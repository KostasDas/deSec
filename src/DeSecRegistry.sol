// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GuardianAdapter} from "./GuardianAdapter.sol";
import {GuardianAdapterFactory} from "./GuardianAdapterFactory.sol";
import {GuardianExecutor} from "./GuardianExecutor.sol";
import {IDeSecRegistry} from "./interfaces/IDeSecRegistry.sol";

/// @title DeSec Registry
/// @dev Implementation notes beyond the interface: `onlyOwner` resolves the administrator from
/// `adapter.owner()` on every call (nothing is cached), escrow accounting is keyed by protocolId, and
/// the receive/fallback pair credits all unsolicited ETH to `networkFees` because senders cannot be
/// identified or refunded. See {IDeSecRegistry} for the full API contract.
contract DeSecRegistry is IDeSecRegistry, ReentrancyGuard {
    uint32 public constant override MINIMUM_INTERVAL = 1 minutes;
    uint256 public constant override MINIMUM_REGISTRATION_FEE = 0.01 ether;
    uint256 public constant override NETWORK_FEE_BPS = 100;
    uint256 public constant override BPS_DENOMINATOR = 10_000;
    GuardianAdapterFactory public immutable factory;
    GuardianExecutor public executor;

    mapping(uint256 => Protocol) public protocols;
    mapping(address => mapping(uint256 => uint256)) public override claimableBounties;
    uint256 public override protocolId;
    uint256 public override totalAwarded;
    uint256 public override networkFees;
    address public override feeRecipient;
    address public override pendingFeeRecipient;

    modifier onlyFactory() {
        require(msg.sender == address(factory));
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == address(executor));
        _;
    }

    modifier onlyFeeRecipient() {
        require(msg.sender == feeRecipient);
        _;
    }

    modifier onlyOwner(uint256 _protocolId) {
        GuardianAdapter adapter = protocols[_protocolId].adapter;
        require(address(adapter) != address(0));
        address owner = adapter.owner();
        require(owner == msg.sender);
        _;
    }

    /// @dev The `feeRecipient` manages itself from deployment on — there is no separate admin for the fee pool.
    /// @param _factory The one factory allowed to register records, bound immutably here as an anti-grief measure.
    /// @param _feeRecipient Initial owner of the network fee pool; the factory passes its own deployer.
    constructor(GuardianAdapterFactory _factory, address _feeRecipient) {
        if (address(_factory) == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        factory = _factory;
        feeRecipient = _feeRecipient;

        emit RegistryDeployed(address(this));
    }

    /// @inheritdoc IDeSecRegistry
    function setExecutor(GuardianExecutor _executor) external override onlyFactory {
        if (address(executor) != address(0)) {
            revert ExecutorAlreadySet();
        }
        if (address(_executor) == address(0)) {
            revert ZeroAddress();
        }
        executor = _executor;
        emit ExecutorSet(address(_executor));
    }

    /// @inheritdoc IDeSecRegistry
    /// @dev Registration reverts when:
    /// - bounty or msg.value are less than minimum
    /// - msg.value is less than bounty or msg.value is less than bounty + checkInFee
    /// if the check in fee is not 0, value should cover at least one check in fee.
    /// @param _protocol the protocol registering
    /// @param _adapter the adapter deployed by the factory
    /// @param _invariantPayload the invariant the adapter will check that must never be broken
    /// @param _emergencyActionPayload what the adapter will call in case the invariant is broken
    /// @param _bounty how much the protocol will pay for the report
    /// @param _checkInFee how much the protocol pays for a check in (an invariant check)
    /// @param _interval how often the protocol allows checkins
    function register(
        address _protocol,
        GuardianAdapter _adapter,
        bytes calldata _invariantPayload,
        bytes calldata _emergencyActionPayload,
        uint256 _bounty,
        uint256 _checkInFee,
        uint32 _interval
    ) public payable override onlyFactory returns (uint256) {
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

    /// @inheritdoc IDeSecRegistry
    function getProtocol(uint256 _id) public view override returns (Protocol memory) {
        Protocol memory p = protocols[_id];
        if (p.protocolId == 0) {
            revert ProtocolNotFound(_id);
        }
        return p;
    }

    /// @inheritdoc IDeSecRegistry
    function addBounty(uint256 _protocolId) public payable override onlyOwner(_protocolId) {
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

    /// @inheritdoc IDeSecRegistry
    function topUp(uint256 _protocolId) external payable override onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        if (msg.value == 0) {
            revert ValueRequired();
        }
        uint256 previous = p.balance;
        p.balance += msg.value;

        emit BalanceUpdated(_protocolId, previous, p.balance);
    }

    /// @inheritdoc IDeSecRegistry
    function remainingCheckIns(uint256 _protocolId) external view override returns (uint256) {
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

    /// @inheritdoc IDeSecRegistry
    function lastCheckIn(uint256 _protocolId) external view override returns (uint256) {
        Protocol storage p = protocols[_protocolId];
        if (p.protocolId == 0) {
            revert ProtocolNotFound(_protocolId);
        }
        return p.lastCheckIn;
    }

    /**
     * Protocol Owner actions
     */

    /// @inheritdoc IDeSecRegistry
    function deRegister(uint256 _protocolId) public override onlyOwner(_protocolId) nonReentrant {
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

    /// @inheritdoc IDeSecRegistry
    function updateCheckInFee(uint256 _protocolId, uint256 _fee) public override onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        uint256 previous = p.checkInFee;
        p.checkInFee = _fee; // we allow _fee to be 0
        emit CheckInFeeUpdated(_protocolId, previous, _fee);
    }

    /// @inheritdoc IDeSecRegistry
    function updateInterval(uint256 _protocolId, uint32 _interval) public override onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        if (_interval < MINIMUM_INTERVAL) {
            revert InvalidIntervalDuration(_interval, MINIMUM_INTERVAL);
        }
        uint256 previous = p.interval;
        p.interval = _interval;
        emit IntervalUpdated(_protocolId, previous, _interval);
    }

    /// @inheritdoc IDeSecRegistry
    function withdraw(uint256 _protocolId, uint256 _amount) public override onlyOwner(_protocolId) nonReentrant {
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

    /// @inheritdoc IDeSecRegistry
    function updateInvariant(uint256 _protocolId, bytes calldata _newInvariant) public override onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        invariantCheck(p.protocol, _newInvariant);
        bytes memory previous = p.invariantPayload;
        p.invariantPayload = _newInvariant;

        emit InvariantUpdated(_protocolId, previous, _newInvariant);
    }

    /// @inheritdoc IDeSecRegistry
    function updateEmergencyAction(uint256 _protocolId, bytes calldata _newEmergency)
        public
        override
        onlyOwner(_protocolId)
    {
        Protocol storage p = protocols[_protocolId];
        bytes memory previous = p.emergencyPayload;
        p.emergencyPayload = _newEmergency;

        emit EmergencyActionUpdated(_protocolId, previous, _newEmergency);
    }

    /// @inheritdoc IDeSecRegistry
    function resolveIncident(uint256 _protocolId) public override onlyOwner(_protocolId) {
        Protocol storage p = protocols[_protocolId];
        invariantCheck(p.protocol, p.invariantPayload);
        if (p.balance < p.bounty) {
            revert InsufficientProtocolBalance(_protocolId, p.balance, p.bounty);
        }
        p.incidentActive = false;
        emit IncidentResolved(_protocolId);
    }

    /// @dev Test-fires the invariant read-only: the target must hold code, the call must succeed, and
    /// the answer must be true. Used at registration, on every invariant update, and at incident resolution.
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

    /// @inheritdoc IDeSecRegistry
    function awardBounty(uint256 _protocolId, address _watcher) public override onlyExecutor {
        Protocol storage p = protocols[_protocolId];
        if (p.protocolId == 0) {
            revert ProtocolNotFound(_protocolId);
        }
        if (p.balance < p.bounty) {
            revert InsufficientProtocolBalance(_protocolId, p.balance, p.bounty);
        }
        p.balance -= p.bounty;
        uint256 fee = (p.bounty * NETWORK_FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = p.bounty - fee;
        networkFees += fee;
        claimableBounties[_watcher][_protocolId] += net;
        totalAwarded += net;
        p.incidentActive = true;
        emit BountyAwarded(_protocolId, _watcher, net);
    }

    /// @inheritdoc IDeSecRegistry
    function drip(uint256 _protocolId, address _watcher) public override onlyExecutor {
        Protocol storage p = protocols[_protocolId];
        p.balance -= p.checkInFee;
        assert(p.balance >= p.bounty);
        p.lastCheckIn = block.timestamp;
        totalAwarded += p.checkInFee;
        claimableBounties[_watcher][_protocolId] += p.checkInFee;
        emit BountyAwarded(_protocolId, _watcher, p.checkInFee);
    }

    /// @inheritdoc IDeSecRegistry
    function claim(uint256 _protocolId) public override nonReentrant {
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

    fallback() external payable {
        networkFees += msg.value;
    }

    receive() external payable {
        networkFees += msg.value;
    }

    /// @inheritdoc IDeSecRegistry
    function transferFeeRecipient(address _newRecipient) external override onlyFeeRecipient {
        if (_newRecipient == address(0)) {
            revert ZeroAddress();
        }
        pendingFeeRecipient = _newRecipient;
        emit FeeRecipientTransferStarted(feeRecipient, _newRecipient);
    }

    /// @inheritdoc IDeSecRegistry
    function acceptFeeRecipient() external override {
        require(msg.sender == pendingFeeRecipient);
        address previous = feeRecipient;
        feeRecipient = pendingFeeRecipient;
        delete pendingFeeRecipient;
        emit FeeRecipientTransferred(previous, feeRecipient);
    }

    /// @inheritdoc IDeSecRegistry
    function withdrawNetworkFees() external override onlyFeeRecipient nonReentrant {
        uint256 amount = networkFees;
        if (amount == 0) {
            revert NoNetworkFees();
        }
        networkFees = 0;
        emit NetworkFeesWithdrawn(feeRecipient, amount);
        (bool success, bytes memory reason) = msg.sender.call{value: amount}("");
        if (!success) {
            revert ActionFailed(reason);
        }
    }
}
