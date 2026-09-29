// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../src/GuardianAdapter.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {console} from "forge-std/console.sol";

contract GuardianAdapterTest is Test {
    address protocolOwner = makeAddr("Protocol_Owner");
    address random = makeAddr("Random_Account");
    MockProtocol mockProtocol;
    GuardianAdapterFactory private factory;
    GuardianAdapter adapter;
    uint256 protocolId;

    function setUp() public {
        factory = new GuardianAdapterFactory();
        vm.deal(protocolOwner, 5 ether);
        vm.prank(protocolOwner);
        mockProtocol = new MockProtocol();

        vm.prank(protocolOwner);
        (address _adapter, uint256 _protocolId) = factory.register{value: 5 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            5 minutes,
            protocolOwner
        );
        adapter = GuardianAdapter(_adapter);
        protocolId = _protocolId;
    }
}
