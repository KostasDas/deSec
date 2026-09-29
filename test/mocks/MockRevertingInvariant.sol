// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract MockRevertingInvariant {
    function isHealthy() external pure returns (bool) {
        revert();
    }
}
