// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract MockFlakyProtocol is AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum Mode {
        Healthy,
        Unhealthy,
        Reverting,
        Garbage
    }

    Mode public mode;
    bool public paused;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setMode(Mode _mode) external {
        mode = _mode;
    }

    function check() external view returns (bool) {
        if (mode == Mode.Reverting) {
            revert("invariant exploded");
        }
        if (mode == Mode.Garbage) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return mode == Mode.Healthy;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
    }
}
