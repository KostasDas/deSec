// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract MockProtocol is AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bool public healthy = true;
    bool public paused;

    error PauseFailed();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function isHealthy() external view returns (bool) {
        return healthy;
    }

    function checkHealth() external view returns (bool) {
        return healthy;
    }

    function breakHealth() external {
        healthy = false;
    }

    function heal() external {
        healthy = true;
    }

    function alwaysHealthy() external pure returns (bool) {
        return true;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
    }

    function pauseWithCustomError() external pure {
        revert PauseFailed();
    }

    function pauseSilently() external pure {
        revert();
    }
}
