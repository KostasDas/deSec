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
        address protocol,
        bytes4 invariantSelector,
        bytes4 emergencySelector,
        uint256 bounty,
        uint256 checkInFee,
        uint256 checkInDuration,
        address owner
    ) public payable returns (address, uint256) {
        if (owner == address(0)) {
            owner = msg.sender;
        }
        GuardianAdapter _adapter = new GuardianAdapter(owner, executor, registry);
        uint256 protocolId = registry.register{value: msg.value}(
            protocol, _adapter, invariantSelector, emergencySelector, bounty, checkInFee, checkInDuration
        );
        return (address(_adapter), protocolId);
    }
}
