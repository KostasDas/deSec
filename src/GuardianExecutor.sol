// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeSecRegistry} from "./DeSecRegistry.sol";
import {GuardianAdapter} from "./GuardianAdapter.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGuardianExecutor} from "./interfaces/IGuardianExecutor.sol";
import {IDeSecRegistry} from "./interfaces/IDeSecRegistry.sol";

/// @title Guardian Executor
/// @dev All entry points are nonReentrant, and bounties are credited as claimable balances inside the
/// registry (checks-effects-interactions) so the time-critical trigger never pushes ETH to an untrusted
/// recipient. See {IGuardianExecutor} for the full API contract.
contract GuardianExecutor is IGuardianExecutor, ReentrancyGuard {
    DeSecRegistry public immutable registry;

    /// @dev The registry binding is immutable — the factory deploys and wires executor and registry together.
    /// @param _registry The registry holding every protocol record and escrow this executor acts on.
    constructor(DeSecRegistry _registry) {
        if (address(_registry) == address(0)) {
            revert ZeroAddress();
        }
        registry = _registry;
    }

    /// @inheritdoc IGuardianExecutor
    function report(uint256 _protocolId) public override nonReentrant returns (bool) {
        IDeSecRegistry.Protocol memory p = registry.getProtocol(_protocolId);
        return _report(p);
    }

    /// @dev Shared trigger path for report and for checkIn-discovered breaches. The bounty is awarded
    /// regardless of the emergency call's outcome — it pays for the verified alarm, not the pause,
    /// because registration can never prove the pause will work.
    function _report(IDeSecRegistry.Protocol memory _p) internal returns (bool) {
        if (_p.incidentActive) {
            revert IncidentActive(_p.protocolId);
        }
        assert(_p.balance >= _p.bounty);
        address protocol = _p.protocol;
        bytes memory payload = _p.invariantPayload;
        bool healthy = invariantCheck(protocol, payload);
        if (healthy) {
            revert InvariantNotBreached();
        }

        emit InvariantBreached(_p.protocolId, protocol);
        bool result = false;
        if (_p.emergencyPayload.length > 0) {
            result = triggerEmergencyAction(_p.protocolId, _p.adapter, protocol, _p.emergencyPayload);
            emit EmergencyActionCalled(_p.protocolId, protocol, result);
        }
        registry.awardBounty(_p.protocolId, msg.sender);
        return result;
    }

    /// @inheritdoc IGuardianExecutor
    function checkIn(uint256 _protocolId) public override nonReentrant {
        IDeSecRegistry.Protocol memory p = registry.getProtocol(_protocolId);
        if (p.incidentActive) {
            revert IncidentActive(_protocolId);
        }
        if (registry.remainingCheckIns(_protocolId) == 0) {
            revert NoCheckInFeeForProtocol(_protocolId);
        }
        if (block.timestamp < p.lastCheckIn + p.interval) {
            revert IntervalNotPassed(p.lastCheckIn + p.interval);
        }
        bool healthy = invariantCheck(p.protocol, p.invariantPayload);
        if (healthy) {
            registry.drip(_protocolId, msg.sender);
            return;
        }
        _report(p);
    }

    /// @dev Staticcall, so the check is read-only by construction. A reverting invariant raises
    /// InvariantReverted — unevaluable, never a violation — instead of being read as a breach.
    function invariantCheck(address _protocol, bytes memory _payload) internal view returns (bool) {
        (bool success, bytes memory returnData) = _protocol.staticcall(_payload);
        if (!success) {
            revert InvariantReverted();
        }
        return abi.decode(returnData, (bool));
    }

    /// @dev try/catch keeps a failing emergency call from undoing the verified alarm or the bounty;
    /// the bubbled reason is emitted in EmergencyActionFailed.
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
