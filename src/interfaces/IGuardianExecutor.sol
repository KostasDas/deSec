// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IGuardianExecutor {
    error ZeroAddress();
    error InvariantNotBreached();
    error InvariantReverted();
    error InsufficientProtocolBalance(uint256 protocolId, uint256 balance, uint256 bounty);
    error IncidentActive(uint256 protocolId);
    error IntervalNotPassed(uint256 nextInterval);
    error NoCheckInFeeForProtocol(uint256 protocolId);

    event InvariantBreached(uint256 indexed protocolId, address indexed protocol);
    event EmergencyActionCalled(uint256 indexed protocolId, address indexed protocol, bool callResult);
    event EmergencyActionFailed(uint256 indexed protocolId, address indexed protocol, bytes reason);

    function report(uint256 _protocolId) external returns (bool);
    function checkIn(uint256 _protocolId) external;
}
