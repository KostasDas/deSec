// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IGuardianAdapter {
    event AdapterDeployed(address adapter);

    error ZeroAddress();

    function owner() external view returns (address);
    function callEmergencyFunction(address protocol, bytes calldata payload) external;
}
