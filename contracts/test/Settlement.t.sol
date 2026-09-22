// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IRainfallOracle} from "../src/interfaces/IRainfallOracle.sol";
import {Pool} from "../src/Pool.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {RainfallOracle} from "../src/RainfallOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice End-to-end settlement, using the demo policy's real parameters.
/// @dev Thresholds come from the pricing engine's calibration for Yavatmal
///      (sowing 292/231, flowering 166/146, maturity 30/8) and the rainfall
///      figures are the actual 2005 season, which the burn analysis scores as
///      the worst in the 30-year record.
contract SettlementTest is Test {
    MockUSDC internal usdc;
    Pool internal pool;
    RainfallOracle internal oracle;
    PolicyManager internal manager;

    address internal governor = makeAddr("governor");
    address internal lp = makeAddr("lp");
    address internal fpo = makeAddr("fpo");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant M = 1e6;
    uint256 internal constant SUM_INSURED = 24_000 * M; // ~INR 20 lakh
    uint256 internal constant PREMIUM = 2_189 * M; // 9.12% of sum insured

    uint64 internal seasonStart;

    function setUp() public {
        vm.warp(1_700_000_000);
        seasonStart = uint64(block.timestamp);

        usdc = new MockUSDC();
        pool = new Pool(IERC20(address(usdc)), governor, 10_000);
        oracle = new RainfallOracle(governor);
        manager = new PolicyManager(pool, IRainfallOracle(address(oracle)), governor);

        vm.startPrank(governor);
        pool.setUnderwriter(address(manager), true);
        manager.setApprovedBuyer(fpo, true);
        vm.stopPrank();

        usdc.mint(lp, 500_000 * M);
        vm.prank(lp);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(lp);
        pool.deposit(100_000 * M);

        usdc.mint(fpo, 10_000 * M);
        vm.prank(fpo);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @dev The demo policy: three phases, weights 25/55/20.
    function _phases() internal view returns (PolicyManager.Phase[] memory p) {
        p = new PolicyManager.Phase[](3);
        p[0] = PolicyManager.Phase({
            startsAt: seasonStart,
            endsAt: seasonStart + 46 days, // 15 Jun - 31 Jul
            weightBps: 2_500,
            triggerMmX100: 29_200,
            exitMmX100: 23_100,
            settled: false,
            paidUnits: 0
        });
        p[1] = PolicyManager.Phase({
            startsAt: seasonStart + 51 days,
            endsAt: seasonStart + 87 days, // 5 Aug - 10 Sep
            weightBps: 5_500,
            triggerMmX100: 16_600,
            exitMmX100: 14_600,
            settled: false,
            paidUnits: 0
        });
        p[2] = PolicyManager.Phase({
            startsAt: seasonStart + 88 days,
            endsAt: seasonStart + 122 days, // 11 Sep - 15 Oct
            weightBps: 2_000,
            triggerMmX100: 3_000,
            exitMmX100: 800,
            settled: false,
            paidUnits: 0
        });
    }

    function _createPolicy() internal returns (uint256) {
        vm.prank(fpo);
        return manager.createPolicy(fpo, SUM_INSURED, PREMIUM, _phases());
    }

    function _publish(uint256 policyId, uint8 phaseIndex, uint32 mmX100) internal {
        uint32[] memory values = new uint32[](3);
        // Three feeds that disagree slightly; the median is what settles.
        values[0] = mmX100;
        values[1] = mmX100 + 40;
        values[2] = mmX100 > 30 ? mmX100 - 30 : 0;

        string[] memory names = new string[](3);
        names[0] = "open-meteo";
        names[1] = "nasa-power";
        names[2] = "chirps";

        vm.prank(governor);
        oracle.publish(policyId, phaseIndex, values, names);
    }

    // ------------------------------------------------------------- creation

    function test_CreatePolicyReservesAndCollects() public {
        uint256 policyId = _createPolicy();

        assertEq(pool.totalReserved(), SUM_INSURED);
        assertEq(pool.totalAssets(), 100_000 * M + PREMIUM);

        PolicyManager.Policy memory policy = manager.getPolicy(policyId);
        assertEq(policy.buyer, fpo);
        assertEq(policy.sumInsuredUnits, SUM_INSURED);
        assertEq(policy.phaseCount, 3);
    }

    function test_CannotCreateForUnapprovedBuyer() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(PolicyManager.BuyerNotApproved.selector, stranger)
        );
        vm.prank(fpo);
        manager.createPolicy(stranger, SUM_INSURED, PREMIUM, _phases());
    }

    function test_RejectsWeightsNotSummingToBps() public {
        PolicyManager.Phase[] memory p = _phases();
        p[0].weightBps = 3_000; // now sums to 10_500
        vm.expectRevert(
            abi.encodeWithSelector(PolicyManager.WeightsMustSumToBps.selector, uint256(10_500))
        );
        vm.prank(fpo);
        manager.createPolicy(fpo, SUM_INSURED, PREMIUM, p);
    }

    function test_RejectsExitAboveTrigger() public {
        PolicyManager.Phase[] memory p = _phases();
        p[1].exitMmX100 = p[1].triggerMmX100 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(PolicyManager.ExitNotBelowTrigger.selector, uint8(1))
        );
        vm.prank(fpo);
        manager.createPolicy(fpo, SUM_INSURED, PREMIUM, p);
    }

    function test_CannotWriteBeyondPoolCapacity() public {
        // Pool holds 100k; a 200k policy must be refused.
        vm.expectRevert();
        vm.prank(fpo);
        manager.createPolicy(fpo, 200_000 * M, PREMIUM, _phases());
    }

    // ------------------------------------------------------------ settlement

    function test_DroughtFiresPayout() public {
        uint256 policyId = _createPolicy();

        // 2005 flowering window: 134.8mm, below the 146mm exit -> full phase payout.
        vm.warp(seasonStart + 88 days);
        _publish(policyId, 1, 13_480);

        uint256 before = usdc.balanceOf(fpo);
        vm.prank(keeper); // permissionless: not the buyer, not the governor
        uint256 paid = manager.settlePhase(policyId, 1);

        // Full payout on a 55%-weighted phase.
        assertEq(paid, (SUM_INSURED * 5_500) / 10_000);
        assertEq(usdc.balanceOf(fpo), before + paid);
    }

    function test_NormalSeasonPaysNothing() public {
        uint256 policyId = _createPolicy();

        // 2009 flowering: 274.3mm, far above the 166mm trigger.
        vm.warp(seasonStart + 88 days);
        _publish(policyId, 1, 27_430);

        vm.prank(keeper);
        uint256 paid = manager.settlePhase(policyId, 1);
        assertEq(paid, 0);
        assertEq(usdc.balanceOf(fpo), 10_000 * M - PREMIUM);
    }

    function test_PartialPayoutBetweenTriggerAndExit() public {
        uint256 policyId = _createPolicy();

        // 156.00mm sits midway between exit 146 and trigger 166 -> half.
        vm.warp(seasonStart + 88 days);
        _publish(policyId, 1, 15_600);

        vm.prank(keeper);
        uint256 paid = manager.settlePhase(policyId, 1);
        assertEq(paid, (SUM_INSURED * 5_500 * 5_000) / (10_000 * 10_000));
    }

    function test_CannotSettleBeforeWindowCloses() public {
        uint256 policyId = _createPolicy();
        _publish(policyId, 1, 13_480);

        vm.warp(seasonStart + 60 days); // flowering ends at +87d
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.WindowNotClosed.selector,
                seasonStart + 87 days,
                uint64(seasonStart + 60 days)
            )
        );
        manager.settlePhase(policyId, 1);
    }

    function test_CannotSettleWithoutOracleValue() public {
        uint256 policyId = _createPolicy();
        vm.warp(seasonStart + 88 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.OracleNotSettled.selector, policyId, uint8(1)
            )
        );
        manager.settlePhase(policyId, 1);
    }

    function test_CannotSettleTwice() public {
        uint256 policyId = _createPolicy();
        vm.warp(seasonStart + 88 days);
        _publish(policyId, 1, 13_480);

        manager.settlePhase(policyId, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.PhaseAlreadySettled.selector, policyId, uint8(1)
            )
        );
        manager.settlePhase(policyId, 1);
    }

    /// @dev The full 2005 season: the worst year in the historical record.
    function test_FullSeasonReleasesReservation() public {
        uint256 policyId = _createPolicy();
        vm.warp(seasonStart + 123 days);

        _publish(policyId, 0, 54_700); // sowing 547.0mm  - no payout
        _publish(policyId, 1, 13_480); // flowering 134.8 - full payout
        _publish(policyId, 2, 14_400); // maturity 144.0  - no payout

        uint256 total;
        for (uint8 i = 0; i < 3; ++i) {
            total += manager.settlePhase(policyId, i);
        }

        // Only the flowering phase fired: 55% of cover.
        assertEq(total, (SUM_INSURED * 5_500) / 10_000);

        PolicyManager.Policy memory policy = manager.getPolicy(policyId);
        assertTrue(policy.closed);
        assertEq(policy.totalPaidUnits, total);

        // Reservation released, so the capital can back new cover.
        assertEq(pool.totalReserved(), 0);
    }

    function test_TotalPayoutNeverExceedsSumInsured() public {
        uint256 policyId = _createPolicy();
        vm.warp(seasonStart + 123 days);

        // Total failure in every phase.
        _publish(policyId, 0, 0);
        _publish(policyId, 1, 0);
        _publish(policyId, 2, 0);

        uint256 total;
        for (uint8 i = 0; i < 3; ++i) {
            total += manager.settlePhase(policyId, i);
        }
        assertEq(total, SUM_INSURED);
        assertEq(pool.totalReserved(), 0);
    }

    // ---------------------------------------------------------------- oracle

    function test_OracleTakesMedianOfSources() public {
        uint32[] memory values = new uint32[](3);
        values[0] = 13_000;
        values[1] = 13_480; // median
        values[2] = 90_000; // outlier feed
        string[] memory names = new string[](3);
        names[0] = "a";
        names[1] = "b";
        names[2] = "c";

        vm.prank(governor);
        uint32 median = oracle.publish(1, 0, values, names);
        assertEq(median, 13_480);
    }

    function test_OracleRejectsUnauthorisedReporter() public {
        uint32[] memory values = new uint32[](1);
        values[0] = 100;
        string[] memory names = new string[](1);
        names[0] = "a";

        vm.expectRevert(RainfallOracle.NotAuthorised.selector);
        vm.prank(keeper);
        oracle.publish(1, 0, values, names);
    }

    function test_OracleRetainsSourceValuesForAudit() public {
        _publish(1, 0, 13_480);
        uint32[] memory stored = oracle.sourceValues(1, 0);
        assertEq(stored.length, 3);
        assertEq(stored[0], 13_480);
    }

    // ------------------------------------------------------------------ view

    function test_QuotePhasePayoutDrivesDashboard() public {
        uint256 policyId = _createPolicy();
        // Above trigger -> nothing owed yet.
        assertEq(manager.quotePhasePayout(policyId, 1, 30_000), 0);
        // At exit -> full phase exposure.
        assertEq(
            manager.quotePhasePayout(policyId, 1, 14_600), (SUM_INSURED * 5_500) / 10_000
        );
    }
}
