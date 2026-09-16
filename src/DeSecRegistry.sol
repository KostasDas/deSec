// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {GuardianAdapter} from "./GuardianAdapter.sol";

contract DeSecRegistry {

    mapping(uint256 => uint256) public balances;
    mapping(uint256 => Protocol) public protocols;
    uint256 public protocolId;

    struct Protocol {
        uint256 protocolId;
    }

    event Registered(address indexed adapter, uint256 protocolId);

    error ZeroAddress();
    error InsufficientBounty(uint256 passed, uint256 required);

    function register(
        GuardianAdapter adapter, 
        bytes4 invariantSelector, 
        bytes4 emergencySelector) public payable {

    }
}