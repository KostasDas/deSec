// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../src/GuardianAdapter.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {console} from "forge-std/console.sol";

contract DeSecRegistryTest is Test {
    address protocolOwner = makeAddr("Protocol_Owner");
    address random = makeAddr("Random_Account");
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

        uint256 expectedId = registry.protocolId() + 1;
        vm.expectEmit(true, true, false, false);
        emit Ownable.OwnershipTransferred(address(0), protocolOwner);

        vm.expectEmit(false, false, false, true, address(registry));
        emit DeSecRegistry.Registered(address(0), address(mockProtocol), expectedId);
        // we need to cover the bounty plus 30 days of check in fees.
        (address adapter, uint256 protocolId) = factory.register{value: 4 ether + (1e6 wei * 30 days)}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            30 days,
            protocolOwner
        );
        vm.stopPrank();
        vm.assertTrue(adapter.code.length > 0);
        vm.assertEq(protocolOwner, GuardianAdapter(adapter).owner());
        // the resulting balance will be what's left of the initial minus the value passed.
        vm.assertEq(protocolOwner.balance, 5 ether - (4 ether + (1e6 wei * 30 days)));
        DeSecRegistry.Protocol memory _p = factory.registry().getProtocol(protocolId);
        vm.assertEq(protocolId, _p.protocolId);
        vm.assertEq(address(mockProtocol), _p.protocol);
    }

    function testRegistrationNoValue() public {
        uint256 bounty = 4 ether;
        uint256 checkInFee = 1e6 wei;
        // registration reverts if no value passed
        bytes memory expectedError = abi.encodeWithSelector(
            DeSecRegistry.InvalidRegistrationAmounts.selector,
            0,
            bounty,
            checkInFee,
            factory.registry().MINIMUM_REGISTRATION_FEE()
        );
        vm.expectRevert(expectedError);
        factory.register(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            bounty,
            checkInFee,
            5 minutes,
            protocolOwner
        );
    }

    function testRegistrationNoBounty() public {
        uint256 value = 2 ether;
        uint256 checkInFee = 1e6 wei;
        // registration reverts if no bounty passed
        bytes memory expectedError = abi.encodeWithSelector(
            DeSecRegistry.InvalidRegistrationAmounts.selector,
            value,
            0,
            checkInFee,
            factory.registry().MINIMUM_REGISTRATION_FEE()
        );
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            0,
            checkInFee,
            2 minutes,
            protocolOwner
        );
    }

    function testRegistrationInsufficientBountyValue() public {
        // registration reverts if the value passed cannot satisfy the bounty
        uint256 bounty = 7 ether;
        uint256 checkInFee = 1e6 wei;
        uint256 duration = 1 hours;
        uint256 passed = 4 ether + checkInFee;

        bytes memory expectedError = abi.encodeWithSelector(
            DeSecRegistry.InvalidRegistrationAmounts.selector,
            passed,
            bounty,
            checkInFee,
            factory.registry().MINIMUM_REGISTRATION_FEE()
        );

        vm.expectRevert(expectedError);
        factory.register{value: passed}(
            address(mockProtocol),
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
        uint256 checkInFee = 0.01 ether;
        uint256 interval = 1 hours;
        uint256 passed = 1.001 ether;

        bytes memory expectedError = abi.encodeWithSelector(
            DeSecRegistry.InvalidRegistrationAmounts.selector,
            passed,
            bounty,
            checkInFee,
            factory.registry().MINIMUM_REGISTRATION_FEE()
        );

        vm.expectRevert(expectedError);
        factory.register{value: passed}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            bounty,
            checkInFee,
            interval,
            protocolOwner
        );
    }

    function testRegistrationInvalidDuration() public {
        // someone tries to register with less than the minimum duration
        uint256 invalidDuration = 10 seconds;
        bytes memory expectedError = abi.encodeWithSelector(
            DeSecRegistry.InvalidIntervalDuration.selector, invalidDuration, factory.registry().MINIMUM_INTERVAL()
        );
        vm.expectRevert(expectedError);
        factory.register{value: 5 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            invalidDuration,
            protocolOwner
        );
    }

    /**
     * When a user updates bounty, we need to update both the balance and the bounty
     */
    function testRandomUserUpdateBounty() public {
        uint256 extraBounty = 1 ether;
        vm.deal(random, extraBounty);
        uint256 id = register();
        vm.startPrank(random);
        DeSecRegistry registry = factory.registry();
        DeSecRegistry.Protocol memory _p = factory.registry().getProtocol(id);
        vm.expectEmit(true, true, true, true, address(registry));

        uint256 previousBounty = _p.bounty;
        uint256 previousBalance = _p.balance;

        emit DeSecRegistry.BalanceUpdated(_p.protocolId, previousBalance, previousBalance + extraBounty);
        emit DeSecRegistry.BountyUpdated(_p.protocolId, previousBounty, previousBounty + extraBounty);
        registry.addBounty{value: extraBounty}(_p.protocolId);

        _p = factory.registry().getProtocol(id);
        vm.assertEq(_p.bounty, previousBounty + extraBounty);
        vm.assertEq(_p.balance, previousBalance + extraBounty);
    }

    function testUpdateBountyNoValueReverts() public {
        uint256 id = register();

        vm.startPrank(random);
        DeSecRegistry registry = factory.registry();
        DeSecRegistry.Protocol memory _p = registry.getProtocol(id);

        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ValueRequired.selector);
        vm.expectRevert(expectedError);
        registry.addBounty(_p.protocolId);

        vm.stopPrank();
    }

    function register() private returns (uint256) {
        (, uint256 protocolId) = factory.register{value: 4 ether + (1e6 wei * 30 days)}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            30 days,
            protocolOwner
        );
        return protocolId;
    }
}
