// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract MockProtocol is AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bool public healthy = true;
    bool public paused;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function isHealthy() external view returns (bool) {
        return healthy;
    }

    function breakHealth() external {
        healthy = false;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
    }
}
