// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title Guardian Executor
/// @notice The trustless trigger and heartbeat engine of deSec: re-verifies each protocol's invariant
/// on-chain at call time, fires the emergency action through the protocol's adapter on a verified
/// breach, and routes payment to the watcher. The only contract any GuardianAdapter obeys.
/// @dev Watchers are couriers, not judges: they only draw this contract's attention, and the EVM's own
/// staticcall decides every claim — a watcher can never cause a false pause or fabricate a violation.
interface IGuardianExecutor {
    /// @notice The constructor was given a zero registry address.
    error ZeroAddress();
    /// @notice A report was submitted for a protocol whose invariant currently holds; the caller paid gas for nothing.
    error InvariantNotBreached();
    /// @notice The invariant reverted during the read-only check. A reverting invariant is treated as
    /// unevaluable — never as a violation — so a crash in the health check cannot be weaponized into an unearned pause.
    error InvariantReverted();
    /// @notice The record's balance cannot cover its bounty reserve.
    /// @param protocolId The underfunded record.
    /// @param balance The record's escrowed balance.
    /// @param bounty The reserved prize the balance must cover.
    error InsufficientProtocolBalance(uint256 protocolId, uint256 balance, uint256 bounty);
    /// @notice The record has an unresolved incident; report and checkIn stay blocked until the owner
    /// resolves it, so one breach can pay only one bounty.
    /// @param protocolId The record with the active incident.
    error IncidentActive(uint256 protocolId);
    /// @notice A checkIn was submitted before the record's interval elapsed; no watcher can drain a deposit by over-checking.
    /// @param nextInterval The earliest timestamp at which the next checkIn is accepted.
    error IntervalNotPassed(uint256 nextInterval);
    /// @notice A checkIn was submitted for a record that cannot currently pay a fee (remainingCheckIns
    /// is 0). The record operates in bounty-only mode; report remains fully functional.
    /// @param protocolId The record with no funded checks remaining.
    error NoCheckInFeeForProtocol(uint256 protocolId);

    /// @notice A breach was verified against live state inside the triggering transaction, so a false positive is impossible by construction.
    event InvariantBreached(uint256 indexed protocolId, address indexed protocol);
    /// @notice The emergency payload was fired through the adapter; `callResult` reports whether the protocol actually executed it.
    event EmergencyActionCalled(uint256 indexed protocolId, address indexed protocol, bool callResult);
    /// @notice The adapter's emergency call reverted; `reason` is the bubbled revert data. The verified alarm and the bounty stand regardless.
    event EmergencyActionFailed(uint256 indexed protocolId, address indexed protocol, bytes reason);

    /// @notice Reports a breach: re-verifies the invariant read-only, fires the emergency payload
    /// through the adapter, and credits the caller the bounty.
    /// @dev Reverts when an incident is already active, when the invariant holds, or when the invariant
    /// itself reverts. The bounty pays for the verified alarm, not for a successful pause — it is
    /// awarded even if the emergency call fails or the record was registered monitoring-only (empty payload).
    /// @param _protocolId The record to trigger.
    /// @return True iff the emergency call succeeded; false when it failed or no payload was configured.
    function report(uint256 _protocolId) external returns (bool);
    /// @notice Performs a routine paid heartbeat: a healthy invariant drips the caller the checkInFee,
    /// while a discovered breach routes atomically into the report path and pays the full bounty instead.
    /// @dev Reverts when an incident is active, when the record cannot pay a fee (remainingCheckIns == 0),
    /// when the interval has not elapsed, or when the invariant itself reverts. The atomic routing
    /// leaves no frontrunning window between a heartbeat that finds a breach and the trigger.
    /// @param _protocolId The record to check.
    function checkIn(uint256 _protocolId) external;
}
