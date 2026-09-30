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
        vm.assertEq(logs.length, 1);
        vm.assertEq(logs[0].topics[0], GuardianExecutor.InvariantBreached.selector);
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
}
