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

/// @notice Deploys the stack and writes addresses for the dashboard to read.
/// @dev Separate from Demo.s.sol: this one only deploys, so the dashboard can
///      be pointed at a chain whose season has not been fast-forwarded yet.
///
///        forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
///          --broadcast --unlocked --sender 0xf39F...2266
contract DeployScript is Script {
    uint256 internal constant M = 1e6;

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

        // Seed the deployer so the dashboard has something to show.
        usdc.mint(actor, 1_000_000 * M);
        usdc.approve(address(pool), type(uint256).max);

        vm.stopBroadcast();

        string memory json = string.concat(
            "{\n",
            '  "chainId": ', vm.toString(block.chainid), ",\n",
            '  "usdc": "', vm.toString(address(usdc)), '",\n',
            '  "pool": "', vm.toString(address(pool)), '",\n',
            '  "oracle": "', vm.toString(address(oracle)), '",\n',
            '  "policyManager": "', vm.toString(address(manager)), '"\n',
            "}\n"
        );

        vm.writeFile("../dashboards/src/contracts/addresses.json", json);

        console.log("=== deployed ===");
        console.log(json);
        console.log("Wrote dashboards/src/contracts/addresses.json");
    }
}
