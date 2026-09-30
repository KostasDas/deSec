// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeSecRegistry} from "../src/DeSecRegistry.sol";
import {GuardianAdapterFactory} from "../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../src/GuardianAdapter.sol";
import {GuardianExecutor} from "../src/GuardianExecutor.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {console} from "forge-std/console.sol";

contract GuardianAdapterTest is Test {
    address protocolOwner = makeAddr("Protocol_Owner");
    address random = makeAddr("Random_Account");
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
    }

    function testCallEmergencyFunctionRevertsWhenCallerIsNotExecutor() public {
        vm.expectRevert();
        vm.prank(random);
        adapter.callEmergencyFunction(address(mockProtocol), emergencyPayload);
    }

    function testCallEmergencyFunctionExecutesOnTarget() public {
        bytes32 pauserRole = mockProtocol.PAUSER_ROLE();
        vm.prank(protocolOwner);
        mockProtocol.grantRole(pauserRole, address(adapter));
        vm.prank(address(executor));
        adapter.callEmergencyFunction(address(mockProtocol), emergencyPayload);
        vm.assertTrue(mockProtocol.paused());
    }

    function testCallEmergencyFunctionBubblesRevertReason() public {
        bytes memory expectedReason = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, address(adapter), mockProtocol.PAUSER_ROLE()
        );
        vm.expectRevert(expectedReason);
        vm.prank(address(executor));
        adapter.callEmergencyFunction(address(mockProtocol), emergencyPayload);
    }

    function testConstructorWiresOwnerExecutorAndRegistry() public {
        vm.assertEq(adapter.owner(), protocolOwner);
        vm.assertEq(address(adapter.executor()), address(executor));
        vm.assertEq(address(adapter.registry()), address(factory.registry()));
    }

    function testConstructorRevertsWhenExecutorIsZero() public {
        DeSecRegistry registry = factory.registry();
        bytes memory expectedError = abi.encodeWithSelector(GuardianAdapter.ZeroAddress.selector);
        vm.expectRevert(expectedError);
        new GuardianAdapter(protocolOwner, GuardianExecutor(address(0)), registry);
    }

    function testConstructorRevertsWhenRegistryIsZero() public {
        bytes memory expectedError = abi.encodeWithSelector(GuardianAdapter.ZeroAddress.selector);
        vm.expectRevert(expectedError);
        new GuardianAdapter(protocolOwner, executor, DeSecRegistry(payable(address(0))));
    }

    function testConstructorEmitsAdapterDeployed() public {
        DeSecRegistry registry = factory.registry();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(false, false, false, true);
        emit GuardianAdapter.AdapterDeployed(predicted);
        new GuardianAdapter(protocolOwner, executor, registry);
    }
}
