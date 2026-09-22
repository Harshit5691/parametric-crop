// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IRainfallOracle} from "../src/interfaces/IRainfallOracle.sol";
import {Pool} from "../src/Pool.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {RainfallOracle} from "../src/RainfallOracle.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Demo parameters shared by both halves of the script.
/// @dev The thresholds are the pricing engine's calibrated output for Yavatmal
///      and the rainfall figures are the real 2005 season, the worst in the
///      30-year record.
abstract contract DemoBase is Script {
    uint256 internal constant M = 1e6;
    uint256 internal constant SUM_INSURED = 24_000 * M; // ~INR 20 lakh
    uint256 internal constant PREMIUM = 2_189 * M; // 9.12% of sum insured
    uint256 internal constant LP_CAPITAL = 100_000 * M;

    // 2005 Yavatmal, in hundredths of a mm.
    uint32 internal constant SOWING_2005 = 54_700; // 547.0mm
    uint32 internal constant FLOWERING_2005 = 13_480; // 134.8mm <- drought
    uint32 internal constant MATURITY_2005 = 14_400; // 144.0mm

    function _phases(uint64 start) internal pure returns (PolicyManager.Phase[] memory p) {
        p = new PolicyManager.Phase[](3);
        p[0] = PolicyManager.Phase({
            startsAt: start,
            endsAt: start + 46 days, // 15 Jun - 31 Jul
            weightBps: 2_500,
            triggerMmX100: 29_200,
            exitMmX100: 23_100,
            settled: false,
            paidUnits: 0
        });
        p[1] = PolicyManager.Phase({
            startsAt: start + 51 days,
            endsAt: start + 87 days, // 5 Aug - 10 Sep
            weightBps: 5_500,
            triggerMmX100: 16_600,
            exitMmX100: 14_600,
            settled: false,
            paidUnits: 0
        });
        p[2] = PolicyManager.Phase({
            startsAt: start + 88 days,
            endsAt: start + 122 days, // 11 Sep - 15 Oct
            weightBps: 2_000,
            triggerMmX100: 3_000,
            exitMmX100: 800,
            settled: false,
            paidUnits: 0
        });
    }

    function _publish(RainfallOracle oracle, uint256 policyId, uint8 phaseIndex, uint32 mmX100)
        internal
    {
        uint32[] memory values = new uint32[](3);
        // Three feeds that disagree slightly; the median settles.
        values[0] = mmX100;
        values[1] = mmX100 + 40;
        values[2] = mmX100 > 30 ? mmX100 - 30 : 0;

        string[] memory names = new string[](3);
        names[0] = "open-meteo";
        names[1] = "nasa-power";
        names[2] = "chirps";

        oracle.publish(policyId, phaseIndex, values, names);
    }
}

/// @notice Part 1 — deploy, fund the pool, write the policy, publish the season.
/// @dev Split from settlement because forge dry-runs a whole script against
///      current chain state before broadcasting. With settlement in the same
///      script the simulation runs before the clock advances and every
///      settlePhase reverts WindowNotClosed. Splitting also suits the demo
///      video: pause here, advance the clock on camera, then settle.
///
///        anvil                                          # terminal 1
///        forge script script/Demo.s.sol:DemoSetup \
///          --rpc-url http://localhost:8545 --broadcast --unlocked \
///          --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
contract DemoSetup is DemoBase {
    function run() external {
        address actor = msg.sender;
        vm.startBroadcast();

        MockUSDC usdc = new MockUSDC();
        Pool pool = new Pool(IERC20(address(usdc)), actor, 10_000);
        RainfallOracle oracle = new RainfallOracle(actor);
        PolicyManager manager =
            new PolicyManager(pool, IRainfallOracle(address(oracle)), actor);

        pool.setUnderwriter(address(manager), true);
        manager.setApprovedBuyer(actor, true);

        // --- LP side: capital arrives -------------------------------------
        usdc.mint(actor, 1_000_000 * M);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LP_CAPITAL);

        // --- Buyer side: the FPO writes cover ------------------------------
        uint256 policyId =
            manager.createPolicy(actor, SUM_INSURED, PREMIUM, _phases(uint64(block.timestamp)));

        // --- Oracle publishes the 2005 season ------------------------------
        _publish(oracle, policyId, 0, SOWING_2005);
        _publish(oracle, policyId, 1, FLOWERING_2005);
        _publish(oracle, policyId, 2, MATURITY_2005);

        vm.stopBroadcast();

        console.log("=== deployed ===");
        console.log("  USDC          ", address(usdc));
        console.log("  Pool          ", address(pool));
        console.log("  Oracle        ", address(oracle));
        console.log("  PolicyManager ", address(manager));
        console.log("");
        console.log("=== pool ===");
        console.log("  capital (USDC)", pool.totalAssets() / M);
        console.log("  reserved      ", pool.totalReserved() / M);
        console.log("");
        console.log("=== policy", policyId, "written ===");
        console.log("  sum insured   ", SUM_INSURED / M);
        console.log("  premium       ", PREMIUM / M);
        console.log("  flowering index 134.8mm vs trigger 166.0mm -> below");
        console.log("");
        console.log("Next: advance the chain past the windows, then run DemoSettle.");
        console.log("  cast rpc evm_increaseTime 11232000 --rpc-url http://localhost:8545");
        console.log("  cast rpc evm_mine --rpc-url http://localhost:8545");
        console.log("");
        console.log("  export POOL=%s", vm.toString(address(pool)));
        console.log("  export MANAGER=%s", vm.toString(address(manager)));
        console.log("  export POLICY_ID=%s", vm.toString(policyId));
    }
}

/// @notice Part 2 — settle every phase. The payout moment.
/// @dev Run after advancing the chain clock past the last window:
///
///        cast rpc evm_increaseTime 11232000 --rpc-url http://localhost:8545
///        cast rpc evm_mine --rpc-url http://localhost:8545
///        POOL=0x... MANAGER=0x... POLICY_ID=1 \
///        forge script script/Demo.s.sol:DemoSettle \
///          --rpc-url http://localhost:8545 --broadcast --unlocked \
///          --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
contract DemoSettle is DemoBase {
    function run() external {
        Pool pool = Pool(vm.envAddress("POOL"));
        PolicyManager manager = PolicyManager(vm.envAddress("MANAGER"));
        uint256 policyId = vm.envUint("POLICY_ID");

        IERC20 usdc = pool.asset();
        PolicyManager.Policy memory policy = manager.getPolicy(policyId);

        uint256 capitalBefore = pool.totalAssets();
        uint256 buyerBefore = usdc.balanceOf(policy.buyer);

        console.log("=== before settlement ===");
        console.log("  pool capital  ", capitalBefore / M);
        console.log("  pool reserved ", pool.totalReserved() / M);
        console.log("  buyer balance ", buyerBefore / M);
        console.log("");

        vm.startBroadcast();
        uint256 total;
        for (uint8 i = 0; i < policy.phaseCount; ++i) {
            // Permissionless: no claim is filed, anyone can call this.
            uint256 paid = manager.settlePhase(policyId, i);
            total += paid;
            console.log("  settled phase", i, "-> paid", paid / M);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("=== after settlement ===");
        console.log("  total payout  ", total / M);
        console.log("  buyer received", (usdc.balanceOf(policy.buyer) - buyerBefore) / M);
        console.log("  pool capital  ", pool.totalAssets() / M);
        console.log("  pool reserved ", pool.totalReserved() / M);
        console.log("");
        console.log("No claim was filed. No adjuster visited.");
    }
}
