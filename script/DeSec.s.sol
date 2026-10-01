// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";

contract DeSecDeploy is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast(deployerKey);
        GuardianAdapterFactory factory = new GuardianAdapterFactory(feeRecipient);
        vm.stopBroadcast();

        console.log("GuardianAdapterFactory:", address(factory));
        console.log("DeSecRegistry:", address(factory.registry()));
        console.log("GuardianExecutor:", address(factory.executor()));
        console.log("Network fee recipient:", factory.registry().feeRecipient());
    }
}
