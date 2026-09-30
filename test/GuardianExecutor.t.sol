// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../src/GuardianAdapter.sol";
import {GuardianExecutor} from "../src/GuardianExecutor.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {MockFlakyProtocol} from "./mocks/MockFlakyProtocol.sol";
import {console} from "forge-std/console.sol";

contract GuardianExecutorTest is Test {
    address protocolOwner = makeAddr("Protocol_Owner");
    address watcher = makeAddr("Watcher");
    address random = makeAddr("Random_Account");
    MockProtocol mockProtocol;
    GuardianAdapterFactory private factory;
    GuardianExecutor executor;
    DeSecRegistry registry;
    GuardianAdapter adapter;
    uint256 protocolId;
    bytes invariantPayload = abi.encodeCall(MockProtocol.isHealthy, ());
    bytes emergencyPayload = abi.encodeCall(MockProtocol.pause, ());

    function setUp() public {
        factory = new GuardianAdapterFactory();
        executor = factory.executor();
        registry = factory.registry();
        vm.deal(protocolOwner, 5 ether);
        vm.prank(protocolOwner);
        mockProtocol = new MockProtocol();

        vm.prank(protocolOwner);
        (address _adapter, uint256 _protocolId) = factory.register{value: 5 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 4 ether, 1e6 wei, 5 minutes, protocolOwner
        );
        adapter = GuardianAdapter(_adapter);
        protocolId = _protocolId;

        bytes32 pauserRole = mockProtocol.PAUSER_ROLE();
        vm.prank(protocolOwner);
        mockProtocol.grantRole(pauserRole, address(adapter));
    }

    // ==============================================
    // Happy path
    // ==============================================

    function testReportPausesProtocolWhenInvariantIsBroken() public {
        mockProtocol.breakHealth();
        vm.expectEmit(true, true, false, false, address(executor));
        emit GuardianExecutor.InvariantBreached(protocolId, address(mockProtocol));
        vm.expectEmit(true, true, true, true, address(executor));
        emit GuardianExecutor.EmergencyActionCalled(protocolId, address(mockProtocol), true);
        vm.prank(watcher);
        bool result = executor.report(protocolId);
        vm.assertTrue(result);
        vm.assertTrue(mockProtocol.paused());
    }

    // ==============================================
    // Invariant gate
    // ==============================================

    function testReportRevertsWhenInvariantIsHealthy() public {
        bytes memory expectedError = abi.encodeWithSelector(GuardianExecutor.InvariantNotBreached.selector);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        executor.report(protocolId);
    }

    function testReportRevertsWhenProtocolDoesNotExist() public {
        uint256 nonExistentId = 999;
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ProtocolNotFound.selector, nonExistentId);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        executor.report(nonExistentId);
    }

    function testReportRevertsWhenInvariantCallReverts() public {
        (MockFlakyProtocol flaky, uint256 id) = registerFlakyProtocol();
        flaky.setMode(MockFlakyProtocol.Mode.Reverting);
        bytes memory expectedError = abi.encodeWithSelector(GuardianExecutor.InvariantReverted.selector);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        executor.report(id);
    }

    function testReportRevertsWhenInvariantReturnsGarbage() public {
        (MockFlakyProtocol flaky, uint256 id) = registerFlakyProtocol();
        flaky.setMode(MockFlakyProtocol.Mode.Garbage);
        vm.expectRevert();
        vm.prank(watcher);
        executor.report(id);
    }

    // ==============================================
    // Emergency action
    // ==============================================

    function testReportSurvivesWhenAdapterLacksPauseRole() public {
        bytes32 pauserRole = mockProtocol.PAUSER_ROLE();
        vm.prank(protocolOwner);
        mockProtocol.revokeRole(pauserRole, address(adapter));
        mockProtocol.breakHealth();
        bytes memory expectedReason = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, address(adapter), mockProtocol.PAUSER_ROLE()
        );
        vm.expectEmit(true, true, false, false, address(executor));
        emit GuardianExecutor.InvariantBreached(protocolId, address(mockProtocol));
        vm.expectEmit(true, true, true, true, address(executor));
        emit GuardianExecutor.EmergencyActionFailed(protocolId, address(mockProtocol), expectedReason);
        vm.expectEmit(true, true, true, true, address(executor));
        emit GuardianExecutor.EmergencyActionCalled(protocolId, address(mockProtocol), false);
        vm.prank(watcher);
        bool result = executor.report(protocolId);
        vm.assertFalse(result);
        vm.assertFalse(mockProtocol.paused());
    }

    function testReportEmitsReasonWhenEmergencyRevertsWithCustomError() public {
        uint256 id = registerWithEmergencyPayload(abi.encodeCall(MockProtocol.pauseWithCustomError, ()));
        mockProtocol.breakHealth();
        bytes memory expectedReason = abi.encodeWithSelector(MockProtocol.PauseFailed.selector);
        vm.expectEmit(true, true, true, true, address(executor));
        emit GuardianExecutor.EmergencyActionFailed(id, address(mockProtocol), expectedReason);
        vm.prank(watcher);
        bool result = executor.report(id);
        vm.assertFalse(result);
        vm.assertFalse(mockProtocol.paused());
    }

    function testReportEmitsReasonWhenEmergencyRevertsSilently() public {
        uint256 id = registerWithEmergencyPayload(abi.encodeCall(MockProtocol.pauseSilently, ()));
        mockProtocol.breakHealth();
        bytes memory expectedReason = abi.encodeWithSelector(Errors.FailedCall.selector);
        vm.expectEmit(true, true, true, true, address(executor));
        emit GuardianExecutor.EmergencyActionFailed(id, address(mockProtocol), expectedReason);
        vm.prank(watcher);
        bool result = executor.report(id);
        vm.assertFalse(result);
        vm.assertFalse(mockProtocol.paused());
    }

    function testReportSkipsEmergencyActionForMonitoringOnlyProtocol() public {
        uint256 id = registerWithEmergencyPayload(bytes(""));
        mockProtocol.breakHealth();
        vm.recordLogs();
        vm.prank(watcher);
        bool result = executor.report(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.assertFalse(result);
        vm.assertEq(logs.length, 2);
        vm.assertEq(logs[0].topics[0], GuardianExecutor.InvariantBreached.selector);
        vm.assertEq(logs[0].emitter, address(executor));
        vm.assertEq(logs[1].topics[0], DeSecRegistry.BountyAwarded.selector);
        vm.assertEq(logs[1].emitter, address(registry));
    }

    function registerWithEmergencyPayload(bytes memory _emergencyPayload) internal returns (uint256) {
        vm.deal(protocolOwner, 5 ether);
        vm.prank(protocolOwner);
        (, uint256 id) = factory.register{value: 5 ether}(
            address(mockProtocol), invariantPayload, _emergencyPayload, 4 ether, 1e6 wei, 5 minutes, protocolOwner
        );
        return id;
    }

    function registerFlakyProtocol() internal returns (MockFlakyProtocol, uint256) {
        vm.prank(protocolOwner);
        MockFlakyProtocol flaky = new MockFlakyProtocol();
        vm.deal(protocolOwner, 5 ether);
        vm.prank(protocolOwner);
        (, uint256 id) = factory.register{value: 5 ether}(
            address(flaky),
            abi.encodeCall(MockFlakyProtocol.check, ()),
            abi.encodeCall(MockFlakyProtocol.pause, ()),
            4 ether,
            1e6 wei,
            5 minutes,
            protocolOwner
        );
        return (flaky, id);
    }

    // ==============================================
    // Bounty awards
    // ==============================================

    function testReportAwardsBountyToReporter() public {
        mockProtocol.breakHealth();
        vm.expectEmit(true, true, false, true, address(registry));
        emit DeSecRegistry.BountyAwarded(protocolId, watcher, 4 ether);
        vm.prank(watcher);
        bool result = executor.report(protocolId);
        vm.assertTrue(result);
        vm.assertEq(registry.totalAwarded(), 4 ether);
    }

    function testReportAwardsBountyWhenEmergencyActionFails() public {
        bytes32 pauserRole = mockProtocol.PAUSER_ROLE();
        vm.prank(protocolOwner);
        mockProtocol.revokeRole(pauserRole, address(adapter));
        mockProtocol.breakHealth();
        vm.expectEmit(true, true, false, true, address(registry));
        emit DeSecRegistry.BountyAwarded(protocolId, watcher, 4 ether);
        vm.prank(watcher);
        bool result = executor.report(protocolId);
        vm.assertFalse(result);
    }

    function testReportAwardsBountyForMonitoringOnlyProtocol() public {
        uint256 id = registerWithEmergencyPayload(bytes(""));
        mockProtocol.breakHealth();
        vm.expectEmit(true, true, false, true, address(registry));
        emit DeSecRegistry.BountyAwarded(id, watcher, 4 ether);
        vm.prank(watcher);
        executor.report(id);
    }

    function testReportRevertsDuringIncidentEvenAfterTopUp() public {
        enterIncident();
        vm.deal(protocolOwner, 10 ether);
        vm.prank(protocolOwner);
        registry.topUp{value: 10 ether}(protocolId);
        bytes memory expectedError = abi.encodeWithSelector(GuardianExecutor.IncidentActive.selector, protocolId);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        executor.report(protocolId);
    }

    function testClaimTransfersBountyToReporter() public {
        mockProtocol.breakHealth();
        vm.prank(watcher);
        executor.report(protocolId);
        vm.assertEq(registry.claimableBounties(watcher, protocolId), 4 ether);
        vm.expectEmit(true, true, false, true, address(registry));
        emit DeSecRegistry.BountyClaimed(protocolId, watcher, 4 ether);
        vm.prank(watcher);
        registry.claim(protocolId);
        vm.assertEq(watcher.balance, 4 ether);
        vm.assertEq(registry.claimableBounties(watcher, protocolId), 0);
        vm.assertEq(address(registry).balance, 1 ether);
    }

    function testClaimRevertsWhenClaimingTwice() public {
        mockProtocol.breakHealth();
        vm.prank(watcher);
        executor.report(protocolId);
        vm.prank(watcher);
        registry.claim(protocolId);
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.NoAvailableBounty.selector);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        registry.claim(protocolId);
    }

    function testClaimRevertsWhenNothingWasAwarded() public {
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.NoAvailableBounty.selector);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        registry.claim(protocolId);
    }

    function testWithdrawRevertsCleanlyWhenRecordIsUnderwater() public {
        mockProtocol.breakHealth();
        vm.prank(watcher);
        executor.report(protocolId);
        bytes memory expectedError =
            abi.encodeWithSelector(DeSecRegistry.InSufficientWithdrawableBalance.selector, 1 ether, 0);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.withdraw(protocolId, 1 ether);
    }

    function testClaimRevertsWhenBountyBelongsToAnotherUser() public {
        mockProtocol.breakHealth();
        vm.prank(watcher);
        executor.report(protocolId);
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.NoAvailableBounty.selector);
        vm.expectRevert(expectedError);
        vm.prank(random);
        registry.claim(protocolId);
    }

    function testClaimRevertsWhenProtocolDoesNotExist() public {
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.NoAvailableBounty.selector);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        registry.claim(999);
    }

    function testClaimRevertsWhenReporterCannotReceiveEther() public {
        mockProtocol.breakHealth();
        vm.prank(address(mockProtocol));
        executor.report(protocolId);
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.ActionFailed.selector, bytes(""));
        vm.expectRevert(expectedError);
        vm.prank(address(mockProtocol));
        registry.claim(protocolId);
        vm.assertEq(registry.claimableBounties(address(mockProtocol), protocolId), 4 ether);
    }

    function testClaimIsolatesBountiesBetweenWatchersAndProtocols() public {
        address secondWatcher = makeAddr("Second_Watcher");
        uint256 secondId = registerWithEmergencyPayload(bytes(""));
        mockProtocol.breakHealth();
        vm.prank(watcher);
        executor.report(protocolId);
        vm.prank(secondWatcher);
        executor.report(secondId);
        vm.prank(watcher);
        registry.claim(protocolId);
        vm.prank(secondWatcher);
        registry.claim(secondId);
        vm.assertEq(watcher.balance, 4 ether);
        vm.assertEq(secondWatcher.balance, 4 ether);
        vm.assertEq(registry.claimableBounties(watcher, secondId), 0);
        vm.assertEq(registry.claimableBounties(secondWatcher, protocolId), 0);
    }

    function testClaimSucceedsWhenBountyEqualsEntireRegistryBalance() public {
        GuardianAdapterFactory freshFactory = new GuardianAdapterFactory();
        GuardianExecutor freshExecutor = freshFactory.executor();
        DeSecRegistry freshRegistry = freshFactory.registry();
        vm.prank(protocolOwner);
        MockProtocol solo = new MockProtocol();
        vm.deal(protocolOwner, 1 ether);
        vm.prank(protocolOwner);
        (, uint256 id) = freshFactory.register{value: 1 ether}(
            address(solo), abi.encodeCall(MockProtocol.isHealthy, ()), bytes(""), 1 ether, 0, 5 minutes, protocolOwner
        );
        solo.breakHealth();
        vm.prank(watcher);
        freshExecutor.report(id);
        vm.prank(watcher);
        freshRegistry.claim(id);
        vm.assertEq(watcher.balance, 1 ether);
    }

    // ==============================================
    // Incident state
    // ==============================================

    function testFullLifecycleFromBreachToClaim() public {
        mockProtocol.breakHealth();
        vm.expectEmit(true, true, false, false, address(executor));
        emit GuardianExecutor.InvariantBreached(protocolId, address(mockProtocol));
        vm.expectEmit(true, true, true, true, address(executor));
        emit GuardianExecutor.EmergencyActionCalled(protocolId, address(mockProtocol), true);
        vm.expectEmit(true, true, false, true, address(registry));
        emit DeSecRegistry.BountyAwarded(protocolId, watcher, 4 ether);
        vm.prank(watcher);
        bool result = executor.report(protocolId);
        vm.assertTrue(result);
        vm.assertTrue(mockProtocol.paused());

        vm.deal(protocolOwner, 3 ether);
        vm.prank(protocolOwner);
        registry.topUp{value: 3 ether}(protocolId);
        mockProtocol.heal();
        vm.expectEmit(true, false, false, false, address(registry));
        emit DeSecRegistry.IncidentResolved(protocolId);
        vm.prank(protocolOwner);
        registry.resolveIncident(protocolId);

        vm.expectEmit(true, true, false, true, address(registry));
        emit DeSecRegistry.BountyClaimed(protocolId, watcher, 4 ether);
        vm.prank(watcher);
        registry.claim(protocolId);
        vm.assertEq(watcher.balance, 4 ether);
        vm.assertEq(registry.totalAwarded(), 4 ether);

        DeSecRegistry.Protocol memory p = registry.getProtocol(protocolId);
        vm.assertEq(p.balance, 4 ether);
        vm.assertFalse(p.incidentActive);
        vm.assertEq(registry.claimableBounties(watcher, protocolId), 0);
        vm.assertEq(address(registry).balance, 4 ether);
    }

    function testReportRevertsWhileIncidentIsActive() public {
        enterIncident();
        bytes memory expectedError = abi.encodeWithSelector(GuardianExecutor.IncidentActive.selector, protocolId);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        executor.report(protocolId);
    }

    function testOwnerCanUpdateInvariantDuringIncident() public {
        enterIncident();
        bytes memory newInvariant = abi.encodeCall(MockProtocol.alwaysHealthy, ());
        vm.prank(protocolOwner);
        registry.updateInvariant(protocolId, newInvariant);
        DeSecRegistry.Protocol memory p = registry.getProtocol(protocolId);
        vm.assertEq(p.invariantPayload, newInvariant);
    }

    function testOwnerCanUpdateEmergencyActionDuringIncident() public {
        enterIncident();
        bytes memory newEmergency = abi.encodeCall(MockProtocol.breakHealth, ());
        vm.prank(protocolOwner);
        registry.updateEmergencyAction(protocolId, newEmergency);
        DeSecRegistry.Protocol memory p = registry.getProtocol(protocolId);
        vm.assertEq(p.emergencyPayload, newEmergency);
    }

    function testOwnerCanFundRecordDuringIncident() public {
        enterIncident();
        vm.deal(protocolOwner, 4 ether);
        vm.prank(protocolOwner);
        registry.topUp{value: 3 ether}(protocolId);
        vm.prank(protocolOwner);
        registry.addBounty{value: 1 ether}(protocolId);
        DeSecRegistry.Protocol memory p = registry.getProtocol(protocolId);
        vm.assertEq(p.balance, 5 ether);
        vm.assertEq(p.bounty, 5 ether);
    }

    function testOwnerCanUpdateParametersDuringIncident() public {
        enterIncident();
        vm.prank(protocolOwner);
        registry.updateCheckInFee(protocolId, 0.01 ether);
        vm.prank(protocolOwner);
        registry.updateInterval(protocolId, 10 minutes);
        DeSecRegistry.Protocol memory p = registry.getProtocol(protocolId);
        vm.assertEq(p.checkInFee, 0.01 ether);
        vm.assertEq(p.interval, 10 minutes);
    }

    function testOwnerCanWithdrawExcessDuringIncident() public {
        vm.deal(protocolOwner, 20 ether);
        vm.prank(protocolOwner);
        (, uint256 id) = factory.register{value: 20 ether}(
            address(mockProtocol), invariantPayload, emergencyPayload, 4 ether, 1e6 wei, 5 minutes, protocolOwner
        );
        mockProtocol.breakHealth();
        vm.prank(watcher);
        executor.report(id);
        vm.prank(protocolOwner);
        registry.withdraw(id, 12 ether);
        DeSecRegistry.Protocol memory p = registry.getProtocol(id);
        vm.assertEq(p.balance, 4 ether);
    }

    function testWatcherCanClaimAfterOwnerDeRegistersDuringIncident() public {
        enterIncident();
        uint256 ownerBefore = protocolOwner.balance;
        vm.prank(protocolOwner);
        registry.deRegister(protocolId);
        vm.assertEq(protocolOwner.balance, ownerBefore + 1 ether);
        vm.prank(watcher);
        registry.claim(protocolId);
        vm.assertEq(watcher.balance, 4 ether);
    }

    function testResolveIncidentRestoresMonitoring() public {
        enterIncident();
        vm.deal(protocolOwner, 3 ether);
        vm.prank(protocolOwner);
        registry.topUp{value: 3 ether}(protocolId);
        mockProtocol.heal();
        vm.expectEmit(true, false, false, false, address(registry));
        emit DeSecRegistry.IncidentResolved(protocolId);
        vm.prank(protocolOwner);
        registry.resolveIncident(protocolId);
        DeSecRegistry.Protocol memory p = registry.getProtocol(protocolId);
        vm.assertFalse(p.incidentActive);
        bytes memory expectedError = abi.encodeWithSelector(GuardianExecutor.InvariantNotBreached.selector);
        vm.expectRevert(expectedError);
        vm.prank(watcher);
        executor.report(protocolId);
    }

    function testSecondIncidentPaysBountyAgainAfterResolution() public {
        enterIncident();
        vm.deal(protocolOwner, 7 ether);
        vm.prank(protocolOwner);
        registry.topUp{value: 7 ether}(protocolId);
        mockProtocol.heal();
        vm.prank(protocolOwner);
        registry.resolveIncident(protocolId);
        mockProtocol.breakHealth();
        address secondWatcher = makeAddr("Second_Watcher");
        vm.expectEmit(true, true, false, true, address(registry));
        emit DeSecRegistry.BountyAwarded(protocolId, secondWatcher, 4 ether);
        vm.prank(secondWatcher);
        executor.report(protocolId);
        vm.assertEq(registry.claimableBounties(secondWatcher, protocolId), 4 ether);
    }

    function testResolveIncidentRevertsWhenInvariantStillBroken() public {
        enterIncident();
        bytes memory expectedError = abi.encodeWithSelector(DeSecRegistry.InvariantCurrentlyBroken.selector);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.resolveIncident(protocolId);
    }

    function testResolveIncidentRevertsWhenUnderwater() public {
        enterIncident();
        mockProtocol.heal();
        bytes memory expectedError =
            abi.encodeWithSelector(DeSecRegistry.InsufficientProtocolBalance.selector, protocolId, 1 ether, 4 ether);
        vm.expectRevert(expectedError);
        vm.prank(protocolOwner);
        registry.resolveIncident(protocolId);
    }

    function testResolveIncidentRevertsWhenCalledByNonOwner() public {
        enterIncident();
        vm.expectRevert();
        vm.prank(random);
        registry.resolveIncident(protocolId);
    }

    function enterIncident() internal {
        mockProtocol.breakHealth();
        vm.prank(watcher);
        executor.report(protocolId);
    }

    function testExecutorConstructorRevertsWhenRegistryIsZero() public {
        bytes memory expectedError = abi.encodeWithSelector(GuardianExecutor.ZeroAddress.selector);
        vm.expectRevert(expectedError);
        new GuardianExecutor(DeSecRegistry(payable(address(0))));
    }

    // ==============================================
    // Fuzz tests
    // ==============================================

    function testFuzzClaimTransfersExactBounty(uint256 bounty) public {
        bounty = bound(bounty, registry.MINIMUM_REGISTRATION_FEE(), 100 ether);
        vm.deal(protocolOwner, 2 * bounty);
        vm.prank(protocolOwner);
        (, uint256 id) = factory.register{value: 2 * bounty}(
            address(mockProtocol), invariantPayload, bytes(""), bounty, 0, 5 minutes, protocolOwner
        );
        mockProtocol.breakHealth();
        vm.prank(watcher);
        executor.report(id);
        vm.prank(watcher);
        registry.claim(id);
        vm.assertEq(watcher.balance, bounty);
        vm.assertEq(registry.claimableBounties(watcher, id), 0);
        vm.assertEq(registry.totalAwarded(), bounty);
    }
}
