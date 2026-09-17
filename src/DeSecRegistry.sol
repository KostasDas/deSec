// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {GuardianAdapter} from "./GuardianAdapter.sol";
import {GuardianAdapterFactory} from "./GuardianAdapterFactory.sol";

contract DeSecRegistry {
    GuardianAdapterFactory public immutable factory;

    mapping(uint256 => uint256) public balances;
    mapping(uint256 => Protocol) public protocols;
    uint256 public protocolId;

    struct Protocol {
        uint256 protocolId;
    }

    event Registered(address indexed adapter, uint256 protocolId);
    event RegistryDeployed(address indexed registry);

    error ZeroAddress();
    error OnlyFactoryAllowed();
    error InsufficientBounty(uint256 passed, uint256 required);

    constructor(GuardianAdapterFactory _factory) {
        if (address(_factory) == address(0)) {
            revert ZeroAddress();
        }
        factory = _factory;

        emit RegistryDeployed(address(this));
    }

    function register(
        GuardianAdapter adapter,
        bytes4 invariantSelector,
        bytes4 emergencySelector,
        uint256 bounty,
        uint256 checkInFee,
        uint256 checkInDuration
    ) public payable {
        if (msg.sender != address(factory)) {
            revert OnlyFactoryAllowed();
        }

        emit Registered(address(adapter), protocolId);
    }
}
