// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";

contract DeSecRegistryTest is Test {
    address protocolOwner = makeAddr("Protocol_Owner");
    MockProtocol mockProtocol;
    GuardianAdapterFactory private factory;

    function setUp() public {
        factory = new GuardianAdapterFactory();
        vm.prank(protocolOwner);
        mockProtocol = new MockProtocol();
    }

    function testRegistrationSuccess() public {
        vm.deal(protocolOwner, 5 ether);
        vm.startPrank(protocolOwner);
        DeSecRegistry registry = factory.registry();

        uint256 expectedId = registry.protocolId();
        vm.expectEmit(true, true, false, false);
        emit Ownable.OwnershipTransferred(address(0), protocolOwner);
        
        vm.expectEmit(false, false, false, true, address(registry));
        emit DeSecRegistry.Registered(address(0), expectedId);

        address adapter = factory.register{value: 4 ether + 1e6 wei}(
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            30 days,
            protocolOwner
        );
        vm.assertTrue(adapter.code.length > 0);
        vm.assertEq(protocolOwner.balance, 1 ether - 1e6 wei);
    }

    function testRegistrationNoValue() public view {}

    function testRegistrationInsufficientValue1() public view {}

    function testRegistrationInsufficientValue2() public view {}

    function testRegistrationInsufficientValue3() public view {}
}
