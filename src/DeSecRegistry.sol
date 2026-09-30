// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GuardianAdapter} from "./GuardianAdapter.sol";
import {GuardianAdapterFactory} from "./GuardianAdapterFactory.sol";
import {GuardianExecutor} from "./GuardianExecutor.sol";

contract DeSecRegistry is ReentrancyGuard {
    uint32 public constant MINIMUM_INTERVAL = 1 minutes;
    uint256 public constant MINIMUM_REGISTRATION_FEE = 0.01 ether;
    GuardianAdapterFactory public immutable factory;
    GuardianExecutor public executor;

    mapping(uint256 => Protocol) public protocols;
    mapping(address => mapping(uint256 => uint256)) public claimableBounties;
    uint256 public protocolId;
    uint256 public totalAwarded;

    struct Protocol {
        uint256 protocolId;
        uint256 balance;
        uint256 bounty;
        uint256 checkInFee;
        uint256 lastCheckIn;
        uint256 registrationTime;
        bytes invariantPayload;
        bytes emergencyPayload;
        address protocol;
        GuardianAdapter adapter;
        uint32 interval;
        bool incidentActive;
    }

    event Registered(address indexed adapter, address indexed protocol, uint256 indexed protocolId);
    event RegistryDeployed(address indexed registry);
    event ExecutorSet(address indexed executor);
    event BountyUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    event BalanceUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    event ProtocolDeregistered(uint256 indexed protocolId);
    event CheckInFeeUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    event IntervalUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    event InvariantUpdated(uint256 indexed protocolId, bytes previous, bytes next);
    event EmergencyActionUpdated(uint256 indexed protocolId, bytes previous, bytes next);
    event BountyAwarded(uint256 indexed protocolId, address indexed user, uint256 amount);
    event BountyClaimed(uint256 indexed protocolId, address indexed user, uint256 amount);
    event IncidentResolved(uint256 indexed protocolId);

    error ZeroAddress();
    error ExecutorAlreadySet();
    error ValueRequired();
    error InvalidRegistrationAmounts(
        uint256 valuePassed, uint256 bountyPassed, uint256 checkInFeePassed, uint256 minimumRegistrationFee
    );
    error ProtocolNotFound(uint256 id);
    error InvalidIntervalDuration(uint256 passed, uint256 minimum);
    error ActionFailed(bytes data);
    error InSufficientWithdrawableBalance(uint256 passed, uint256 available);
    error NoCodeAtTarget(address target);
    error InvariantCurrentlyBroken();
    error NoAvailableBounty();
    error InsufficientProtocolBalance(uint256 protocolId, uint256 balance, uint256 bounty);

    modifier onlyFactory() {
        require(msg.sender == address(factory));
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == address(executor));
        _;
    }

    modifier onlyOwner(uint256 _protocolId) {
        GuardianAdapter adapter = protocols[_protocolId].adapter;
        require(address(adapter) != address(0));
        address owner = adapter.owner();
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

    function setExecutor(GuardianExecutor _executor) external onlyFactory {
        if (address(executor) != address(0)) {
            revert ExecutorAlreadySet();
        }
        if (address(_executor) == address(0)) {
            revert ZeroAddress();
        }
        executor = _executor;
        emit ExecutorSet(address(_executor));
    }

    /**
     * Registration reverts when:
     * - bounty or msg.value are less than minimum
     * - msg.value is less than bounty or msg.value is less than bounty + checkInFee
     * if the check in fee is not 0, value should cover at least one check in fee.
     *
     * @param _protocol the protocol registering
     * @param _adapter the adapter deployed by the factory
     * @param _invariantPayload  the invariant the adapter will check that must never be broken
     * @param _emergencyActionPayload  what the adapter will call in case the invariant is broken
     * @param _bounty how much the protocol will pay for the report
     * @param _checkInFee how much the protocol pays for a check in (an invariant checl)
     * @param _interval  how often the protocol allows checkins
     */
    function register(
        address _protocol,
        GuardianAdapter _adapter,
        bytes calldata _invariantPayload,
        bytes calldata _emergencyActionPayload,
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
        // so, invariant and emergency selectors can be malicious. how do we protect? what assumptions are safe to make?
        // i will delegate this to later.
        invariantCheck(_protocol, _invariantPayload);

        protocolId += 1;
        Protocol memory p = Protocol({
            protocolId: protocolId,
            balance: msg.value,
            bounty: _bounty,
            checkInFee: _checkInFee,
            lastCheckIn: block.timestamp,
            interval: _interval,
            registrationTime: block.timestamp,
            protocol: _protocol,
            adapter: _adapter,
            invariantPayload: _invariantPayload,
            emergencyPayload: _emergencyActionPayload,
            incidentActive: false
        });
        protocols[p.protocolId] = p;

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
        return p.lastCheckIn;
    }

    /**
     * Protocol Owner actions
     */

    function deRegister(uint256 _protocolId) public onlyOwner(_protocolId) nonReentrant {
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
        if (p.balance < p.bounty) {
            revert InSufficientWithdrawableBalance(_amount, 0);
        }
        uint256 availableBalance = p.balance - p.bounty;
        if (_amount == 0) {
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

    function updateInvariant(uint256 _protocolId, bytes calldata _newInvariant) public onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        invariantCheck(p.protocol, _newInvariant);
        bytes memory previous = p.invariantPayload;
        p.invariantPayload = _newInvariant;

        emit InvariantUpdated(_protocolId, previous, _newInvariant);
    }

    function updateEmergencyAction(uint256 _protocolId, bytes calldata _newEmergency) public onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        bytes memory previous = p.emergencyPayload;
        p.emergencyPayload = _newEmergency;

        emit EmergencyActionUpdated(_protocolId, previous, _newEmergency);
    }

    function resolveIncident(uint256 _protocolId) public onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        invariantCheck(p.protocol, p.invariantPayload);
        if (p.balance < p.bounty) {
            revert InsufficientProtocolBalance(_protocolId, p.balance, p.bounty);
        }
        p.incidentActive = false;
        emit IncidentResolved(_protocolId);
    }

    function invariantCheck(address _protocol, bytes memory _invariant) internal view {
        if (_protocol.code.length == 0) {
            revert NoCodeAtTarget(_protocol);
        }
        (bool ok, bytes memory result) = _protocol.staticcall(_invariant);
        if (!ok) {
            revert ActionFailed(result);
        }
        bool healthy = abi.decode(result, (bool));
        if (!healthy) {
            revert InvariantCurrentlyBroken();
        }
    }

    function awardBounty(uint256 _protocolId, address _watcher) public onlyExecutor {
        Protocol storage p = protocols[_protocolId];
        if (p.protocolId == 0) {
            revert ProtocolNotFound(_protocolId);
        }
        if (p.balance < p.bounty) {
            revert InsufficientProtocolBalance(_protocolId, p.balance, p.bounty);
        }
        p.balance -= p.bounty;
        claimableBounties[_watcher][_protocolId] += p.bounty;
        totalAwarded += p.bounty;
        p.incidentActive = true;
        emit BountyAwarded(_protocolId, _watcher, p.bounty);
    }

    function drip(uint256 _protocolId, address _watcher) public onlyExecutor {
        Protocol storage p = protocols[_protocolId];
        p.balance -= p.checkInFee;
        assert(p.balance >= p.bounty);
        p.lastCheckIn = block.timestamp;
        totalAwarded += p.checkInFee;
        claimableBounties[_watcher][_protocolId] += p.checkInFee;
        emit BountyAwarded(_protocolId, _watcher, p.checkInFee);
    }

    function claim(uint256 _protocolId) public nonReentrant {
        uint256 bounty = claimableBounties[msg.sender][_protocolId];
        if (bounty == 0) {
            revert NoAvailableBounty();
        }
        assert(address(this).balance >= bounty);
        delete claimableBounties[msg.sender][_protocolId];
        emit BountyClaimed(_protocolId, msg.sender, bounty);
        (bool success, bytes memory reason) = msg.sender.call{value: bounty}("");
        if (!success) {
            revert ActionFailed(reason);
        }
    }

    fallback() external payable {}
    receive() external payable {}
}
