// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../src/GuardianAdapter.sol";
import {GuardianExecutor} from "../src/GuardianExecutor.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {console} from "forge-std/console.sol";

contract GuardianExecutorTest is Test {
    address protocolOwner = makeAddr("Protocol_Owner");
    address watcher = makeAddr("Watcher");
    MockProtocol mockProtocol;
    GuardianAdapterFactory private factory;
    GuardianExecutor executor;
    GuardianAdapter adapter;
    uint256 protocolId;
    bytes invariantPayload = abi.encodeCall(MockProtocol.isHealthy, ());
    bytes emergencyPayload = abi.encodeCall(MockProtocol.pause, ());

    function setUp() public {
        factory = new GuardianAdapterFactory();
        executor = factory.executor();
        vm.deal(protocolOwner, 5 ether);
        vm.prank(protocolOwner);
        mockProtocol = new MockProtocol();

        vm.prank(protocolOwner);
        (address _adapter, uint256 _protocolId) = factory.register{value: 5 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 4 ether, 1e6 wei, 5 minutes, protocolOwner
        );
        adapter = GuardianAdapter(_adapter);
        protocolId = _protocolId;

        vm.prank(protocolOwner);
        mockProtocol.grantRole(mockProtocol.PAUSER_ROLE(), address(adapter));
    }
}
