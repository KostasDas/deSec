// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GuardianAdapter} from "./GuardianAdapter.sol";
import {GuardianAdapterFactory} from "./GuardianAdapterFactory.sol";

contract DeSecRegistry is ReentrancyGuard {
    uint32 public constant MINIMUM_INTERVAL = 1 minutes;
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
        uint256 registrationTime;
        address protocol;
        address owner;
        bytes4 invariantSelector;
        bytes4 emergencySelector;
        uint32 interval;
    }

    event Registered(address indexed adapter, address indexed protocol, uint256 indexed protocolId);
    event RegistryDeployed(address indexed registry);
    event BountyUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    event BalanceUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    event ProtocolDeregistered(uint256 indexed protocolId);
    event CheckInFeeUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    event IntervalUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);

    error ZeroAddress();
    error ValueRequired();
    error InvalidRegistrationAmounts(
        uint256 valuePassed, uint256 bountyPassed, uint256 checkInFeePassed, uint256 minimumRegistrationFee
    );
    error ProtocolNotFound(uint256 id);
    error InvalidIntervalDuration(uint256 passed, uint256 minimum);
    error ActionFailed(bytes data);
    error InSufficientWithdrawableBalance(uint256 passed, uint256 available);

    modifier onlyFactory() {
        require(msg.sender == address(factory));
        _;
    }

    modifier onlyOwner(uint256 _protocolId) {
        address owner = protocols[_protocolId].owner;
        require(owner == msg.sender);
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
        uint32 _interval
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
        Protocol memory p = Protocol({
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
        protocols[p.protocolId] = p;

        // todo: the adapter needs to perform a staticcall to the protocol's invariant selector.
        // it will revert if any state changes
        // adapter.staticcall(todo define method and parameters)

        emit Registered(address(_adapter), _protocol, protocolId);
        return p.protocolId;
    }

    function getProtocol(uint256 _id) public view returns (Protocol memory) {
        Protocol memory p = protocols[_id];
        if (p.protocolId == 0) {
            revert ProtocolNotFound(_id);
        }
        return p;
    }

    function addBounty(uint256 _protocolId) public payable onlyOwner(_protocolId) {
        if (msg.value == 0) {
            revert ValueRequired();
        }
        Protocol storage p = protocols[_protocolId];
        uint256 previousBounty = p.bounty;
        uint256 previousBalance = p.balance;

        p.bounty += msg.value;
        p.balance += msg.value;

        emit BountyUpdated(_protocolId, previousBounty, p.bounty);
        emit BalanceUpdated(_protocolId, previousBalance, p.balance);
    }

    function topUp(uint256 _protocolId) external payable onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        if (msg.value == 0) {
            revert ValueRequired();
        }
        uint256 previous = p.balance;
        p.balance += msg.value;

        emit BalanceUpdated(_protocolId, previous, p.balance);
    }

    function remainingCheckIns(uint256 _protocolId) external view returns (uint256) {
        Protocol storage p = protocols[_protocolId];
        if (p.protocolId == 0) {
            revert ProtocolNotFound(_protocolId);
        }
        if (p.balance <= p.bounty || p.checkInFee == 0) {
            return 0;
        }
        uint256 checkInBalance = p.balance - p.bounty;
        return checkInBalance / p.checkInFee;
    }

    function lastCheckIn(uint256 _protocolId) external view returns (uint256) {
        Protocol storage p = protocols[_protocolId];
        if (p.protocolId == 0) {
            revert ProtocolNotFound(_protocolId);
        }
        return p.lastCheckTime;
    }

    /**
     * Protocol Owner actions
     */

    function deRegister(uint256 _protocolId) public onlyOwner(_protocolId) nonReentrant {
        //todo perfom checks that we don't currently have about the protocol's state. if it's pending
        // a bounty payout it should not be allowed to deregister
        Protocol storage p = protocols[_protocolId];
        uint256 balance = p.balance;
        delete protocols[_protocolId];
        (bool success, bytes memory data) = msg.sender.call{value: balance}("");
        if (success) {
            emit ProtocolDeregistered(_protocolId);
            return;
        }
        revert ActionFailed(data);
    }

    function updateCheckInFee(uint256 _protocolId, uint256 _fee) public onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        uint256 previous = p.checkInFee;
        p.checkInFee = _fee; // we allow _fee to be 0
        emit CheckInFeeUpdated(_protocolId, previous, _fee);
    }

    function updateInterval(uint256 _protocolId, uint32 _interval) public onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        if (_interval < MINIMUM_INTERVAL) {
            revert InvalidIntervalDuration(_interval, MINIMUM_INTERVAL);
        }
        uint256 previous = p.interval;
        p.interval = _interval;
        emit IntervalUpdated(_protocolId, previous, _interval);
    }

    function withdraw(uint256 _protocolId, uint256 _amount) public onlyOwner(_protocolId) nonReentrant {
        Protocol storage p = protocols[_protocolId];
        uint256 previousBalance = p.balance;
        uint256 availableBalance = p.balance - p.bounty;
        if (_amount == 0 ) {
            revert ValueRequired();
        }
        if (availableBalance < _amount) {
            revert InSufficientWithdrawableBalance(_amount, availableBalance);
        }
        p.balance -= _amount;
        assert(p.balance >= p.bounty);
        (bool success, bytes memory data) = msg.sender.call{value: _amount}("");
        if (success) {
            emit BalanceUpdated(_protocolId, previousBalance, p.balance);
            return;
        }
        revert ActionFailed(data);
    }
}
