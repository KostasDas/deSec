// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeSecRegistry} from "./DeSecRegistry.sol";
import {GuardianAdapter} from "./GuardianAdapter.sol";
import {GuardianExecutor} from "./GuardianExecutor.sol";

/// @title Guardian Adapter Factory
/// @notice The single entry point into the deSec network: deploys the registry and executor at
/// construction, then deploys each protocol's adapter and registers it atomically.
/// @dev Because every adapter is born here and the registry accepts registrations only from this
/// address, every registered protocol is guaranteed to run the audited adapter template — lookalike
/// factories are rejected by the registry.
contract GuardianAdapterFactory {
    DeSecRegistry public immutable registry;
    GuardianExecutor public immutable executor;

    /// @dev Binds the registry to this factory and wires the executor set-once, all within one
    /// transaction; the factory's deployer becomes the initial network fee recipient.
    constructor() {
        registry = new DeSecRegistry(this, msg.sender);
        executor = new GuardianExecutor(registry);
        registry.setExecutor(executor);
    }

    /// @notice Deploys the protocol's GuardianAdapter and registers its record in one atomic transaction.
    /// @dev Adapter deployment, invariant test-fire, and escrow funding happen together, so a record can
    /// never exist without its adapter. Granting the adapter the emergency role on the protocol's own
    /// contracts remains a separate governance action the protocol performs after registration.
    /// @param _protocol Contract the invariant is checked against and the emergency payload targets.
    /// @param _invariantPayload Complete `abi.encodeCall` of the health check (function + arguments);
    /// must be read-only, permissionless, and non-reverting.
    /// @param _emergencyActionPayload Complete `abi.encodeCall` fired on a verified breach; empty for
    /// monitoring-only registration.
    /// @param _bounty Gross prize for the first verified breach; locked as a reserve for the record's lifetime.
    /// @param _checkInFee Per-heartbeat payment; 0 registers the protocol in bounty-only mode.
    /// @param _interval Minimum seconds between paid heartbeats; 0 selects the registry's MINIMUM_INTERVAL.
    /// @param _owner Administrator of the record (the adapter's owner); defaults to msg.sender when zero.
    /// @return The address of the freshly deployed adapter — grant it the emergency role on the protocol's contracts.
    /// @return The new record's protocolId.
    function register(
        address _protocol,
        bytes calldata _invariantPayload,
        bytes calldata _emergencyActionPayload,
        uint256 _bounty,
        uint256 _checkInFee,
        uint32 _interval,
        address _owner
    ) public payable returns (address, uint256) {
        if (_owner == address(0)) {
            _owner = msg.sender;
        }
        GuardianAdapter adapter = new GuardianAdapter(_owner, executor, registry);
        uint256 id = registry.register{value: msg.value}(
            _protocol, adapter, _invariantPayload, _emergencyActionPayload, _bounty, _checkInFee, _interval
        );
        return (address(adapter), id);
    }
}
