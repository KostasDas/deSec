// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeSecRegistry} from "./DeSecRegistry.sol";
import {GuardianAdapter} from "./GuardianAdapter.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GuardianExecutor is ReentrancyGuard {
    DeSecRegistry public immutable registry;

    error ZeroAddress();
    error InvariantNotBreached();
    error InvariantReverted();
    error InsufficientProtocolBalance(uint256 protocolId, uint256 balance, uint256 bounty);
    error IncidentActive(uint256 protocolId);

    event InvariantBreached(uint256 indexed protocolId, address indexed protocol);
    event EmergencyActionCalled(uint256 indexed protocolId, address indexed protocol, bool callResult);
    event EmergencyActionFailed(uint256 indexed protocolId, address indexed protocol, bytes reason);

    constructor(DeSecRegistry _registry) {
        if (address(_registry) == address(0)) {
            revert ZeroAddress();
        }
        registry = _registry;
    }

    function report(uint256 _protocolId) public nonReentrant returns (bool) {
        DeSecRegistry.Protocol memory p = registry.getProtocol(_protocolId);
        if (p.incidentActive) {
            revert IncidentActive(_protocolId);
        }
        assert(p.balance >= p.bounty);
        address protocol = p.protocol;
        bytes memory payload = p.invariantPayload;
        (bool success, bytes memory returnData) = protocol.staticcall(payload);
        if (!success) {
            revert InvariantReverted();
        }
        bool healthy = abi.decode(returnData, (bool));
        if (healthy) {
            revert InvariantNotBreached();
        }
        emit InvariantBreached(_protocolId, protocol);
        bool result = false;
        if (p.emergencyPayload.length > 0) {
            result = triggerEmergencyAction(_protocolId, p.adapter, protocol, p.emergencyPayload);
            emit EmergencyActionCalled(_protocolId, protocol, result);
        }
        registry.awardBounty(_protocolId, msg.sender);
        return result;
    }

    function triggerEmergencyAction(
        uint256 _protocolId,
        GuardianAdapter _adapter,
        address _protocol,
        bytes memory _payload
    ) internal returns (bool) {
        try _adapter.callEmergencyFunction(_protocol, _payload) {
            return true;
        } catch (bytes memory reason) {
            emit EmergencyActionFailed(_protocolId, _protocol, reason);
            return false;
        }
    }
}
