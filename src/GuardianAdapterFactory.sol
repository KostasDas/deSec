// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeSecRegistry} from "./DeSecRegistry.sol";
import {GuardianAdapter} from "./GuardianAdapter.sol";
import {GuardianExecutor} from "./GuardianExecutor.sol";

contract GuardianAdapterFactory {
    DeSecRegistry public immutable registry;
    GuardianExecutor public immutable executor;

    constructor() {
        registry = new DeSecRegistry(this);
        //Todo pass the registry to the executor when ready
        executor = new GuardianExecutor();
    }

    /**
     * Main protocol function.
     * Creates an adapter and registers the protocol to our guardian
     */
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
