// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {IDeSecRegistry} from "../src/interfaces/IDeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../src/GuardianAdapter.sol";
import {GuardianExecutor} from "../src/GuardianExecutor.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {MockRevertingInvariant} from "./mocks/MockRevertingInvariant.sol";
import {MockGarbageInvariant} from "./mocks/MockGarbageInvariant.sol";
import {console} from "forge-std/console.sol";

contract DeSecRegistryTest is Test {
    address protocolOwner = makeAddr("Protocol_Owner");
    address random = makeAddr("Random_Account");
    MockProtocol mockProtocol;
    GuardianAdapterFactory private factory;
    bytes invariantPayload = abi.encodeCall(MockProtocol.isHealthy, ());
    bytes emergencyPayload = abi.encodeCall(MockProtocol.pause, ());
    bytes healthyPayload = abi.encodeCall(MockProtocol.checkHealth, ());
    bytes breakHealthPayload = abi.encodeCall(MockProtocol.breakHealth, ());

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
        emit IDeSecRegistry.Registered(address(0), address(mockProtocol), expectedId);
        (address adapter, uint256 protocolId) = factory.register{value: 5 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 4 ether, 1e6 wei, 5 minutes, protocolOwner
        );
        vm.stopPrank();
        vm.assertTrue(adapter.code.length > 0);
        vm.assertEq(protocolOwner, GuardianAdapter(adapter).owner());
        vm.assertEq(protocolOwner.balance, 0);
        IDeSecRegistry.Protocol memory _p = factory.registry().getProtocol(protocolId);
        vm.assertEq(protocolId, _p.protocolId);
        vm.assertEq(address(mockProtocol), _p.protocol);
        vm.assertEq(address(_p.adapter), adapter);
        vm.assertEq(GuardianAdapter(adapter).owner(), protocolOwner);
        vm.assertEq(4 ether, _p.bounty);
        vm.assertEq(5 minutes, _p.interval);
        vm.assertEq(1e6, _p.checkInFee);
        vm.assertEq(5 ether, _p.balance);
        vm.assertEq(_p.invariantPayload, invariantPayload);
        vm.assertEq(_p.emergencyPayload, emergencyPayload);
        vm.assertEq(block.timestamp, _p.lastCheckIn);
        vm.assertEq(block.timestamp, _p.registrationTime);
    }

    function testRegistrationNoValue() public {
        uint256 bounty = 4 ether;
        uint256 checkInFee = 1e6 wei;
        // registration reverts if no value passed
        bytes memory expectedError = abi.encodeWithSelector(
            IDeSecRegistry.InvalidRegistrationAmounts.selector,
            0,
            bounty,
            checkInFee,
            factory.registry().MINIMUM_REGISTRATION_FEE()
        );
        vm.expectRevert(expectedError);
        factory.register(
            address(mockProtocol), invariantPayload, emergencyPayload, bounty, checkInFee, 5 minutes, protocolOwner
        );
    }

    function testRegistrationNoBounty() public {
        uint256 value = 2 ether;
        uint256 checkInFee = 1e6 wei;
        // registration reverts if no bounty passed
        bytes memory expectedError = abi.encodeWithSelector(
            IDeSecRegistry.InvalidRegistrationAmounts.selector,
            value,
            0,
            checkInFee,
            factory.registry().MINIMUM_REGISTRATION_FEE()
        );
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 0, checkInFee, 2 minutes, protocolOwner
        );
    }

    function testRegistrationInsufficientBountyValue() public {
        // registration reverts if the value passed cannot satisfy the bounty
        uint256 bounty = 7 ether;
        uint256 checkInFee = 1e6 wei;
        uint32 duration = 1 hours;
        uint256 passed = 4 ether + checkInFee;

        bytes memory expectedError = abi.encodeWithSelector(
            IDeSecRegistry.InvalidRegistrationAmounts.selector,
            passed,
            bounty,
            checkInFee,
            factory.registry().MINIMUM_REGISTRATION_FEE()
        );

        vm.expectRevert(expectedError);
        factory.register{value: passed}(
            address(mockProtocol), invariantPayload, emergencyPayload, bounty, checkInFee, duration, protocolOwner
        );
    }

    function testRegistrationInsufficientCheckInValue() public {
        // registration reverts if the value passed cannot satisfy the check in fees
        uint256 bounty = 1 ether;
        uint256 checkInFee = 0.01 ether;
        uint32 interval = 1 hours;
        uint256 passed = 1.001 ether;

        bytes memory expectedError = abi.encodeWithSelector(
            IDeSecRegistry.InvalidRegistrationAmounts.selector,
            passed,
            bounty,
            checkInFee,
            factory.registry().MINIMUM_REGISTRATION_FEE()
        );

        vm.expectRevert(expectedError);
        factory.register{value: passed}(
            address(mockProtocol), invariantPayload, emergencyPayload, bounty, checkInFee, interval, protocolOwner
        );
    }

    function testRegistrationInvalidDuration() public {
        // someone tries to register with less than the minimum duration
        uint32 invalidDuration = 10 seconds;
        bytes memory expectedError = abi.encodeWithSelector(
            IDeSecRegistry.InvalidIntervalDuration.selector, invalidDuration, factory.registry().MINIMUM_INTERVAL()
        );
        vm.expectRevert(expectedError);
        factory.register{value: 5 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 4 ether, 1e6 wei, invalidDuration, protocolOwner
        );
    }

    function testAddBountyOwnerIncreasesBountyAndBalance() public {
        uint256 extraBounty = 1 ether;
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        IDeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        uint256 previousBounty = _p.bounty;
        uint256 previousBalance = _p.balance;

        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeSecRegistry.BountyUpdated(id, previousBounty, previousBounty + extraBounty);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeSecRegistry.BalanceUpdated(id, previousBalance, previousBalance + extraBounty);

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
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ValueRequired.selector);
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
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ProtocolNotFound.selector, nonExistentId);
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
        emit IDeSecRegistry.CheckInFeeUpdated(id, 0.001 ether, 0.01 ether);
        vm.prank(protocolOwner);
        registry.updateCheckInFee(id, 0.01 ether);
        IDeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.checkInFee, 0.01 ether);
    }

    function testUpdateCheckInFeeOwnerCanSetFeeToZero() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.prank(protocolOwner);
        registry.updateCheckInFee(id, 0);
        IDeSecRegistry.Protocol memory _p = registry.getProtocol(id);
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
        emit IDeSecRegistry.IntervalUpdated(id, 5 minutes, 10 minutes);
        vm.prank(protocolOwner);
        registry.updateInterval(id, 10 minutes);
        IDeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.interval, 10 minutes);
    }

    function testUpdateIntervalAllowsExactlyMinimumInterval() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        uint32 minimum = registry.MINIMUM_INTERVAL();
        vm.prank(protocolOwner);
        registry.updateInterval(id, minimum);
        IDeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.interval, minimum);
    }

    function testUpdateIntervalRevertsWhenBelowMinimum() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        uint32 tooShort = 30 seconds;
        bytes memory expectedError = abi.encodeWithSelector(
            IDeSecRegistry.InvalidIntervalDuration.selector, tooShort, registry.MINIMUM_INTERVAL()
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
        emit IDeSecRegistry.CheckInFeeUpdated(id, 0.001 ether, 0.01 ether);
        registry.updateCheckInFee(id, 0.01 ether);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDeSecRegistry.IntervalUpdated(id, 5 minutes, 10 minutes);
        registry.updateInterval(id, 10 minutes);
        vm.stopPrank();
        IDeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.checkInFee, 0.01 ether);
        vm.assertEq(_p.interval, 10 minutes);
        vm.assertEq(registry.remainingCheckIns(id), 100);
    }

    function testDeRegisterOwnerReclaimsBalanceAndRecordIsDeleted() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDeSecRegistry.ProtocolDeregistered(id);
        vm.prank(protocolOwner);
        registry.deRegister(id);
        vm.assertEq(protocolOwner.balance, 10 ether);
        vm.assertEq(address(registry).balance, 0);
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ProtocolNotFound.selector, id);
        vm.expectRevert(expectedError);
        registry.getProtocol(id);
    }

    function testDeRegisterRevertsWhenOwnerCannotReceiveEther() public {
        (, uint256 id) = factory.register{value: 5 ether}(
            address(mockProtocol),
            invariantPayload,
            emergencyPayload,
            4 ether,
            1e6 wei,
            5 minutes,
            address(mockProtocol)
        );
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        vm.prank(address(mockProtocol));
        registry.deRegister(id);
    }

    function testTopUpOwnerIncreasesBalance() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDeSecRegistry.BalanceUpdated(id, 2 ether, 3 ether);
        vm.prank(protocolOwner);
        registry.topUp{value: 1 ether}(id);
        IDeSecRegistry.Protocol memory _p = registry.getProtocol(id);
        vm.assertEq(_p.balance, 3 ether);
        vm.assertEq(protocolOwner.balance, 4 ether);
    }

    function testTopUpRevertsWhenNoValueSent() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ValueRequired.selector);
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
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ProtocolNotFound.selector, nonExistentId);
        vm.expectRevert(expectedError);
        registry.lastCheckIn(nonExistentId);
    }

    function register(uint256 bounty, uint256 checkInFee, uint256 value) private returns (uint256) {
        (, uint256 protocolId) = factory.register{value: value}(
            address(mockProtocol), invariantPayload, emergencyPayload, bounty, checkInFee, 5 minutes, protocolOwner
        );
        return protocolId;
    }

    function testOwnerCannotTouchAnotherProtocolsRecord() public {
        address secondOwner = makeAddr("Second_Owner");
        uint256 firstId = register(1 ether, 0.001 ether, 2 ether);
        (, uint256 secondId) = factory.register{value: 2 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 1 ether, 0.001 ether, 5 minutes, secondOwner
        );
        DeSecRegistry registry = factory.registry();
        vm.deal(secondOwner, 1 ether);
        vm.expectRevert();
        vm.prank(secondOwner);
        registry.topUp{value: 0.5 ether}(firstId);
        vm.prank(secondOwner);
        registry.topUp{value: 0.5 ether}(secondId);
        IDeSecRegistry.Protocol memory p = registry.getProtocol(secondId);
        vm.assertEq(p.balance, 2.5 ether);
    }

    function testOwnerCannotUpdateAnotherProtocolsCheckInFee() public {
        address secondOwner = makeAddr("Second_Owner");
        uint256 firstId = register(1 ether, 0.001 ether, 2 ether);
        (, uint256 secondId) = factory.register{value: 2 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 1 ether, 0.001 ether, 5 minutes, secondOwner
        );
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(secondOwner);
        registry.updateCheckInFee(firstId, 0.01 ether);
        vm.prank(secondOwner);
        registry.updateCheckInFee(secondId, 0.01 ether);
        IDeSecRegistry.Protocol memory p = registry.getProtocol(secondId);
        vm.assertEq(p.checkInFee, 0.01 ether);
    }

    function testWithdrawOwnerWithdrawsAboveBounty() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDeSecRegistry.BalanceUpdated(id, 5 ether, 4.5 ether);
        vm.prank(protocolOwner);
        registry.withdraw(id, 0.5 ether);
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.balance, 4.5 ether);
        vm.assertEq(protocolOwner.balance, 5.5 ether);
    }

    function testWithdrawAllowsExactAvailableBalance() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.prank(protocolOwner);
        registry.withdraw(id, 1 ether);
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.balance, p.bounty);
        vm.assertEq(protocolOwner.balance, 6 ether);
    }

    function testWithdrawRevertsAboveAvailableBalance() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        uint256 amount = 1 ether + 1 wei;
        bytes memory expectedError =
            abi.encodeWithSelector(IDeSecRegistry.InSufficientWithdrawableBalance.selector, amount, 1 ether);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.withdraw(id, amount);
    }

    function testWithdrawRevertsWhenAmountIsZero() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ValueRequired.selector);
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
            invariantPayload,
            emergencyPayload,
            4 ether,
            1e6 wei,
            5 minutes,
            address(mockProtocol)
        );
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        vm.prank(address(mockProtocol));
        registry.withdraw(id, 0.5 ether);
    }

    function testOwnershipRotationThroughAdapterTransfersAdminRights() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        GuardianAdapter protocolAdapter = GuardianAdapter(address(p.adapter));
        address newOwner = makeAddr("New_Owner");
        vm.deal(newOwner, 1 ether);

        vm.prank(protocolOwner);
        protocolAdapter.transferOwnership(newOwner);

        vm.expectRevert();
        vm.prank(newOwner);
        registry.topUp{value: 0.5 ether}(id);

        vm.prank(newOwner);
        protocolAdapter.acceptOwnership();

        vm.expectEmit(true, false, false, true, address(registry));
        emit IDeSecRegistry.BalanceUpdated(id, 2 ether, 2.5 ether);
        vm.prank(newOwner);
        registry.topUp{value: 0.5 ether}(id);

        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.topUp{value: 0.5 ether}(id);

        p = registry.getProtocol(id);
        vm.assertEq(p.balance, 2.5 ether);
    }

    function testExecutorIsWiredAtDeployment() public {
        DeSecRegistry registry = factory.registry();
        vm.assertEq(address(registry.executor()), address(factory.executor()));
    }

    function testSetExecutorRevertsWhenCalledByNonFactory() public {
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.setExecutor(GuardianExecutor(random));
    }

    function testSetExecutorRevertsWhenAlreadySet() public {
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ExecutorAlreadySet.selector);
        vm.expectRevert(expectedError);
        vm.prank(address(factory));
        registry.setExecutor(GuardianExecutor(random));
    }

    // ==============================================
    // Bounty award guard tests
    // ==============================================

    function testAwardBountyRevertsWhenCallerIsNotExecutor() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.awardBounty(id, random);
    }

    function testAwardBountyRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        address executor = address(factory.executor());
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ProtocolNotFound.selector, nonExistentId);
        vm.expectRevert(expectedError);
        vm.prank(executor);
        registry.awardBounty(nonExistentId, random);
    }

    function testAwardBountyRevertsWhenRecordIsUnderwater() public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        address executor = address(factory.executor());
        mockProtocol.breakHealth();
        vm.prank(executor);
        registry.awardBounty(id, random);
        bytes memory expectedError =
            abi.encodeWithSelector(IDeSecRegistry.InsufficientProtocolBalance.selector, id, 1 ether, 4 ether);
        vm.expectRevert(expectedError);
        vm.prank(executor);
        registry.awardBounty(id, random);
    }

    function testRegisterDefaultsOwnerToCallerWhenZeroOwnerPassed() public {
        (address adapter, uint256 id) = factory.register{value: 2 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 1 ether, 0.001 ether, 5 minutes, address(0)
        );
        DeSecRegistry registry = factory.registry();
        vm.assertEq(GuardianAdapter(adapter).owner(), address(this));
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(GuardianAdapter(address(p.adapter)).owner(), address(this));
    }

    function testDeRegisterRevertsWhenCalledByNonOwner() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.deRegister(id);
    }

    function testRegistryConstructorRevertsWhenFactoryIsZero() public {
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ZeroAddress.selector);
        vm.expectRevert(expectedError);
        new DeSecRegistry(GuardianAdapterFactory(address(0)), protocolOwner);
    }

    function testRegistryConstructorRevertsWhenFeeRecipientIsZero() public {
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ZeroAddress.selector);
        vm.expectRevert(expectedError);
        new DeSecRegistry(GuardianAdapterFactory(address(1)), address(0));
    }

    // ==============================================
    // Network fees
    // ==============================================

    function testFeeRecipientIsFactoryDeployer() public {
        DeSecRegistry registry = factory.registry();
        vm.assertEq(registry.feeRecipient(), address(this));
    }

    function testReportSkimsNetworkFeeFromBounty() public {
        DeSecRegistry registry = factory.registry();
        GuardianExecutor executor = factory.executor();
        vm.prank(protocolOwner);
        (, uint256 id) = factory.register{value: 5 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 4 ether, 1e6 wei, 5 minutes, protocolOwner
        );
        mockProtocol.breakHealth();
        address watcher = makeAddr("Watcher");
        vm.prank(watcher);
        executor.report(id);
        vm.assertEq(registry.claimableBounties(watcher, id), 3.96 ether);
        vm.assertEq(registry.networkFees(), 0.04 ether);
        vm.assertEq(registry.totalAwarded(), 3.96 ether);
    }

    function testDonationsThroughReceiveIncrementNetworkFees() public {
        DeSecRegistry registry = factory.registry();
        vm.deal(address(this), 2 ether);
        (bool success,) = address(registry).call{value: 1 ether}("");
        vm.assertTrue(success);
        vm.assertEq(registry.networkFees(), 1 ether);
    }

    function testDonationsThroughFallbackIncrementNetworkFees() public {
        DeSecRegistry registry = factory.registry();
        vm.deal(address(this), 2 ether);
        (bool success,) = address(registry).call{value: 1 ether}(hex"deadbeef");
        vm.assertTrue(success);
        vm.assertEq(registry.networkFees(), 1 ether);
    }

    function testWithdrawNetworkFeesTransfersToRecipient() public {
        DeSecRegistry registry = factory.registry();
        address network = makeAddr("Network_Treasury");
        registry.transferFeeRecipient(network);
        vm.prank(network);
        registry.acceptFeeRecipient();
        vm.deal(address(this), 2 ether);
        (bool success,) = address(registry).call{value: 1 ether}("");
        vm.assertTrue(success);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDeSecRegistry.NetworkFeesWithdrawn(network, 1 ether);
        vm.prank(network);
        registry.withdrawNetworkFees();
        vm.assertEq(network.balance, 1 ether);
        vm.assertEq(registry.networkFees(), 0);
    }

    function testWithdrawNetworkFeesRevertsWhenNoFees() public {
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.NoNetworkFees.selector);
        vm.expectRevert(expectedError);
        registry.withdrawNetworkFees();
    }

    function testWithdrawNetworkFeesRevertsWhenCalledByNonRecipient() public {
        DeSecRegistry registry = factory.registry();
        vm.deal(address(this), 2 ether);
        (bool success,) = address(registry).call{value: 1 ether}("");
        vm.assertTrue(success);
        vm.expectRevert();
        vm.prank(random);
        registry.withdrawNetworkFees();
    }

    function testTransferFeeRecipientStartsRotation() public {
        DeSecRegistry registry = factory.registry();
        address network = makeAddr("Network_Treasury");
        vm.expectEmit(true, true, false, false, address(registry));
        emit IDeSecRegistry.FeeRecipientTransferStarted(address(this), network);
        registry.transferFeeRecipient(network);
        vm.assertEq(registry.pendingFeeRecipient(), network);
        vm.assertEq(registry.feeRecipient(), address(this));
    }

    function testTransferFeeRecipientRevertsWhenCalledByNonRecipient() public {
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.transferFeeRecipient(makeAddr("Network_Treasury"));
    }

    function testTransferFeeRecipientRevertsToZeroAddress() public {
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ZeroAddress.selector);
        vm.expectRevert(expectedError);
        registry.transferFeeRecipient(address(0));
    }

    function testAcceptFeeRecipientCompletesRotation() public {
        DeSecRegistry registry = factory.registry();
        address network = makeAddr("Network_Treasury");
        registry.transferFeeRecipient(network);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IDeSecRegistry.FeeRecipientTransferred(address(this), network);
        vm.prank(network);
        registry.acceptFeeRecipient();
        vm.assertEq(registry.feeRecipient(), network);
        vm.assertEq(registry.pendingFeeRecipient(), address(0));
    }

    function testAcceptFeeRecipientRevertsWhenCalledByWrongAccount() public {
        DeSecRegistry registry = factory.registry();
        registry.transferFeeRecipient(makeAddr("Network_Treasury"));
        vm.expectRevert();
        vm.prank(random);
        registry.acceptFeeRecipient();
    }

    function testOldRecipientCannotWithdrawAfterRotation() public {
        DeSecRegistry registry = factory.registry();
        address network = makeAddr("Network_Treasury");
        registry.transferFeeRecipient(network);
        vm.prank(network);
        registry.acceptFeeRecipient();
        vm.deal(address(this), 2 ether);
        (bool success,) = address(registry).call{value: 1 ether}("");
        vm.assertTrue(success);
        vm.expectRevert();
        registry.withdrawNetworkFees();
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
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.NoCodeAtTarget.selector, random);
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            random, hex"deadbeef", emergencyPayload, 1 ether, 0.001 ether, 5 minutes, protocolOwner
        );
    }

    function testRegistrationRevertsWhenInvariantReverts() public {
        MockRevertingInvariant bad = new MockRevertingInvariant();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            address(bad),
            abi.encodeCall(MockRevertingInvariant.isHealthy, ()),
            emergencyPayload,
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
            address(garbage), hex"deadbeef", emergencyPayload, 1 ether, 0.001 ether, 5 minutes, protocolOwner
        );
    }

    function testRegistrationRevertsWhenPayloadMatchesNoFunction() public {
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            address(mockProtocol), hex"deadbeef", emergencyPayload, 1 ether, 0.001 ether, 5 minutes, protocolOwner
        );
    }

    function testRegistrationRevertsWhenInvariantCurrentlyBroken() public {
        mockProtocol.breakHealth();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.InvariantCurrentlyBroken.selector);
        vm.expectRevert(expectedError);
        factory.register{value: 2 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 1 ether, 0.001 ether, 5 minutes, protocolOwner
        );
    }

    function testUpdateInvariantOwnerUpdatesInvariant() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDeSecRegistry.InvariantUpdated(id, invariantPayload, healthyPayload);
        vm.prank(protocolOwner);
        registry.updateInvariant(id, healthyPayload);
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.invariantPayload, healthyPayload);
    }

    function testUpdateInvariantRevertsWhenCalledByNonOwner() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.updateInvariant(id, healthyPayload);
    }

    function testUpdateInvariantRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.updateInvariant(nonExistentId, healthyPayload);
    }

    function testUpdateInvariantRevertsWhenNewInvariantIsBroken() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        mockProtocol.breakHealth();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.InvariantCurrentlyBroken.selector);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.updateInvariant(id, invariantPayload);
    }

    function testUpdateInvariantRevertsWhenPayloadMatchesNoFunction() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(IDeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.updateInvariant(id, hex"deadbeef");
    }

    function testUpdateEmergencyActionOwnerUpdatesPayload() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDeSecRegistry.EmergencyActionUpdated(id, emergencyPayload, breakHealthPayload);
        vm.prank(protocolOwner);
        registry.updateEmergencyAction(id, breakHealthPayload);
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.emergencyPayload, breakHealthPayload);
    }

    function testUpdateEmergencyActionRevertsWhenCalledByNonOwner() public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(random);
        registry.updateEmergencyAction(id, breakHealthPayload);
    }

    function testUpdateEmergencyActionRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        DeSecRegistry registry = factory.registry();
        vm.expectRevert();
        vm.prank(protocolOwner);
        registry.updateEmergencyAction(nonExistentId, breakHealthPayload);
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
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.balance, 5 ether - amount);
        vm.assertGe(p.balance, p.bounty);
        vm.assertEq(protocolOwner.balance, ownerBefore + amount);
    }

    function testFuzzWithdrawRevertsAboveAvailableBalance(uint256 amount) public {
        uint256 id = register(4 ether, 1e6 wei, 5 ether);
        DeSecRegistry registry = factory.registry();
        amount = bound(amount, 1 ether + 1 wei, 10 ether);
        bytes memory expectedError =
            abi.encodeWithSelector(IDeSecRegistry.InSufficientWithdrawableBalance.selector, amount, 1 ether);
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
            address(mockProtocol), invariantPayload, emergencyPayload, bounty, checkInFee, 5 minutes, protocolOwner
        );

        IDeSecRegistry.Protocol memory _p = registry.getProtocol(protocolId);
        vm.assertTrue(adapter.code.length > 0);
        vm.assertEq(GuardianAdapter(address(_p.adapter)).owner(), protocolOwner);
        vm.assertEq(_p.bounty, bounty);
        vm.assertEq(_p.checkInFee, checkInFee);
        vm.assertEq(_p.balance, value);
    }

    function testFuzzRemainingCheckInsMatchesArithmetic(uint256 bounty, uint256 checkInFee, uint256 extra) public {
        DeSecRegistry registry = factory.registry();
        bounty = bound(bounty, registry.MINIMUM_REGISTRATION_FEE(), 100 ether);
        checkInFee = bound(checkInFee, 0, 10 ether);
        uint256 value = bounty + checkInFee + bound(extra, 0, 10 ether);
        uint256 id = register(bounty, checkInFee, value);

        if (checkInFee == 0 || value <= bounty) {
            vm.assertEq(registry.remainingCheckIns(id), 0);
        } else {
            vm.assertEq(registry.remainingCheckIns(id), (value - bounty) / checkInFee);
        }
    }

    function testFuzzUpdateIntervalRespectsMinimum(uint32 interval) public {
        uint256 id = register(1 ether, 0.001 ether, 2 ether);
        DeSecRegistry registry = factory.registry();
        if (interval < registry.MINIMUM_INTERVAL()) {
            bytes memory expectedError = abi.encodeWithSelector(
                IDeSecRegistry.InvalidIntervalDuration.selector, interval, registry.MINIMUM_INTERVAL()
            );
            vm.expectRevert(expectedError);
            vm.prank(protocolOwner);
            registry.updateInterval(id, interval);
        } else {
            vm.prank(protocolOwner);
            registry.updateInterval(id, interval);
            IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
            vm.assertEq(p.interval, interval);
        }
    }
}

