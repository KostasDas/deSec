// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {GuardianAdapter} from "./GuardianAdapter.sol";
import {GuardianAdapterFactory} from "./GuardianAdapterFactory.sol";

contract DeSecRegistry {
    GuardianAdapterFactory public immutable factory;
    uint256 public constant MINIMUM_DURATION = 7 days;
    uint256 public constant MINIMUM_REGISTRATION_FEE = 0.01 ether;

    mapping(uint256 => uint256) public balances;
    mapping(uint256 => Protocol) public protocols;
    uint256 public protocolId;

    struct Protocol {
        uint256 protocolId;
        address protocol;
        bytes4 invariantSelector;
        bytes4 emergencySelector;
    }

    event Registered(address indexed adapter, address indexed protocol, uint256 protocolId);
    event RegistryDeployed(address indexed registry);

    error ZeroAddress();
    error InitialDepositTooLow();
    error NoProtocolFound(uint256 id);
    error InsufficientValue(uint256 passed, uint256 required);
    error InvalidCheckInDuration(uint256 passed, uint256 minimum);

    modifier onlyFactory() {
        require(msg.sender == address(factory));
        _;
    }

    constructor(GuardianAdapterFactory _factory) {
        if (address(_factory) == address(0)) {
            revert ZeroAddress();
        }
        factory = _factory;

        emit RegistryDeployed(address(this));
    }

    function register(
        address protocol,
        GuardianAdapter adapter,
        bytes4 invariantSelector,
        bytes4 emergencySelector,
        uint256 bounty,
        uint256 checkInFee,
        uint256 checkInDuration
    ) public payable onlyFactory returns (uint256) {
        if (msg.value < MINIMUM_REGISTRATION_FEE) {
            revert InitialDepositTooLow();
        }
        if (checkInDuration < MINIMUM_DURATION) {
            revert InvalidCheckInDuration(checkInDuration, MINIMUM_DURATION);
        }

        uint256 valueRequired = bounty + (checkInFee * checkInDuration);
        if (msg.value < valueRequired) {
            revert InsufficientValue(msg.value, valueRequired);
        }

        // so, invariant and emergency selectors can be malicious. how do we cleanup?
        // i will delegate this to later.
        protocolId += 1;
        Protocol memory _p = Protocol({
            protocolId: protocolId,
            protocol: protocol,
            invariantSelector: invariantSelector,
            emergencySelector: emergencySelector
        });
        protocols[_p.protocolId] = _p;

        // todo: the adapter needs to perform a staticcall to the protocol's invariant selector.
        // it will revert if any state changes
        // adapter.staticcall(todo define method and parameters)

        emit Registered(address(adapter), address(protocol), protocolId);
        return _p.protocolId;
    }

    function getProtocol(uint256 id) public view returns (Protocol memory) {
        Protocol memory _p = protocols[id];
        if (_p.protocolId == 0) {
            revert NoProtocolFound(id);
        }
        return _p;
    }
}
