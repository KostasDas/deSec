// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GuardianAdapter} from "../GuardianAdapter.sol";
import {GuardianExecutor} from "../GuardianExecutor.sol";

/// @title DeSec Registry
/// @notice The vault and ledger of the deSec monitoring network. Holds one escrowed record per
/// protocol — its invariant, its emergency action, its economic configuration, and its deposit —
/// and pays watchers for verified invariant checks.
/// @dev Registration is restricted to the GuardianAdapterFactory bound immutably at construction, and
/// only the wired GuardianExecutor may debit escrow (awardBounty / drip). The administrator of every
/// record is resolved live from `adapter.owner()` on each privileged call, so rotating adapter
/// ownership (Ownable2Step) instantly rotates admin rights with no migration.
interface IDeSecRegistry {
    /// @notice One protocol's complete relationship with the network: what to check, what to fire,
    /// and the escrow that pays for both.
    /// @dev `balance` can never drop below `bounty` while the record exists — the prize is always
    /// reserved. Payloads are complete `abi.encodeCall` values (function plus arguments), never bare
    /// selectors, so a watcher can only fire the exact pre-authorized call, never choose arguments.
    struct Protocol {
        /// @dev Assigned sequentially from 1 at registration; 0 means "no record" and serves as the existence check.
        uint256 protocolId;
        /// @dev Escrowed ETH funding bounties and heartbeat fees; the `bounty` portion is locked as a reserve.
        uint256 balance;
        /// @dev Gross prize for the first verified breach. Increase-only while the record exists, so a
        /// pending trigger can never be front-run by shrinking the prize.
        uint256 bounty;
        /// @dev Paid in full (no network skim) to the watcher of each healthy heartbeat. 0 means bounty-only mode.
        uint256 checkInFee;
        /// @dev Timestamp of the last paid checkIn; starts at registration time, so the first interval elapses from registration.
        uint256 lastCheckIn;
        uint256 registrationTime;
        /// @dev The health question, static-called at every check. Must be permissionless (watchers are
        /// anonymous) and must never revert — a reverting invariant is treated as unevaluable, not as a violation.
        bytes invariantPayload;
        /// @dev Fired through the adapter when a breach is verified. Empty means monitoring-only: no call is attempted.
        bytes emergencyPayload;
        /// @dev Target of the invariant staticcall and of the emergency call.
        address protocol;
        /// @dev Holds the protocol's emergency role; `adapter.owner()` is the record administrator, read live on every privileged call.
        GuardianAdapter adapter;
        /// @dev Minimum seconds between paid checkIns; floored network-wide at MINIMUM_INTERVAL so no record can be drained instantly.
        uint32 interval;
        /// @dev Set when a breach is verified; blocks further report/checkIn (and double payouts) until the owner resolves the incident.
        bool incidentActive;
    }

    /// @notice A record was created; the adapter deployment and the registration are one atomic factory transaction.
    /// @param adapter The freshly deployed GuardianAdapter that will hold the protocol's emergency role.
    /// @param protocol The contract the invariant is checked against.
    /// @param protocolId The new record's id, assigned sequentially from 1.
    event Registered(address indexed adapter, address indexed protocol, uint256 indexed protocolId);
    /// @notice Emitted at construction so the registry address is discoverable from the factory's deployment logs.
    event RegistryDeployed(address indexed registry);
    /// @notice Emitted exactly once, when the factory wires the executor at deployment; the setter is set-once.
    /// @param executor The only contract that will ever be allowed to call awardBounty and drip.
    event ExecutorSet(address indexed executor);
    /// @notice The owner increased the bounty; `next` is always greater than `previous`.
    event BountyUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    /// @notice The escrowed balance changed through topUp, addBounty, or withdraw; awardBounty and drip debits do not emit it.
    event BalanceUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    /// @notice The record was deleted and its entire balance, bounty reserve included, refunded to the administrator.
    event ProtocolDeregistered(uint256 indexed protocolId);
    /// @notice The per-heartbeat payment changed; a `next` of 0 switches the record to bounty-only mode.
    event CheckInFeeUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    /// @notice The minimum time between paid heartbeats changed; `next` is guaranteed to be at least MINIMUM_INTERVAL.
    event IntervalUpdated(uint256 indexed protocolId, uint256 previous, uint256 next);
    /// @notice The invariant payload was replaced after the new payload was successfully test-fired against the protocol.
    event InvariantUpdated(uint256 indexed protocolId, bytes previous, bytes next);
    /// @notice The emergency payload was replaced; it cannot be test-fired in advance, so correctness is the owner's responsibility.
    event EmergencyActionUpdated(uint256 indexed protocolId, bytes previous, bytes next);
    /// @notice A watcher was credited a claimable balance. For a bounty, `amount` is the NET prize after
    /// the 1% network skim; this event also carries heartbeat drips, where `amount` is the full checkInFee.
    event BountyAwarded(uint256 indexed protocolId, address indexed user, uint256 amount);
    /// @notice A watcher withdrew their claimable balance.
    event BountyClaimed(uint256 indexed protocolId, address indexed user, uint256 amount);
    /// @notice The owner cleared the incident flag after the invariant test-fired healthy and the balance
    /// covered the bounty; monitoring is re-armed.
    event IncidentResolved(uint256 indexed protocolId);
    /// @notice The current fee recipient named a successor; the role moves only if the successor accepts.
    event FeeRecipientTransferStarted(address indexed current, address indexed pending);
    /// @notice The successor accepted; the fee recipient rotation is complete.
    event FeeRecipientTransferred(address indexed previous, address indexed current);
    /// @notice The fee recipient pulled the accumulated network fee pool — the only exit for those funds.
    event NetworkFeesWithdrawn(address indexed recipient, uint256 amount);

    /// @notice A required address — factory, executor, fee recipient, or fee-recipient successor — was the zero address.
    error ZeroAddress();
    /// @notice setExecutor was called after the factory already wired the executor; the wiring is set-once and immutable.
    error ExecutorAlreadySet();
    /// @notice A funding call carried no ETH, or withdraw was asked for a zero amount.
    error ValueRequired();
    /// @notice Registration funding failed a floor: msg.value or bounty below the minimum registration
    /// fee, or msg.value below bounty + checkInFee (the prize plus at least one paid check).
    /// @param valuePassed The msg.value sent with the registration.
    /// @param bountyPassed The declared bounty, which must itself meet the minimum.
    /// @param checkInFeePassed The declared per-check fee; msg.value must cover bounty plus one of these.
    /// @param minimumRegistrationFee The floor (0.01 ether) applied to both msg.value and bounty.
    error InvalidRegistrationAmounts(
        uint256 valuePassed, uint256 bountyPassed, uint256 checkInFeePassed, uint256 minimumRegistrationFee
    );
    /// @notice No record exists for `id` — it was never registered or was already deregistered.
    error ProtocolNotFound(uint256 id);
    /// @notice An interval below the floor was supplied. Registration treats 0 as "use the minimum",
    /// but any other sub-floor value is rejected rather than silently corrected.
    /// @param passed The interval the caller asked for.
    /// @param minimum The network-wide floor, MINIMUM_INTERVAL.
    error InvalidIntervalDuration(uint256 passed, uint256 minimum);
    /// @notice A low-level call reverted — an invariant test-fire, a payout, or an emergency dispatch; `data` carries the bubbled revert reason.
    error ActionFailed(bytes data);
    /// @notice withdraw asked for more than the balance minus the reserved bounty.
    /// @param passed The amount requested.
    /// @param available The maximum withdrawable amount above the reserve.
    error InSufficientWithdrawableBalance(uint256 passed, uint256 available);
    /// @notice The invariant target holds no code; checked before every test-fire.
    error NoCodeAtTarget(address target);
    /// @notice A test-fired invariant returned false, so the registration, invariant update, or incident resolution was rejected.
    error InvariantCurrentlyBroken();
    /// @notice claim was called with a zero claimable balance.
    error NoAvailableBounty();
    /// @notice The record's balance is below its bounty, so the award or incident resolution cannot proceed.
    /// @param protocolId The underfunded record.
    /// @param balance The record's escrowed balance.
    /// @param bounty The reserved prize the balance must cover.
    error InsufficientProtocolBalance(uint256 protocolId, uint256 balance, uint256 bounty);
    /// @notice withdrawNetworkFees was called with an empty fee pool.
    error NoNetworkFees();

    /// @notice Network-wide floor (1 minute) on the check interval, so no configuration can be drained instantly.
    function MINIMUM_INTERVAL() external view returns (uint32);
    /// @notice Floor (0.01 ether) applied to both msg.value and the bounty at registration.
    function MINIMUM_REGISTRATION_FEE() external view returns (uint256);
    /// @notice Share of each awarded bounty skimmed into the network fee pool: 100 out of
    /// BPS_DENOMINATOR = 1%. Heartbeat drips are never skimmed.
    function NETWORK_FEE_BPS() external view returns (uint256);
    /// @notice Denominator for basis-point math: 10,000.
    function BPS_DENOMINATOR() external view returns (uint256);
    /// @notice Count of records ever created and the source of new ids; ids start at 1 and are never reused, even after deregistration.
    function protocolId() external view returns (uint256);
    /// @notice Cumulative watcher earnings credited — net bounties plus full heartbeat fees; excludes the network skim.
    function totalAwarded() external view returns (uint256);
    /// @notice Accumulated network revenue: the 1% bounty skim plus every wei sent outside a protocol
    /// action, which receive/fallback credit here because senders cannot be identified or refunded.
    function networkFees() external view returns (uint256);
    /// @notice The only address that may withdraw networkFees and start rotation of its own role; set at construction to the factory's deployer.
    function feeRecipient() external view returns (address);
    /// @notice Successor named by the current feeRecipient; holds no power until it calls acceptFeeRecipient.
    function pendingFeeRecipient() external view returns (address);
    /// @notice Pull-pattern earnings of a watcher against a record: net bounties and full drip fees, claimable via claim.
    /// @param watcher The earner — the address that submitted the report or checkIn.
    /// @param protocolId_ The record the earnings were credited against.
    /// @return The ETH amount waiting to be claimed.
    function claimableBounties(address watcher, uint256 protocolId_) external view returns (uint256);

    /// @notice Starts rotation of the fee recipient role.
    /// @dev Two-step by design: the role moves only when the successor accepts, so a mistyped address
    /// can never capture it. Callable only by the current feeRecipient.
    /// @param _newRecipient The proposed successor, stored as pendingFeeRecipient until it accepts.
    function transferFeeRecipient(address _newRecipient) external;
    /// @notice Completes the rotation started by transferFeeRecipient.
    /// @dev Only the pending recipient can call this; an address that was never named cannot take the role.
    function acceptFeeRecipient() external;
    /// @notice Withdraws the entire network fee pool — the only exit for skimmed bounties, donations, and mistaken transfers.
    /// @dev Pull-based and callable only by the feeRecipient.
    function withdrawNetworkFees() external;

    /// @notice Wires the GuardianExecutor into the registry — the only contract allowed to debit escrow via awardBounty/drip.
    /// @dev Set-once and factory-only: the factory calls it during its own construction and it can never be called again.
    /// @param _executor The freshly deployed executor for this network.
    function setExecutor(GuardianExecutor _executor) external;
    /// @notice Creates a protocol's escrowed record and test-fires its invariant before accepting it.
    /// @dev Callable only by the GuardianAdapterFactory as part of its atomic deploy-and-register. The
    /// test-fire proves the target holds code, the function exists, and it answers with a bool. Requires
    /// msg.value >= bounty + checkInFee (the prize plus at least one paid check) and >= MINIMUM_REGISTRATION_FEE.
    /// An `_interval` of 0 means "use MINIMUM_INTERVAL"; any other sub-floor value reverts. `lastCheckIn`
    /// starts at registration, so the first paid heartbeat is one interval away.
    /// @param _protocol Contract the invariant is static-called on; also the target of the emergency payload.
    /// @param _adapter Adapter deployed in the same transaction by the factory; its owner() becomes the record administrator.
    /// @param _invariantPayload Complete `abi.encodeCall` (function + arguments) of the health check;
    /// must be read-only, permissionless, and non-reverting.
    /// @param _emergencyActionPayload Complete `abi.encodeCall` fired through the adapter on a verified
    /// breach; empty for monitoring-only protocols.
    /// @param _bounty Gross prize for the first verified breach, reserved out of the balance for the record's lifetime.
    /// @param _checkInFee Per-heartbeat payment; 0 registers the protocol in bounty-only mode.
    /// @param _interval Minimum seconds between paid checkIns; 0 selects MINIMUM_INTERVAL.
    /// @return The new record's protocolId, assigned sequentially from 1.
    function register(
        address _protocol,
        GuardianAdapter _adapter,
        bytes calldata _invariantPayload,
        bytes calldata _emergencyActionPayload,
        uint256 _bounty,
        uint256 _checkInFee,
        uint32 _interval
    ) external payable returns (uint256);
    /// @notice Returns a full copy of a record — the call a watcher bot polls to decide where to work.
    /// @dev Reverts with ProtocolNotFound for unknown ids instead of returning a zero struct.
    /// @param _id The record to read.
    function getProtocol(uint256 _id) external view returns (Protocol memory);
    /// @notice How many paid heartbeats the record can currently afford: (balance - bounty) / checkInFee.
    /// @dev Derived, never stored; returns 0 when checkInFee is 0 (bounty-only mode) or only the reserve
    /// is left. A free view call, so depletion is never a surprise to watchers or the protocol.
    /// @param _protocolId The record to measure.
    /// @return The number of funded checkIns remaining; the runway is this times the interval.
    function remainingCheckIns(uint256 _protocolId) external view returns (uint256);
    /// @notice Timestamp of the last paid heartbeat; equals the registration time until the first checkIn.
    /// @param _protocolId The record to read.
    function lastCheckIn(uint256 _protocolId) external view returns (uint256);
    /// @notice Increases the bounty — the only direction the prize may move while the record exists.
    /// @dev Increase-only by design: a prize that could shrink could be withdrawn in front of a pending
    /// trigger. The full msg.value raises both bounty and balance, preserving the reserve invariant. A
    /// lower bounty requires deregistering and re-registering.
    /// @param _protocolId The record whose prize to grow.
    function addBounty(uint256 _protocolId) external payable;
    /// @notice Adds escrow without touching the bounty, extending the heartbeat runway.
    /// @param _protocolId The record to fund.
    function topUp(uint256 _protocolId) external payable;
    /// @notice Deletes the record and refunds the entire balance, bounty reserve included, to the administrator.
    /// @dev The only way the reserve is released without a verified breach. Revoking the adapter's role
    /// on the protocol's own contracts is a separate governance action on the protocol's side.
    /// @param _protocolId The record to close.
    function deRegister(uint256 _protocolId) external;
    /// @notice Changes the per-heartbeat payment; 0 is allowed and switches the record to bounty-only mode.
    /// @param _protocolId The record to reconfigure.
    /// @param _fee The new checkInFee.
    function updateCheckInFee(uint256 _protocolId, uint256 _fee) external;
    /// @notice Changes the minimum time between paid heartbeats; values below MINIMUM_INTERVAL revert.
    /// @param _protocolId The record to reconfigure.
    /// @param _interval The new interval in seconds.
    function updateInterval(uint256 _protocolId, uint32 _interval) external;
    /// @notice Reclaims escrow above the reserved bounty.
    /// @dev The balance can never drop below the bounty while the record exists — the prize stays locked
    /// until paid to a watcher or reclaimed through deRegister.
    /// @param _protocolId The record to draw from.
    /// @param _amount The amount to withdraw; must fit within balance minus bounty.
    function withdraw(uint256 _protocolId, uint256 _amount) external;
    /// @notice Replaces the invariant payload after test-firing the new one — a malformed or currently-failing replacement is rejected, never stored.
    /// @param _protocolId The record to update.
    /// @param _newInvariant Complete `abi.encodeCall` of the new health check.
    function updateInvariant(uint256 _protocolId, bytes calldata _newInvariant) external;
    /// @notice Replaces the emergency payload. Unlike the invariant it cannot be test-fired — firing it
    /// IS the emergency — so correctness and the adapter's permission grant are the owner's responsibility.
    /// @param _protocolId The record to update.
    /// @param _newEmergency Complete `abi.encodeCall` of the new emergency call; empty for monitoring-only.
    function updateEmergencyAction(uint256 _protocolId, bytes calldata _newEmergency) external;
    /// @notice Clears the incident flag after a breach, re-arming report and checkIn.
    /// @dev Test-fires the invariant first and requires it healthy, and requires the balance to still
    /// cover the bounty — resolution cannot hide an ongoing breach or an unpayable prize.
    /// @param _protocolId The record to re-arm.
    function resolveIncident(uint256 _protocolId) external;
    /// @notice Pays a verified breach: debits the gross bounty from escrow, skims NETWORK_FEE_BPS into
    /// networkFees, and credits the watcher the net as a claimable balance.
    /// @dev Executor-only; also sets incidentActive, blocking further report/checkIn until the owner
    /// resolves. Emits BountyAwarded with the NET amount.
    /// @param _protocolId The breached record.
    /// @param _watcher The address that submitted the verified report.
    function awardBounty(uint256 _protocolId, address _watcher) external;
    /// @notice Pays a healthy heartbeat: credits the watcher the full checkInFee (no skim) and stamps lastCheckIn.
    /// @dev Executor-only. Cannot draw the balance below the bounty reserve — guarded by the executor's
    /// remainingCheckIns check and an assert in the implementation. Emits BountyAwarded with the fee amount.
    /// @param _protocolId The record that was checked.
    /// @param _watcher The address that performed the heartbeat.
    function drip(uint256 _protocolId, address _watcher) external;
    /// @notice Withdraws the caller's claimable balance for a record.
    /// @dev Pull-over-push: time-critical triggers credit balances instead of sending ETH, so they never
    /// transfer money to untrusted recipients.
    /// @param _protocolId The record the earnings were credited against.
    function claim(uint256 _protocolId) external;
}
