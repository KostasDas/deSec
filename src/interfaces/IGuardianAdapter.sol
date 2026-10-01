// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title Guardian Adapter
/// @notice The per-protocol permission holder of deSec. A protocol's governance grants its emergency
/// role to its own adapter — never to the network directly — so each protocol's pause power sits in
/// its own isolated contract.
/// @dev Deployed only by the GuardianAdapterFactory, which guarantees every adapter runs the audited
/// template. Obeys exactly one caller, the GuardianExecutor, so the only path to the emergency action
/// runs through the executor's on-chain verification. The registry reads `owner()` live as the record administrator.
interface IGuardianAdapter {
    /// @notice Emitted at construction, announcing the adapter a protocol's governance should grant its emergency role to.
    event AdapterDeployed(address adapter);

    /// @notice The executor or registry address passed to the constructor was zero.
    error ZeroAddress();

    /// @notice The administrator of this adapter's registry record, resolved live by the registry on every privileged call.
    /// @dev Rotation uses Ownable2Step: the registry obeys the new administrator the moment they accept,
    /// with no migration and no stale permissions left behind.
    /// @return The current owner; a pending owner has no rights until accepting.
    function owner() external view returns (address);
    /// @notice Fires the protocol's pre-authorized emergency call (e.g. pausing a market).
    /// @dev Callable only by the GuardianExecutor. Uses OpenZeppelin `Address.functionCall`, so revert
    /// reasons bubble to the executor's try/catch and silent failures surface as `FailedCall`.
    /// @param protocol Target contract on which the protocol's governance granted this adapter its role.
    /// @param payload The complete `abi.encodeCall` stored at registration — arguments included, never chosen by the caller.
    function callEmergencyFunction(address protocol, bytes calldata payload) external;
}
