// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {DeSecRegistry} from "../../src/DeSecRegistry.sol";
import {IDeSecRegistry} from "../../src/interfaces/IDeSecRegistry.sol";
import {GuardianAdapterFactory} from "../../src/GuardianAdapterFactory.sol";
import {GuardianAdapter} from "../../src/GuardianAdapter.sol";
import {GuardianExecutor} from "../../src/GuardianExecutor.sol";
import {MockProtocol} from "../mocks/MockProtocol.sol";

contract DeSecHandler is Test {
    GuardianAdapterFactory public factory;
    DeSecRegistry public registry;
    GuardianExecutor public executor;
    MockProtocol[] public mocks;

    address public watcherOne = makeAddr("Watcher_One");
    address public watcherTwo = makeAddr("Watcher_Two");

    uint256[] public liveIds;
    uint256[] public allIds;

    uint256 public ghostAwarded;
    uint256 public ghostClaimed;
    uint256 public ghostClaimableOutstanding;
    bool public reportDuringIncidentSucceeded;
    bool public checkInDuringIncidentSucceeded;
    bool public bountyDecreased;
    mapping(uint256 => uint256) public ghostLastBounty;

    constructor() {
        factory = new GuardianAdapterFactory();
        registry = factory.registry();
        executor = factory.executor();
        for (uint256 i = 0; i < 3; i++) {
            mocks.push(new MockProtocol());
        }
    }

    receive() external payable {}

    function registerProtocol(uint256 bountySeed, uint256 feeSeed, uint256 extraSeed, uint256 mockSeed) external {
        MockProtocol mock = _pickMock(mockSeed);
        uint256 bounty = bound(bountySeed, registry.MINIMUM_REGISTRATION_FEE(), 50 ether);
        uint256 fee = bound(feeSeed, 0, 1 ether);
        uint256 value = bounty + fee + bound(extraSeed, 0, 50 ether);
        (address adapter, uint256 id) = factory.register{value: value}(
            address(mock),
            abi.encodeCall(MockProtocol.isHealthy, ()),
            abi.encodeCall(MockProtocol.pause, ()),
            bounty,
            fee,
            5 minutes,
            address(this)
        );
        mock.grantRole(mock.PAUSER_ROLE(), adapter);
        liveIds.push(id);
        allIds.push(id);
        _syncBounty(id);
    }

    function topUp(uint256 idSeed, uint256 amountSeed) external {
        uint256 id = _pickLive(idSeed);
        if (id == 0) return;
        uint256 amount = bound(amountSeed, 0, 10 ether);
        try registry.topUp{value: amount}(id) {} catch {}
        _syncBounty(id);
    }

    function addBounty(uint256 idSeed, uint256 amountSeed) external {
        uint256 id = _pickLive(idSeed);
        if (id == 0) return;
        uint256 amount = bound(amountSeed, 0, 10 ether);
        try registry.addBounty{value: amount}(id) {} catch {}
        _syncBounty(id);
    }

    function withdraw(uint256 idSeed, uint256 amountSeed) external {
        uint256 id = _pickLive(idSeed);
        if (id == 0) return;
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        uint256 amount = bound(amountSeed, 0, p.balance);
        try registry.withdraw(id, amount) {} catch {}
        _syncBounty(id);
    }

    function deRegister(uint256 idSeed) external {
        if (liveIds.length == 0) return;
        uint256 index = idSeed % liveIds.length;
        uint256 id = liveIds[index];
        _syncBounty(id);
        try registry.deRegister(id) {
            liveIds[index] = liveIds[liveIds.length - 1];
            liveIds.pop();
            delete ghostLastBounty[id];
        } catch {}
    }

    function breakProtocol(uint256 mockSeed) external {
        _pickMock(mockSeed).breakHealth();
    }

    function healProtocol(uint256 mockSeed) external {
        _pickMock(mockSeed).heal();
    }

    function report(uint256 idSeed, uint256 watcherSeed) external {
        uint256 id = _pickLive(idSeed);
        if (id == 0) return;
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        address watcher = _pickWatcher(watcherSeed);
        vm.prank(watcher);
        if (p.incidentActive) {
            try executor.report(id) {
                reportDuringIncidentSucceeded = true;
            } catch {}
        } else {
            try executor.report(id) {
                ghostAwarded += p.bounty;
                ghostClaimableOutstanding += p.bounty;
            } catch {}
        }
        _syncBounty(id);
    }

    function resolveIncident(uint256 idSeed) external {
        uint256 id = _pickLive(idSeed);
        if (id == 0) return;
        try registry.resolveIncident(id) {} catch {}
        _syncBounty(id);
    }

    function checkIn(uint256 idSeed, uint256 watcherSeed, uint256 warpSeed) external {
        uint256 id = _pickLive(idSeed);
        if (id == 0) return;
        IDeSecRegistry.Protocol memory pre = registry.getProtocol(id);
        vm.warp(block.timestamp + bound(warpSeed, 0, 10 minutes));
        address watcher = _pickWatcher(watcherSeed);
        vm.prank(watcher);
        try executor.checkIn(id) {
            if (pre.incidentActive) {
                checkInDuringIncidentSucceeded = true;
                return;
            }
            IDeSecRegistry.Protocol memory post = registry.getProtocol(id);
            if (post.incidentActive) {
                ghostAwarded += pre.bounty;
                ghostClaimableOutstanding += pre.bounty;
            } else {
                ghostAwarded += pre.checkInFee;
                ghostClaimableOutstanding += pre.checkInFee;
            }
        } catch {}
        _syncBounty(id);
    }

    function claim(uint256 idSeed, uint256 watcherSeed) external {
        uint256 id = _pickAny(idSeed);
        if (id == 0) return;
        address watcher = _pickWatcher(watcherSeed);
        uint256 claimable = registry.claimableBounties(watcher, id);
        vm.prank(watcher);
        try registry.claim(id) {
            ghostClaimed += claimable;
            ghostClaimableOutstanding -= claimable;
        } catch {}
    }

    function liveIdList() external view returns (uint256[] memory) {
        return liveIds;
    }

    function _pickLive(uint256 seed) internal view returns (uint256) {
        if (liveIds.length == 0) return 0;
        return liveIds[seed % liveIds.length];
    }

    function _pickAny(uint256 seed) internal view returns (uint256) {
        if (allIds.length == 0) return 0;
        return allIds[seed % allIds.length];
    }

    function _pickWatcher(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? watcherOne : watcherTwo;
    }

    function _pickMock(uint256 seed) internal view returns (MockProtocol) {
        return mocks[seed % mocks.length];
    }

    function _syncBounty(uint256 id) internal {
        if (id == 0) return;
        IDeSecRegistry.Protocol memory p = registry.getProtocol(id);
        uint256 last = ghostLastBounty[id];
        if (last != 0 && p.bounty < last) {
            bountyDecreased = true;
        }
        ghostLastBounty[id] = p.bounty;
    }
}

contract DeSecInvariantsTest is Test {
    DeSecHandler handler;
    DeSecRegistry registry;

    function setUp() public {
        handler = new DeSecHandler();
        registry = handler.registry();
        vm.deal(address(handler), 1_000_000 ether);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = DeSecHandler.registerProtocol.selector;
        selectors[1] = DeSecHandler.topUp.selector;
        selectors[2] = DeSecHandler.addBounty.selector;
        selectors[3] = DeSecHandler.withdraw.selector;
        selectors[4] = DeSecHandler.deRegister.selector;
        selectors[5] = DeSecHandler.breakProtocol.selector;
        selectors[6] = DeSecHandler.healProtocol.selector;
        selectors[7] = DeSecHandler.report.selector;
        selectors[8] = DeSecHandler.resolveIncident.selector;
        selectors[9] = DeSecHandler.claim.selector;
        selectors[10] = DeSecHandler.checkIn.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_registryBalanceCoversAllObligations() public view {
        uint256 recordsSum;
        uint256[] memory ids = handler.liveIdList();
        for (uint256 i = 0; i < ids.length; i++) {
            recordsSum += registry.getProtocol(ids[i]).balance;
        }
        // surplus is possible: direct donations via receive/fallback
        assertGe(address(registry).balance, recordsSum + handler.ghostClaimableOutstanding());
    }

    function invariant_totalAwardedMatchesEveryAward() public view {
        assertEq(registry.totalAwarded(), handler.ghostAwarded());
    }

    function invariant_claimedNeverExceedsAwarded() public view {
        assertLe(handler.ghostClaimed(), registry.totalAwarded());
    }

    function invariant_noUnderwaterRecordOutsideIncident() public view {
        uint256[] memory ids = handler.liveIdList();
        for (uint256 i = 0; i < ids.length; i++) {
            IDeSecRegistry.Protocol memory p = registry.getProtocol(ids[i]);
            if (!p.incidentActive) {
                assertGe(p.balance, p.bounty);
            }
        }
    }

    function invariant_noReportSucceedsDuringIncident() public view {
        assertFalse(handler.reportDuringIncidentSucceeded());
    }

    function invariant_noCheckInSucceedsDuringIncident() public view {
        assertFalse(handler.checkInDuringIncidentSucceeded());
    }

    function invariant_bountyNeverDecreases() public view {
        assertFalse(handler.bountyDecreased());
    }

    function invariant_executorNeverChanges() public view {
        assertEq(address(registry.executor()), address(handler.factory().executor()));
    }
}
