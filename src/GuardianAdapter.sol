// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {GuardianExecutor} from "./GuardianExecutor.sol";
import {DeSecRegistry} from "./DeSecRegistry.sol";

contract GuardianAdapter is Ownable2Step {
    GuardianExecutor public immutable executor;
    DeSecRegistry public immutable registry;

    event AdapterDeployed(address adapter);

    error ZeroAddress();

    modifier onlyExecutor() {
        require(msg.sender == address(executor));
        _;
    }

    constructor(address _owner, GuardianExecutor _executor, DeSecRegistry _registry) Ownable(_owner) {
        if (address(_executor) == address(0) || address(_registry) == address(0)) {
            revert ZeroAddress();
        }
        executor = _executor;
        registry = _registry;

        emit AdapterDeployed(address(this));
    }

    function callEmergencyFunction(address protocol, bytes calldata payload) external onlyExecutor {
        Address.functionCall(protocol, payload);
    }
}
