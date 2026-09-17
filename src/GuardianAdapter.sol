// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {GuardianExecutor} from "./GuardianExecutor.sol";
import {DeSecRegistry} from "./DeSecRegistry.sol";

contract GuardianAdapter is Ownable2Step, AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR");
    address public immutable executor;
    address public immutable registry;

    event AdapterDeployed();

    constructor(address owner, GuardianExecutor _executor, DeSecRegistry _registry) Ownable(owner) {}
}
