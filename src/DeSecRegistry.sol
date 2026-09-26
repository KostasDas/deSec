// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {GuardianAdapter} from "./GuardianAdapter.sol";
import {GuardianAdapterFactory} from "./GuardianAdapterFactory.sol";

contract DeSecRegistry {
    uint256 public constant MINIMUM_INTERVAL = 1 minutes;
    uint256 public constant MINIMUM_REGISTRATION_FEE = 0.01 ether;
    GuardianAdapterFactory public immutable factory;

    mapping(uint256 => Protocol) public protocols;
    uint256 public protocolId;

    struct Protocol {
        uint256 protocolId;
        uint256 balance;
        uint256 bounty;
        uint256 checkInFee;
        uint256 lastCheckTime;
        uint256 interval;
        uint256 registrationTime;
        address protocol;
        address owner;
        bytes4 invariantSelector;
        bytes4 emergencySelector;
    }

    event Registered(address indexed adapter, address indexed protocol, uint256 indexed protocolId);
    event RegistryDeployed(address indexed registry);
    event BountyUpdated(uint256 indexed protocolId, uint256 _previous, uint256 _new);
    event BalanceUpdated(uint256 indexed protocolId, uint256 _previous, uint256 _new);

    error ZeroAddress();
    error ValueRequired();
    error InvalidRegistrationAmounts(
        uint256 valuePassed, uint256 bountyPassed, uint256 checkInFeePassed, uint256 minimumRegistrationFee
    );
    error ProtocolNotFound(uint256 id);
    error InvalidIntervalDuration(uint256 passed, uint256 minimum);

    modifier onlyFactory() {
        require(msg.sender == address(factory));
        _;
    }

    modifier onlyOwner(uint256 _protocolId) {
        Protocol memory protocol = getProtocol(_protocolId);
        require(protocol.owner == msg.sender);
        _;
    }

    constructor(GuardianAdapterFactory _factory) {
        if (address(_factory) == address(0)) {
            revert ZeroAddress();
        }
        factory = _factory;

        emit RegistryDeployed(address(this));
    }

    /**
     * Registration reverts when:
     * - bounty or msg.value are less than minimum
     * - msg.value is less than bounty or msg.value is less than bounty + checkInFee
     * if the check in fee is not 0, value should cover at least one check in fee.
     *
     * @param _protocol the protocol registering
     * @param _owner the protocol owner
     * @param _adapter the adapter deployed by the factory
     * @param _invariantSelector  the invariant the adapter will check that must never be broken
     * @param _emergencySelector  what the adapter will call in case the invariant is broken
     * @param _bounty how much the protocol will pay for the report
     * @param _checkInFee how much the protocol pays for a check in (an invariant checl)
     * @param _interval  how often the protocol allows checkins
     */
    function register(
        address _protocol,
        address _owner,
        GuardianAdapter _adapter,
        bytes4 _invariantSelector,
        bytes4 _emergencySelector,
        uint256 _bounty,
        uint256 _checkInFee,
        uint256 _interval
    ) public payable onlyFactory returns (uint256) {
        if (
            msg.value < MINIMUM_REGISTRATION_FEE || _bounty < MINIMUM_REGISTRATION_FEE
                || msg.value < (_bounty + _checkInFee)
        ) {
            revert InvalidRegistrationAmounts(msg.value, _bounty, _checkInFee, MINIMUM_REGISTRATION_FEE);
        }
        // if no interval is passed, use minimum.
        if (_interval == 0) {
            _interval = MINIMUM_INTERVAL;
        }
        // if the user specified an interval less than the minimum we explicity want to revert and notify. we don't want to allow
        // registration with a different value the user didn't agree upon
        if (_interval < MINIMUM_INTERVAL) {
            revert InvalidIntervalDuration(_interval, MINIMUM_INTERVAL);
        }
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        // so, invariant and emergency selectors can be malicious. how do we protect? what assumptions are safe to make?
        // i will delegate this to later.
        protocolId += 1;
        Protocol memory _p = Protocol({
            protocolId: protocolId,
            balance: msg.value,
            bounty: _bounty,
            checkInFee: _checkInFee,
            lastCheckTime: block.timestamp,
            interval: _interval,
            registrationTime: block.timestamp,
            protocol: _protocol,
            owner: _owner,
            invariantSelector: _invariantSelector,
            emergencySelector: _emergencySelector
        });
        protocols[_p.protocolId] = _p;

        // todo: the adapter needs to perform a staticcall to the protocol's invariant selector.
        // it will revert if any state changes
        // adapter.staticcall(todo define method and parameters)

        emit Registered(address(_adapter), address(_protocol), protocolId);
        return _p.protocolId;
    }

    function getProtocol(uint256 _id) public view returns (Protocol memory) {
        Protocol memory _p = protocols[_id];
        if (_p.protocolId == 0) {
            revert ProtocolNotFound(_id);
        }
        return _p;
    }

    function addBounty(uint256 _protocolId) public payable {
        if (msg.value == 0) {
            revert ValueRequired();
        }
        Protocol storage _p = protocols[_protocolId];
        if (_p.protocolId == 0) {
            revert ProtocolNotFound(protocolId);
        }
        uint256 _previousBounty = _p.bounty;
        uint256 _previousBalance = _p.balance;

        protocols[_protocolId].bounty += msg.value;
        protocols[_protocolId].balance += msg.value;

        emit BountyUpdated(_protocolId, _previousBounty, _p.bounty);
        emit BalanceUpdated(_protocolId, _previousBalance, _p.balance);
    }

    function addCheckInFee(uint256 _protocolId, uint256 _fee, uint256 _duration) public payable {
        if (msg.value == 0) {
            revert ValueRequired();
        }
        if (_duration == 0) {
            _duration = MINIMUM_INTERVAL;
        }

        Protocol memory _p = getProtocol(_protocolId);
        uint256 _existingFee = _p.checkInFee;
        uint256 _endTime = _p.lastCheckTime;

        //todo think about this, it is not that simple. we need to start doing some math
        // _p.balance += msg.value;
        // _p.bounty += msg.value;
    }

    function remainingCheckIns(uint256 _protocolId) public view returns (uint256) {
        Protocol storage _p = protocols[_protocolId];
        if (_p.protocolId == 0) {
            revert ProtocolNotFound(protocolId);
        }
        if (_p.balance <= _p.bounty || _p.checkInFee == 0) {
            return 0;
        }
        uint256 checkInBalance = _p.balance - _p.bounty;
        return checkInBalance / _p.checkInFee;
    }

    function lastCheckIn(uint256 _protocolId) public view returns (uint256) {
        Protocol storage _p = protocols[_protocolId];
        if (_p.protocolId == 0) {
            revert ProtocolNotFound(protocolId);
        }
        return _p.lastCheckTime;
    }
}
