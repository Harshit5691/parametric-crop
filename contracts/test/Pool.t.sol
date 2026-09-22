// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Pool} from "../src/Pool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PoolTest is Test {
    MockUSDC internal usdc;
    Pool internal pool;

    address internal governor = makeAddr("governor");
    address internal underwriter = makeAddr("underwriter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant M = 1e6; // one USDC

    function setUp() public {
        usdc = new MockUSDC();
        pool = new Pool(IERC20(address(usdc)), governor, 10_000);

        vm.prank(governor);
        pool.setUnderwriter(underwriter, true);

        for (uint256 i = 0; i < 2; ++i) {
            address lp = i == 0 ? alice : bob;
            usdc.mint(lp, 1_000_000 * M);
            vm.prank(lp);
            usdc.approve(address(pool), type(uint256).max);
        }
        usdc.mint(buyer, 1_000_000 * M);
        vm.prank(buyer);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _deposit(address lp, uint256 amount) internal returns (uint256) {
        vm.prank(lp);
        return pool.deposit(amount);
    }

    // ------------------------------------------------------------- deposits

    function test_FirstDepositMintsOneToOne() public {
        uint256 shares = _deposit(alice, 100_000 * M);
        assertEq(shares, 100_000 * M);
        assertEq(pool.totalAssets(), 100_000 * M);
    }

    function test_SecondDepositorIsNotDiluted() public {
        _deposit(alice, 100_000 * M);
        uint256 bobShares = _deposit(bob, 100_000 * M);

        // Equal deposits into an unchanged pool must give equal shares.
        assertEq(bobShares, 100_000 * M);
        assertEq(pool.convertToAssets(bobShares), 100_000 * M);
    }

    function test_PremiumAccruesToExistingLPs() public {
        uint256 aliceShares = _deposit(alice, 100_000 * M);

        vm.prank(underwriter);
        pool.collectPremium(buyer, 10_000 * M);

        // Alice owns the whole pool, so the premium is entirely hers.
        assertEq(pool.convertToAssets(aliceShares), 110_000 * M);
    }

    function test_DepositAfterPremiumGetsFewerShares() public {
        _deposit(alice, 100_000 * M);
        vm.prank(underwriter);
        pool.collectPremium(buyer, 10_000 * M);

        // Pool is now worth 110k. Bob paying 110k should get the same share
        // count Alice holds, not more.
        uint256 bobShares = _deposit(bob, 110_000 * M);
        assertEq(bobShares, 100_000 * M);
    }

    function test_RevertOnZeroDeposit() public {
        vm.expectRevert(Pool.ZeroAmount.selector);
        vm.prank(alice);
        pool.deposit(0);
    }

    // ----------------------------------------------------------- withdrawals

    function test_WithdrawReturnsCapital() public {
        uint256 shares = _deposit(alice, 100_000 * M);
        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = pool.withdraw(shares);

        assertEq(assets, 100_000 * M);
        assertEq(usdc.balanceOf(alice), before + 100_000 * M);
        assertEq(pool.totalShares(), 0);
    }

    function test_CannotWithdrawReservedCapital() public {
        uint256 shares = _deposit(alice, 100_000 * M);

        vm.prank(underwriter);
        pool.reserve(80_000 * M);

        // Only 20k is free; withdrawing everything must fail.
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.InsufficientFreeCapital.selector, 20_000 * M, 100_000 * M
            )
        );
        vm.prank(alice);
        pool.withdraw(shares);
    }

    function test_CanWithdrawFreePortion() public {
        _deposit(alice, 100_000 * M);
        vm.prank(underwriter);
        pool.reserve(80_000 * M);

        uint256 freeShares = pool.convertToShares(20_000 * M);
        vm.prank(alice);
        uint256 assets = pool.withdraw(freeShares);
        assertEq(assets, 20_000 * M);
    }

    function test_CannotWithdrawMoreSharesThanHeld() public {
        uint256 shares = _deposit(alice, 100_000 * M);
        vm.expectRevert(
            abi.encodeWithSelector(Pool.InsufficientShares.selector, shares, shares + 1)
        );
        vm.prank(alice);
        pool.withdraw(shares + 1);
    }

    // -------------------------------------------------------------- solvency

    function test_CapacityTracksCapital() public {
        _deposit(alice, 100_000 * M);
        assertEq(pool.capacity(), 100_000 * M);
        assertEq(pool.availableCapacity(), 100_000 * M);
    }

    function test_CannotReserveBeyondCapacity() public {
        _deposit(alice, 100_000 * M);
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.WouldBreachSolvency.selector, 100_001 * M, 100_000 * M
            )
        );
        vm.prank(underwriter);
        pool.reserve(100_001 * M);
    }

    function test_SolvencyRatioLimitsExposure() public {
        Pool conservative = new Pool(IERC20(address(usdc)), governor, 5_000); // 50%
        vm.prank(governor);
        conservative.setUnderwriter(underwriter, true);

        vm.prank(alice);
        usdc.approve(address(conservative), type(uint256).max);
        vm.prank(alice);
        conservative.deposit(100_000 * M);

        assertEq(conservative.capacity(), 50_000 * M);
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.WouldBreachSolvency.selector, 50_001 * M, 50_000 * M
            )
        );
        vm.prank(underwriter);
        conservative.reserve(50_001 * M);
    }

    function test_ReleaseFreesCapacity() public {
        _deposit(alice, 100_000 * M);

        vm.startPrank(underwriter);
        pool.reserve(100_000 * M);
        assertEq(pool.availableCapacity(), 0);
        pool.release(40_000 * M);
        vm.stopPrank();

        assertEq(pool.totalReserved(), 60_000 * M);
        assertEq(pool.availableCapacity(), 40_000 * M);
    }

    function test_CannotReleaseMoreThanReserved() public {
        _deposit(alice, 100_000 * M);
        vm.startPrank(underwriter);
        pool.reserve(10_000 * M);
        vm.expectRevert(
            abi.encodeWithSelector(Pool.NotReserved.selector, 10_000 * M, 20_000 * M)
        );
        pool.release(20_000 * M);
        vm.stopPrank();
    }

    function test_CannotLowerRatioBelowActiveExposure() public {
        _deposit(alice, 100_000 * M);
        vm.prank(underwriter);
        pool.reserve(80_000 * M);

        // Dropping to 50% would leave 80k of exposure against 50k of capacity.
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.WouldBreachSolvency.selector, 80_000 * M, 50_000 * M
            )
        );
        vm.prank(governor);
        pool.setSolvencyRatio(5_000);
    }

    function test_RejectsRatioAboveFullCollateralisation() public {
        vm.expectRevert(abi.encodeWithSelector(Pool.InvalidRatio.selector, uint16(10_001)));
        vm.prank(governor);
        pool.setSolvencyRatio(10_001);
    }

    // --------------------------------------------------------------- payouts

    function test_PayoutReducesShareValue() public {
        uint256 shares = _deposit(alice, 100_000 * M);

        vm.startPrank(underwriter);
        pool.reserve(50_000 * M);
        pool.payout(buyer, 30_000 * M);
        pool.release(50_000 * M);
        vm.stopPrank();

        assertEq(usdc.balanceOf(buyer), 1_030_000 * M);
        // The loss lands on LP capital, as it should.
        assertEq(pool.convertToAssets(shares), 70_000 * M);
    }

    // ---------------------------------------------------------------- access

    function test_OnlyUnderwriterCanReserve() public {
        _deposit(alice, 100_000 * M);
        vm.expectRevert(Pool.NotAuthorised.selector);
        vm.prank(alice);
        pool.reserve(1 * M);
    }

    function test_OnlyUnderwriterCanPayout() public {
        _deposit(alice, 100_000 * M);
        vm.expectRevert(Pool.NotAuthorised.selector);
        vm.prank(alice);
        pool.payout(alice, 1 * M);
    }

    function test_OnlyGovernorCanSetUnderwriter() public {
        vm.expectRevert(Pool.NotAuthorised.selector);
        vm.prank(alice);
        pool.setUnderwriter(alice, true);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_ReserveNeverExceedsCapacity(uint96 capital, uint96 exposure) public {
        // alice is funded with 1_000_000 * M in setUp; stay inside that.
        capital = uint96(bound(capital, 1, 1_000_000 * M));
        _deposit(alice, capital);

        // Read capacity before pranking: vm.prank applies to the next call
        // only, and a view call would consume it.
        uint256 cap = pool.capacity();

        if (exposure == 0) {
            vm.expectRevert(Pool.ZeroAmount.selector);
            vm.prank(underwriter);
            pool.reserve(exposure);
            return;
        }

        if (exposure > cap) {
            vm.expectRevert(
                abi.encodeWithSelector(Pool.WouldBreachSolvency.selector, exposure, cap)
            );
            vm.prank(underwriter);
            pool.reserve(exposure);
            assertEq(pool.totalReserved(), 0);
        } else {
            vm.prank(underwriter);
            pool.reserve(exposure);
            assertLe(pool.totalReserved(), pool.capacity());
        }
    }

    function testFuzz_RoundTripDepositWithdraw(uint96 amount) public {
        amount = uint96(bound(amount, 1, 1_000_000 * M));
        uint256 shares = _deposit(alice, amount);
        vm.prank(alice);
        uint256 back = pool.withdraw(shares);
        assertEq(back, amount);
    }
}
