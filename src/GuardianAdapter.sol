// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {GuardianExecutor} from "./GuardianExecutor.sol";
import {DeSecRegistry} from "./DeSecRegistry.sol";
import {IGuardianAdapter} from "./interfaces/IGuardianAdapter.sol";

/// @title Guardian Adapter
/// @dev Immutable by design: a contract holding pause power must never have its logic silently
/// changed. One adapter may hold roles on several of a protocol's contracts at once, allowing an
/// entire system to be paused together. See {IGuardianAdapter} for the full API contract.
contract GuardianAdapter is IGuardianAdapter, Ownable2Step {
    GuardianExecutor public immutable executor;
    DeSecRegistry public immutable registry;

    modifier onlyExecutor() {
        require(msg.sender == address(executor));
        _;
    }

    /// @dev `_owner` becomes the administrator of the registry record (read live via `owner()`);
    /// realistically the protocol's governance multisig.
    /// @param _executor The only caller this adapter will ever obey.
    /// @param _registry The registry holding this protocol's record.
    constructor(address _owner, GuardianExecutor _executor, DeSecRegistry _registry) Ownable(_owner) {
        if (address(_executor) == address(0) || address(_registry) == address(0)) {
            revert ZeroAddress();
        }
        executor = _executor;
        registry = _registry;

        emit AdapterDeployed(address(this));
    }

    /// @inheritdoc IGuardianAdapter
    function callEmergencyFunction(address protocol, bytes calldata payload) external override onlyExecutor {
        Address.functionCall(protocol, payload);
    }

    /// @inheritdoc IGuardianAdapter
    function owner() public view override(Ownable, IGuardianAdapter) returns (address) {
        return super.owner();
    }
}
