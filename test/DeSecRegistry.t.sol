// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../src/GuardianAdapter.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";

contract DeSecRegistryTest is Test {
    address protocolOwner = makeAddr("Protocol_Owner");
    MockProtocol mockProtocol;
    GuardianAdapterFactory private factory;

    function setUp() public {
        factory = new GuardianAdapterFactory();
        vm.deal(protocolOwner, 5 ether);
        vm.prank(protocolOwner);
        mockProtocol = new MockProtocol();
    }

    function testRegistrationSuccess() public {
        vm.startPrank(protocolOwner);
        DeSecRegistry registry = factory.registry();

        uint256 expectedId = registry.protocolId();
        vm.expectEmit(true, true, false, false);
        emit Ownable.OwnershipTransferred(address(0), protocolOwner);
        
        vm.expectEmit(false, false, false, true, address(registry));
        emit DeSecRegistry.Registered(address(0), expectedId);
        // we need to cover the bounty plus 30 days of check in fees.
        address adapter = factory.register{value: 4 ether + (1e6 wei * 30 days)}(
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            30 days,
            protocolOwner
        );
        vm.assertTrue(adapter.code.length > 0);
        vm.assertEq(protocolOwner, GuardianAdapter(adapter).owner());
        // the resulting balance will be what's left of the initial minus the value passed.
        vm.assertEq(protocolOwner.balance, 5 ether - (4 ether + (1e6 wei * 30 days)));
        vm.stopPrank();
    }

    function testRegistrationNoValue() public {
        // registration reverts if no value passed
        vm.expectRevert(DeSecRegistry.NoInitialDeposit.selector);
        factory.register(
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            30 days,
            protocolOwner
        );
    }

    function testRegistrationInsufficientBountyValue() public {
        // registration reverts if the value passed cannot satisfy the bounty
        uint256 bounty = 7 ether;
        uint256 checkInFee = 1e6 wei;
        uint256 duration = 30 days;

        uint256 expectedValue = bounty + (checkInFee * duration);
        uint256 passed = 4 ether + checkInFee;

        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.InsufficientValue.selector, passed, expectedValue);

        vm.expectRevert(expectedError);
        factory.register{value: passed}(
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            bounty,
            checkInFee,
            duration,
            protocolOwner
        );

    }

    function testRegistrationInsufficientCheckInValue() public {
        // registration reverts if the value passed cannot satisfy the check in fees
        uint256 bounty = 1 ether;
        uint256 checkInFee = 1 ether;
        uint256 duration = 30 days;

        uint256 expectedValue = bounty + (checkInFee * duration);
        uint256 passed = 4 ether + checkInFee;

        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.InsufficientValue.selector, passed, expectedValue);

        vm.expectRevert(expectedError);
        factory.register{value: passed}(
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            bounty,
            checkInFee,
            duration,
            protocolOwner
        );
    }

    function testRegistrationInvalidDuration() public {
        // someone tries to register with less than the minimum duration
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.InvalidCheckInDuration.selector, 1 days, factory.registry().MINIMUM_DURATION());
        vm.expectRevert(expectedError);
        factory.register{value: 4 ether + (1e6 wei * 1 days)}(
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            1 days,
            protocolOwner
        );
    }
}
