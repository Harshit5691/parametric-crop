// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRainfallOracle} from "./interfaces/IRainfallOracle.sol";

/// @title RainfallOracle
/// @notice Operator-published rainfall observations with the source inputs
///         recorded alongside the settled median.
/// @dev Deliberately a trusted-operator design for launch, and the pitch says
///      so plainly. What it does provide is auditability: every settlement
///      publishes the individual feed values that produced the median, so an
///      observer can recompute the number and catch a bad publish even though
///      they cannot prevent one.
///
///      Decentralisation path: replace the single reporter with a signer set
///      (threshold attestation) or move the fetch into Chainlink Functions. The
///      interface does not change, so the PolicyManager does not either.
contract RainfallOracle is IRainfallOracle {
    error NotAuthorised();
    error AlreadySettled(uint256 policyId, uint8 phaseIndex);
    error NoSources();
    error TooManySources(uint256 count);

    event ReporterSet(address indexed reporter, bool allowed);
    event ObservationPublished(
        uint256 indexed policyId,
        uint8 indexed phaseIndex,
        uint32 medianMmX100,
        uint32[] sourceValues,
        string[] sourceNames
    );

    struct Observation {
        uint32 medianMmX100;
        uint64 settledAt;
    }

    uint256 internal constant MAX_SOURCES = 7;

    address public immutable governor;
    mapping(address => bool) public isReporter;

    mapping(uint256 => mapping(uint8 => Observation)) internal observations;

    /// @notice Source values behind each settled observation, kept for audit.
    mapping(uint256 => mapping(uint8 => uint32[])) internal sourceValuesOf;

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotAuthorised();
        _;
    }

    constructor(address governor_) {
        governor = governor_;
        isReporter[governor_] = true;
        emit ReporterSet(governor_, true);
    }

    function setReporter(address reporter, bool allowed) external onlyGovernor {
        isReporter[reporter] = allowed;
        emit ReporterSet(reporter, allowed);
    }

    /// @notice Publish a settled observation from independent feed values.
    /// @dev The median is computed onchain from the submitted values rather
    ///      than taken on trust, so a reporter cannot publish a number that
    ///      does not follow from the inputs it also published.
    function publish(
        uint256 policyId,
        uint8 phaseIndex,
        uint32[] calldata sourceValues,
        string[] calldata sourceNames
    ) external returns (uint32 medianMmX100) {
        if (!isReporter[msg.sender]) revert NotAuthorised();

        uint256 count = sourceValues.length;
        if (count == 0) revert NoSources();
        if (count > MAX_SOURCES) revert TooManySources(count);

        Observation storage existing = observations[policyId][phaseIndex];
        if (existing.settledAt != 0) revert AlreadySettled(policyId, phaseIndex);

        medianMmX100 = _median(sourceValues);

        observations[policyId][phaseIndex] =
            Observation({medianMmX100: medianMmX100, settledAt: uint64(block.timestamp)});
        sourceValuesOf[policyId][phaseIndex] = sourceValues;

        emit ObservationPublished(policyId, phaseIndex, medianMmX100, sourceValues, sourceNames);
    }

    /// @inheritdoc IRainfallOracle
    function observation(uint256 policyId, uint8 phaseIndex)
        external
        view
        returns (uint32 observedMmX100, uint64 settledAt)
    {
        Observation storage obs = observations[policyId][phaseIndex];
        return (obs.medianMmX100, obs.settledAt);
    }

    /// @notice The individual feed values behind a settled observation.
    function sourceValues(uint256 policyId, uint8 phaseIndex)
        external
        view
        returns (uint32[] memory)
    {
        return sourceValuesOf[policyId][phaseIndex];
    }

    /// @dev Insertion sort over a memory copy. Bounded at MAX_SOURCES, so the
    ///      quadratic cost is trivial and the code stays obvious.
    function _median(uint32[] calldata values) internal pure returns (uint32) {
        uint256 n = values.length;
        uint32[] memory sorted = new uint32[](n);
        for (uint256 i = 0; i < n; ++i) {
            sorted[i] = values[i];
        }
        for (uint256 i = 1; i < n; ++i) {
            uint32 key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                --j;
            }
            sorted[j] = key;
        }

        if (n % 2 == 1) return sorted[n / 2];
        // Even count: mean of the middle pair, widened to avoid overflow.
        return uint32((uint256(sorted[n / 2 - 1]) + uint256(sorted[n / 2])) / 2);
    }
}
