// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GuardianAdapter} from "../GuardianAdapter.sol";
import {GuardianExecutor} from "../GuardianExecutor.sol";

interface IDeSecRegistry {
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
    event FeeRecipientTransferStarted(address indexed current, address indexed pending);
    event FeeRecipientTransferred(address indexed previous, address indexed current);
    event NetworkFeesWithdrawn(address indexed recipient, uint256 amount);

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
    error NoNetworkFees();

    function MINIMUM_INTERVAL() external view returns (uint32);
    function MINIMUM_REGISTRATION_FEE() external view returns (uint256);
    function NETWORK_FEE_BPS() external view returns (uint256);
    function BPS_DENOMINATOR() external view returns (uint256);
    function protocolId() external view returns (uint256);
    function totalAwarded() external view returns (uint256);
    function networkFees() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function pendingFeeRecipient() external view returns (address);
    function claimableBounties(address watcher, uint256 protocolId_) external view returns (uint256);

    function transferFeeRecipient(address _newRecipient) external;
    function acceptFeeRecipient() external;
    function withdrawNetworkFees() external;

    function setExecutor(GuardianExecutor _executor) external;
    function register(
        address _protocol,
        GuardianAdapter _adapter,
        bytes calldata _invariantPayload,
        bytes calldata _emergencyActionPayload,
        uint256 _bounty,
        uint256 _checkInFee,
        uint32 _interval
    ) external payable returns (uint256);
    function getProtocol(uint256 _id) external view returns (Protocol memory);
    function remainingCheckIns(uint256 _protocolId) external view returns (uint256);
    function lastCheckIn(uint256 _protocolId) external view returns (uint256);
    function addBounty(uint256 _protocolId) external payable;
    function topUp(uint256 _protocolId) external payable;
    function deRegister(uint256 _protocolId) external;
    function updateCheckInFee(uint256 _protocolId, uint256 _fee) external;
    function updateInterval(uint256 _protocolId, uint32 _interval) external;
    function withdraw(uint256 _protocolId, uint256 _amount) external;
    function updateInvariant(uint256 _protocolId, bytes calldata _newInvariant) external;
    function updateEmergencyAction(uint256 _protocolId, bytes calldata _newEmergency) external;
    function resolveIncident(uint256 _protocolId) external;
    function awardBounty(uint256 _protocolId, address _watcher) external;
    function drip(uint256 _protocolId, address _watcher) external;
    function claim(uint256 _protocolId) external;
}
