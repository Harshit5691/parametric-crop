// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRainfallOracle} from "./interfaces/IRainfallOracle.sol";
import {PayoutMath} from "./PayoutMath.sol";
import {Pool} from "./Pool.sol";

/// @title PolicyManager
/// @notice Writes policies against the Pool and settles them from oracle data.
/// @dev Combines the brief's Policy and Settlement contracts. They share all of
///      their state, and splitting them would mean a cross-contract call on
///      every settle for no isolation benefit.
///
///      Settlement is permissionless: once a phase window has closed and the
///      oracle has published, anyone can call `settlePhase` and the money
///      moves. The buyer does not file a claim and cannot be stalled by us.
contract PolicyManager {
    using PayoutMath for uint256;

    // ---------------------------------------------------------------- errors

    error NotAuthorised();
    error UnknownPolicy(uint256 policyId);
    error UnknownPhase(uint256 policyId, uint8 phaseIndex);
    error NoPhases();
    error TooManyPhases(uint256 count);
    error WeightsMustSumToBps(uint256 total);
    error ExitNotBelowTrigger(uint8 phaseIndex);
    error WindowNotOrdered(uint8 phaseIndex);
    error ZeroSumInsured();
    error WindowNotClosed(uint64 endsAt, uint64 nowAt);
    error OracleNotSettled(uint256 policyId, uint8 phaseIndex);
    error PhaseAlreadySettled(uint256 policyId, uint8 phaseIndex);
    error BuyerNotApproved(address buyer);

    // ---------------------------------------------------------------- events

    event BuyerApproved(address indexed buyer, bool approved);
    event PolicyCreated(
        uint256 indexed policyId,
        address indexed buyer,
        uint256 sumInsuredUnits,
        uint256 premiumUnits,
        uint8 phaseCount
    );
    event PhaseSettled(
        uint256 indexed policyId,
        uint8 indexed phaseIndex,
        uint32 observedMmX100,
        uint256 payoutUnits
    );
    event PolicyClosed(uint256 indexed policyId, uint256 totalPaidUnits);

    // ----------------------------------------------------------------- types

    /// @dev Packed to keep a phase in two storage slots.
    struct Phase {
        uint64 startsAt; // window open  (unix seconds)
        uint64 endsAt; // window close (unix seconds)
        uint16 weightBps; // share of sum insured exposed in this phase
        uint32 triggerMmX100; // payout begins below this
        uint32 exitMmX100; // full phase payout at or below this
        bool settled;
        uint256 paidUnits;
    }

    struct Policy {
        address buyer;
        uint256 sumInsuredUnits;
        uint256 premiumUnits;
        uint256 totalPaidUnits;
        uint8 phaseCount;
        uint8 settledCount;
        bool closed;
    }

    // ----------------------------------------------------------------- state

    uint256 internal constant BPS = 10_000;
    uint8 internal constant MAX_PHASES = 8;

    Pool public immutable pool;
    IERC20 public immutable asset;
    IRainfallOracle public oracle;
    address public immutable governor;

    mapping(address => bool) public isApprovedBuyer;

    uint256 public nextPolicyId = 1;
    mapping(uint256 => Policy) internal policies;
    mapping(uint256 => mapping(uint8 => Phase)) internal phases;

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotAuthorised();
        _;
    }

    constructor(Pool pool_, IRainfallOracle oracle_, address governor_) {
        pool = pool_;
        asset = pool_.asset();
        oracle = oracle_;
        governor = governor_;
    }

    // ------------------------------------------------------------ governance

    /// @dev Buyers are FPOs, agri-lenders and MFIs, onboarded off-chain. The
    ///      allowlist is a regulatory necessity, not a decentralisation
    ///      failure: cover is sold to vetted businesses under a licensed
    ///      fronting arrangement.
    function setApprovedBuyer(address buyer, bool approved) external onlyGovernor {
        isApprovedBuyer[buyer] = approved;
        emit BuyerApproved(buyer, approved);
    }

    function setOracle(IRainfallOracle oracle_) external onlyGovernor {
        oracle = oracle_;
    }

    // ------------------------------------------------------------ writing io

    /// @notice Write a policy: reserve capital, collect premium upfront.
    /// @dev Reserves the full sum insured. Phase weights sum to BPS, so the
    ///      worst case across all phases is exactly the sum insured — the pool
    ///      never owes more than it has locked.
    function createPolicy(
        address buyer,
        uint256 sumInsuredUnits,
        uint256 premiumUnits,
        Phase[] calldata newPhases
    ) external returns (uint256 policyId) {
        if (!isApprovedBuyer[buyer]) revert BuyerNotApproved(buyer);
        if (sumInsuredUnits == 0) revert ZeroSumInsured();

        uint256 count = newPhases.length;
        if (count == 0) revert NoPhases();
        if (count > MAX_PHASES) revert TooManyPhases(count);

        uint256 weightTotal;
        for (uint8 i = 0; i < count; ++i) {
            Phase calldata p = newPhases[i];
            if (p.exitMmX100 >= p.triggerMmX100) revert ExitNotBelowTrigger(i);
            if (p.startsAt >= p.endsAt) revert WindowNotOrdered(i);
            weightTotal += p.weightBps;
        }
        if (weightTotal != BPS) revert WeightsMustSumToBps(weightTotal);

        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            buyer: buyer,
            sumInsuredUnits: sumInsuredUnits,
            premiumUnits: premiumUnits,
            totalPaidUnits: 0,
            phaseCount: uint8(count),
            settledCount: 0,
            closed: false
        });

        for (uint8 i = 0; i < count; ++i) {
            Phase calldata p = newPhases[i];
            phases[policyId][i] = Phase({
                startsAt: p.startsAt,
                endsAt: p.endsAt,
                weightBps: p.weightBps,
                triggerMmX100: p.triggerMmX100,
                exitMmX100: p.exitMmX100,
                settled: false,
                paidUnits: 0
            });
        }

        // Reserve first: if the pool lacks capacity this reverts and no premium
        // is taken.
        pool.reserve(sumInsuredUnits);
        if (premiumUnits > 0) {
            pool.collectPremium(msg.sender, premiumUnits);
        }

        emit PolicyCreated(policyId, buyer, sumInsuredUnits, premiumUnits, uint8(count));
    }

    // --------------------------------------------------------------- settle io

    /// @notice Settle one phase against the oracle. Permissionless.
    /// @dev No claim, no adjuster. The window closes, the oracle publishes,
    ///      anyone calls this, the money moves.
    function settlePhase(uint256 policyId, uint8 phaseIndex) external returns (uint256 payoutUnits) {
        Policy storage policy = policies[policyId];
        if (policy.buyer == address(0)) revert UnknownPolicy(policyId);
        if (phaseIndex >= policy.phaseCount) revert UnknownPhase(policyId, phaseIndex);

        Phase storage phase = phases[policyId][phaseIndex];
        if (phase.settled) revert PhaseAlreadySettled(policyId, phaseIndex);
        if (block.timestamp < phase.endsAt) {
            revert WindowNotClosed(phase.endsAt, uint64(block.timestamp));
        }

        (uint32 observedMmX100, uint64 settledAt) = oracle.observation(policyId, phaseIndex);
        if (settledAt == 0) revert OracleNotSettled(policyId, phaseIndex);

        payoutUnits = PayoutMath.phasePayout(
            policy.sumInsuredUnits,
            phase.weightBps,
            phase.triggerMmX100,
            phase.exitMmX100,
            observedMmX100
        );

        // Mark settled before any external call.
        phase.settled = true;
        phase.paidUnits = payoutUnits;
        policy.settledCount += 1;
        policy.totalPaidUnits += payoutUnits;

        emit PhaseSettled(policyId, phaseIndex, observedMmX100, payoutUnits);
        if (payoutUnits > 0) {
            pool.payout(policy.buyer, payoutUnits);
        }

        // Once every phase has settled the policy can carry no further
        // liability, so the remaining reservation is freed for other cover.
        if (policy.settledCount == policy.phaseCount) {
            policy.closed = true;
            emit PolicyClosed(policyId, policy.totalPaidUnits);
            pool.release(policy.sumInsuredUnits);
        }
    }

    // ------------------------------------------------------------------ views

    function getPolicy(uint256 policyId) external view returns (Policy memory) {
        Policy memory policy = policies[policyId];
        if (policy.buyer == address(0)) revert UnknownPolicy(policyId);
        return policy;
    }

    function getPhase(uint256 policyId, uint8 phaseIndex) external view returns (Phase memory) {
        Policy storage policy = policies[policyId];
        if (policy.buyer == address(0)) revert UnknownPolicy(policyId);
        if (phaseIndex >= policy.phaseCount) revert UnknownPhase(policyId, phaseIndex);
        return phases[policyId][phaseIndex];
    }

    /// @notice What a phase would pay at a hypothetical rainfall figure.
    /// @dev Drives the dashboard's live "index vs trigger" readout.
    function quotePhasePayout(uint256 policyId, uint8 phaseIndex, uint32 observedMmX100)
        external
        view
        returns (uint256)
    {
        Policy storage policy = policies[policyId];
        if (policy.buyer == address(0)) revert UnknownPolicy(policyId);
        if (phaseIndex >= policy.phaseCount) revert UnknownPhase(policyId, phaseIndex);

        Phase storage phase = phases[policyId][phaseIndex];
        return PayoutMath.phasePayout(
            policy.sumInsuredUnits,
            phase.weightBps,
            phase.triggerMmX100,
            phase.exitMmX100,
            observedMmX100
        );
    }
}
