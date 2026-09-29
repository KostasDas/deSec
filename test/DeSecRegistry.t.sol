// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../src/GuardianAdapter.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {MockRevertingInvariant} from "./mocks/MockRevertingInvariant.sol";
import {MockGarbageInvariant} from "./mocks/MockGarbageInvariant.sol";
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
        (address adapter, uint256 protocolId) = factory.register{value: 5 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            5 minutes,
            protocolOwner
        );
        vm.stopPrank();
        vm.assertTrue(adapter.code.length > 0);
        vm.assertEq(protocolOwner, GuardianAdapter(adapter).owner());
        vm.assertEq(protocolOwner.balance, 0);
        DeSecRegistry.Protocol memory _p = factory.registry().getProtocol(protocolId);
        vm.assertEq(protocolId, _p.protocolId);
        vm.assertEq(address(mockProtocol), _p.protocol);
        vm.assertEq(protocolOwner, _p.owner);
        vm.assertEq(4 ether, _p.bounty);
        vm.assertEq(5 minutes, _p.interval);
        vm.assertEq(1e6, _p.checkInFee);
        vm.assertEq(5 ether, _p.balance);
        vm.assertEq(mockProtocol.isHealthy.selector, _p.invariantSelector);
        vm.assertEq(mockProtocol.pause.selector, _p.emergencySelector);
        vm.assertEq(block.timestamp, _p.lastCheckTime);
        vm.assertEq(block.timestamp, _p.registrationTime);
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
        uint32 duration = 1 hours;
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
        uint32 interval = 1 hours;
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
        uint32 invalidDuration = 10 seconds;
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

    function testAddBountyOwnerIncreasesBountyAndBalance() public {
        uint256 extraBounty = 1 ether;
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        DeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        uint256 previousBounty = _p.bounty;
        uint256 previousBalance = _p.balance;

        vm.expectEmit(true, true, true, true, address(registry));
        emit DeSecRegistry.BountyUpdated(id, previousBounty, previousBounty + extraBounty);
        vm.expectEmit(true, true, true, true, address(registry));
        emit DeSecRegistry.BalanceUpdated(id, previousBalance, previousBalance + extraBounty);

        vm.prank(protocolOwner);
        registry.addBounty{value: extraBounty}(id);

        _p = registry.getProtocol(id);
        vm.assertEq(_p.bounty, previousBounty + extraBounty);
        vm.assertEq(_p.balance, previousBalance + extraBounty);
        vm.assertEq(protocolOwner.balance, 5 ether - extraBounty);
    }

    function testAddBountyRevertsWhenNoValueSent() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ValueRequired.selector);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.addBounty(id);
    }

    function testAddBountyRevertsWhenCalledByNonOwner() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.deal(random, 1 ether);
        vm.expectRevert();
        vm.prank(random);
        registry.addBounty{value: 1 ether}(id);
    }

    function testAddBountyRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.addBounty{value: 1 ether}(nonExistentId);
    }

    function testRemainingCheckInsRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ProtocolNotFound.selector, nonExistentId);
        vm.expectRevert(expectedError);
        registry.remainingCheckIns(nonExistentId);
    }

    function testRemainingCheckInsReturnsZeroWhenFeeIsZero() public {
        uint256 id = register(1 ether, 0, 1.5 ether);
        DeSecRegistry registry = factory.registry();
        vm.assertEq(registry.remainingCheckIns(id), 0);
    }

    function testRemainingCheckInsReturnsFundedChecks() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.assertEq(registry.remainingCheckIns(id), 1000);
    }

    function testRemainingCheckInsUpdatesWhenOwnerChangesCheckInFee() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.assertEq(registry.remainingCheckIns(id), 1000);
        vm.prank(protocolOwner);
        registry.updateCheckInFee(id, 0.01 ether);
        vm.assertEq(registry.remainingCheckIns(id), 100);
    }

    function testRemainingCheckInsReturnsZeroAfterOwnerSetsFeeToZero() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.assertGt(registry.remainingCheckIns(id), 0);
        vm.prank(protocolOwner);
        registry.updateCheckInFee(id, 0);
        vm.assertEq(registry.remainingCheckIns(id), 0);
    }

    function testUpdateCheckInFeeOwnerUpdatesFee() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.CheckInFeeUpdated(id, 0.001 ether, 0.01 ether);
        vm.prank(protocolOwner);
        registry.updateCheckInFee(id, 0.01 ether);
        DeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.checkInFee, 0.01 ether);
    }

    function testUpdateCheckInFeeOwnerCanSetFeeToZero() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.prank(protocolOwner);
        registry.updateCheckInFee(id, 0);
        DeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.checkInFee, 0);
    }

    function testUpdateCheckInFeeRevertsWhenCalledByNonOwner() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.updateCheckInFee(id, 0.01 ether);
    }

    function testUpdateCheckInFeeRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.updateCheckInFee(nonExistentId, 0.01 ether);
    }

    function testUpdateIntervalOwnerUpdatesInterval() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.IntervalUpdated(id, 5 minutes, 10 minutes);
        vm.prank(protocolOwner);
        registry.updateInterval(id, 10 minutes);
        DeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.interval, 10 minutes);
    }

    function testUpdateIntervalAllowsExactlyMinimumInterval() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        uint32 minimum = registry.MINIMUM_INTERVAL();
        vm.prank(protocolOwner);
        registry.updateInterval(id, minimum);
        DeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.interval, minimum);
    }

    function testUpdateIntervalRevertsWhenBelowMinimum() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        uint32 tooShort = 30 seconds;
        bytes memory expectedError = abi.encodeWithSelector(
            DeSecRegistry.InvalidIntervalDuration.selector, tooShort, registry.MINIMUM_INTERVAL()
        );
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.updateInterval(id, tooShort);
    }

    function testUpdateIntervalRevertsWhenCalledByNonOwner() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.updateInterval(id, 10 minutes);
    }

    function testUpdateIntervalRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.updateInterval(nonExistentId, 10 minutes);
    }

    function testOwnerUpdatesCheckInFeeAndIntervalTogether() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.assertEq(registry.remainingCheckIns(id), 1000);
        vm.startPrank(protocolOwner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.CheckInFeeUpdated(id, 0.001 ether, 0.01 ether);
        registry.updateCheckInFee(id, 0.01 ether);
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.IntervalUpdated(id, 5 minutes, 10 minutes);
        registry.updateInterval(id, 10 minutes);
        vm.stopPrank();
        DeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.checkInFee, 0.01 ether);
        vm.assertEq(_p.interval, 10 minutes);
        vm.assertEq(registry.remainingCheckIns(id), 100);
    }

    function testDeRegisterOwnerReclaimsBalanceAndRecordIsDeleted() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.ProtocolDeregistered(id);
        vm.prank(protocolOwner);
        registry.deRegister(id);
        vm.assertEq(protocolOwner.balance, 10 ether);
        vm.assertEq(address(registry).balance, 0);
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ProtocolNotFound.selector, id);
        vm.expectRevert(expectedError);
        registry.getProtocol(id);
    }

    function testDeRegisterRevertsWhenOwnerCannotReceiveEther() public {
        (, uint256 id) = factory.register{value: 5 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            5 minutes,
            address(mockProtocol)
        );
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        vm.prank(address(mockProtocol));
        registry.deRegister(id);
    }

    function testTopUpOwnerIncreasesBalance() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.BalanceUpdated(id, 2 ether, 3 ether);
        vm.prank(protocolOwner);
        registry.topUp{value: 1 ether}(id);
        DeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.balance, 3 ether);
        vm.assertEq(protocolOwner.balance, 4 ether);
    }

    function testTopUpRevertsWhenNoValueSent() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ValueRequired.selector);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.topUp(id);
    }

    function testTopUpRevertsWhenCalledByNonOwner() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.deal(random, 1 ether);
        vm.expectRevert();
        vm.prank(random);
        registry.topUp{value: 1 ether}(id);
    }

    function testTopUpRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.topUp{value: 1 ether}(nonExistentId);
    }

    function testTopUpExtendsRemainingCheckIns() public {
        uint256 id = register(1 ether, 0.001 ether, 1.5 ether);
        DeSecRegistry registry = factory.registry();
        vm.assertEq(registry.remainingCheckIns(id), 500);
        vm.prank(protocolOwner);
        registry.topUp{value: 0.5 ether}(id);
        vm.assertEq(registry.remainingCheckIns(id), 1000);
    }

    function testLastCheckInReturnsRegistrationTimestamp() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.assertEq(registry.lastCheckIn(id), block.timestamp);
    }

    function testLastCheckInRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ProtocolNotFound.selector, nonExistentId);
        vm.expectRevert(expectedError);
        registry.lastCheckIn(nonExistentId);
    }

    function register(uint256 bounty, uint256 checkInFee, uint256 value) private returns (uint256) {
        (, uint256 protocolId) = factory.register{value: value}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            bounty,
            checkInFee,
            5 minutes,
            protocolOwner
        );
        return protocolId;
    }

    function testOwnerCannotTouchAnotherProtocolsRecord() public {
        address secondOwner = makeAddr("Second_Owner");
        uint256 firstId = register(1 ether, 0.001 ether, 2 ether);
        (, uint256 secondId) = factory.register{value: 2 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            1 ether,
            0.001 ether,
            5 minutes,
            secondOwner
        );
        DeSecRegistry registry = factory.registry();
        vm.deal(secondOwner, 1 ether);
        vm.expectRevert();
        vm.prank(secondOwner);
        registry.topUp{value: 0.5 ether}(firstId);
        vm.prank(secondOwner);
        registry.topUp{value: 0.5 ether}(secondId);
        DeSecRegistry.Protocol memory p = registry.getProtocol(secondId);
        vm.assertEq(p.balance, 2.5 ether);
    }

    function testOwnerCannotUpdateAnotherProtocolsCheckInFee() public {
        address secondOwner = makeAddr("Second_Owner");
        uint256 firstId = register(1 ether, 0.001 ether, 2 ether);
        (, uint256 secondId) = factory.register{value: 2 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            1 ether,
            0.001 ether,
            5 minutes,
            secondOwner
        );
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(secondOwner);
        registry.updateCheckInFee(firstId, 0.01 ether);
        vm.prank(secondOwner);
        registry.updateCheckInFee(secondId, 0.01 ether);
        DeSecRegistry.Protocol memory p = registry.getProtocol(secondId);
        vm.assertEq(p.checkInFee, 0.01 ether);
    }

    function testWithdrawOwnerWithdrawsAboveBounty() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.BalanceUpdated(id, 5 ether, 4.5 ether);
        vm.prank(protocolOwner);
        registry.withdraw(id, 0.5 ether);
        DeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.balance, 4.5 ether);
        vm.assertEq(protocolOwner.balance, 5.5 ether);
    }

    function testWithdrawAllowsExactAvailableBalance() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.prank(protocolOwner);
        registry.withdraw(id, 1 ether);
        DeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.balance, p.bounty);
        vm.assertEq(protocolOwner.balance, 6 ether);
    }

    function testWithdrawRevertsAboveAvailableBalance() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        uint256 amount = 1 ether + 1 wei;
        bytes memory expectedError =
            abi.encodeWithSelector(DeSecRegistry.InSufficientWithdrawableBalance.selector, amount, 1 ether);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.withdraw(id, amount);
    }

    function testWithdrawRevertsWhenAmountIsZero() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ValueRequired.selector);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.withdraw(id, 0);
    }

    function testWithdrawRevertsWhenCalledByNonOwner() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.withdraw(id, 0.5 ether);
    }

    function testWithdrawRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.withdraw(nonExistentId, 0.5 ether);
    }

    function testWithdrawRevertsWhenOwnerCannotReceiveEther() public {
        (, uint256 id) = factory.register{value: 5 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            4 ether,
            1e6 wei,
            5 minutes,
            address(mockProtocol)
        );
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        vm.prank(address(mockProtocol));
        registry.withdraw(id, 0.5 ether);
    }

    // ==============================================
    // Invariant gate tests
    // ==============================================

    function testMockProtocolBreakHealthFlipsInvariant() public {
        vm.assertTrue(mockProtocol.isHealthy());
        mockProtocol.breakHealth();
        vm.assertFalse(mockProtocol.isHealthy());
    }

    function testRegistrationRevertsWhenInvariantTargetHasNoCode() public {
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.NoCodeAtTarget.selector, random);
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            random, bytes4(0xdeadbeef), mockProtocol.pause.selector, 1 ether, 0.001 ether, 5 minutes, protocolOwner
        );
    }

    function testRegistrationRevertsWhenInvariantReverts() public {
        MockRevertingInvariant bad = new MockRevertingInvariant();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            address(bad),
            bad.isHealthy.selector,
            mockProtocol.pause.selector,
            1 ether,
            0.001 ether,
            5 minutes,
            protocolOwner
        );
    }

    function testRegistrationRevertsWhenInvariantReturnsGarbage() public {
        MockGarbageInvariant garbage = new MockGarbageInvariant();
        vm.expectRevert();
        factory.register{value: 2 ether}(
            address(garbage),
            bytes4(0xdeadbeef),
            mockProtocol.pause.selector,
            1 ether,
            0.001 ether,
            5 minutes,
            protocolOwner
        );
    }

    function testRegistrationRevertsWhenSelectorDoesNotExist() public {
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            address(mockProtocol),
            bytes4(0xdeadbeef),
            mockProtocol.pause.selector,
            1 ether,
            0.001 ether,
            5 minutes,
            protocolOwner
        );
    }

    function testRegistrationRevertsWhenInvariantCurrentlyBroken() public {
        mockProtocol.breakHealth();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.InvariantCurrentlyBroken.selector);
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            1 ether,
            0.001 ether,
            5 minutes,
            protocolOwner
        );
    }

    function testUpdateInvariantOwnerUpdatesInvariant() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.InvariantUpdated(id, mockProtocol.isHealthy.selector, mockProtocol.healthy.selector);
        vm.prank(protocolOwner);
        registry.updateInvariant(id, mockProtocol.healthy.selector);
        DeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.invariantSelector, mockProtocol.healthy.selector);
    }

    function testUpdateInvariantRevertsWhenCalledByNonOwner() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.updateInvariant(id, mockProtocol.healthy.selector);
    }

    function testUpdateInvariantRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.updateInvariant(nonExistentId, mockProtocol.healthy.selector);
    }

    function testUpdateInvariantRevertsWhenNewInvariantIsBroken() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        mockProtocol.breakHealth();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.InvariantCurrentlyBroken.selector);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.updateInvariant(id, mockProtocol.isHealthy.selector);
    }

    function testUpdateInvariantRevertsWhenSelectorDoesNotExist() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.updateInvariant(id, bytes4(0xdeadbeef));
    }

    function testUpdateEmergencyActionOwnerUpdatesSelector() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit DeSecRegistry.EmergencyActionUpdated(id, mockProtocol.pause.selector, mockProtocol.breakHealth.selector);
        vm.prank(protocolOwner);
        registry.updateEmergencyAction(id, mockProtocol.breakHealth.selector);
        DeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.emergencySelector, mockProtocol.breakHealth.selector);
    }

    function testUpdateEmergencyActionRevertsWhenCalledByNonOwner() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.updateEmergencyAction(id, mockProtocol.breakHealth.selector);
    }

    function testUpdateEmergencyActionRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.updateEmergencyAction(nonExistentId, mockProtocol.breakHealth.selector);
    }

    // ==============================================
    // Fuzz tests
    // ==============================================

    function testFuzzWithdrawWithinAvailableBalance(uint256 amount) public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        amount = bound(amount, 1 wei, 1 ether);
        uint256 ownerBefore = protocolOwner.balance;
        vm.prank(protocolOwner);
        registry.withdraw(id, amount);
        DeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.balance, 5 ether - amount);
        vm.assertGe(p.balance, p.bounty);
        vm.assertEq(protocolOwner.balance, ownerBefore + amount);
    }

    function testFuzzWithdrawRevertsAboveAvailableBalance(uint256 amount) public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        amount = bound(amount, 1 ether + 1 wei, 10 ether);
        bytes memory expectedError =
            abi.encodeWithSelector(DeSecRegistry.InSufficientWithdrawableBalance.selector, amount, 1 ether);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.withdraw(id, amount);
    }

    function testFuzzRegistrationSucceedsWithValidAmounts(uint256 bounty, uint256 checkInFee, uint256 extra) public {
        DeSecRegistry registry = factory.registry();
        bounty = bound(bounty, registry.MINIMUM_REGISTRATION_FEE(), 100 ether);
        checkInFee = bound(checkInFee, 0, 10 ether);
        uint256 value = bounty + checkInFee + bound(extra, 0, 10 ether);

        (address adapter, uint256 protocolId) = factory.register{value: value}(
            address(mockProtocol),
            mockProtocol.isHealthy.selector,
            mockProtocol.pause.selector,
            bounty,
            checkInFee,
            5 minutes,
            protocolOwner
        );

        DeSecRegistry.Protocol memory _p = registry.getProtocol(protocolId);
        vm.assertTrue(adapter.code.length > 0);
        vm.assertEq(_p.owner, protocolOwner);
        vm.assertEq(_p.bounty, bounty);
        vm.assertEq(_p.checkInFee, checkInFee);
        vm.assertEq(_p.balance, value);
    }
}

