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
        bytes4 _invariantSelector,
        bytes4 _emergencySelector,
        uint256 _bounty,
        uint256 _checkInFee,
        uint256 _interval,
        address _owner
    ) public payable returns (address, uint256) {
        if (_owner == address(0)) {
            _owner = msg.sender;
        }
        GuardianAdapter _adapter = new GuardianAdapter(_owner, executor, registry);
        uint256 protocolId = registry.register{value: msg.value}(
            _protocol, _owner, _adapter, _invariantSelector, _emergencySelector, _bounty, _checkInFee, _interval
        );
        return (address(_adapter), protocolId);
    }
}
