// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {MockApass} from "../../mocks/MockApass.sol";
import {MockVerifiedAsset} from "../../mocks/MockVerifiedAsset.sol";
import {CreditManager} from "../../../src/CreditManager.sol";
import {StandingPool} from "../../../src/StandingPool.sol";

/// @notice Drives the protocol through arbitrary sequences of realistic actions.
/// @dev Every action is wrapped in try/catch so a refused call is a no-op rather than the end of the
///      run: the point is to reach deep states, not to prove that reverts revert.
contract StandingHandler is Test {
    StandingPool public immutable pool;
    CreditManager public immutable manager;
    MockVerifiedAsset public immutable asset;
    MockApass public immutable apass;

    address[] public lenders;
    address[] public borrowers;
    bytes32[] public identities;
    uint256[] public loanIds;

    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostOpens;
    uint256 public ghostRepays;
    uint256 public ghostDefaults;

    constructor(StandingPool pool_, CreditManager manager_, MockVerifiedAsset asset_, MockApass apass_) {
        pool = pool_;
        manager = manager_;
        asset = asset_;
        apass = apass_;

        _addLender("handler:lender:1", keccak256("handler:kyc:l1"));
        _addLender("handler:lender:2", keccak256("handler:kyc:l2"));

        // Two identities, three wallets: the first identity is held by two of them, so the shared
        // credit line is exercised by the fuzzer rather than only by the targeted tests.
        bytes32 idA = keccak256("handler:kyc:a");
        bytes32 idB = keccak256("handler:kyc:b");
        identities.push(idA);
        identities.push(idB);
        _addBorrower("handler:borrower:a1", idA);
        _addBorrower("handler:borrower:a2", idA);
        _addBorrower("handler:borrower:b1", idB);
    }

    // ------------------------------------------------------------------ actions

    function deposit(uint256 actorSeed, uint256 amount) external {
        address who = lenders[bound(actorSeed, 0, lenders.length - 1)];
        amount = bound(amount, 1e6, 250_000e6);
        vm.prank(who);
        try pool.deposit(amount, who) {
            ghostDeposits += 1;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address who = lenders[bound(actorSeed, 0, lenders.length - 1)];
        uint256 max = pool.maxWithdraw(who);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(who);
        try pool.withdraw(amount, who, who) {
            ghostWithdrawals += 1;
        } catch {}
    }

    function openLoan(uint256 actorSeed, uint256 amount, uint256 term) external {
        address who = borrowers[bound(actorSeed, 0, borrowers.length - 1)];
        uint256 headroom = manager.quote(who, 0, 0).maxDrawNow;
        if (headroom == 0) return;
        amount = bound(amount, 1, headroom);
        // Short terms on purpose: the fuzzer has to be able to reach maturity, grace expiry and a
        // write-off inside a single run.
        term = bound(term, manager.MIN_TERM_SECONDS(), 30 days);
        vm.prank(who);
        try manager.open(amount, term) returns (uint256 id) {
            loanIds.push(id);
            ghostOpens += 1;
        } catch {}
    }

    function repayLoan(uint256 loanSeed) external {
        if (loanIds.length == 0) return;
        uint256 id = loanIds[bound(loanSeed, 0, loanIds.length - 1)];
        CreditManager.Loan memory l = manager.loan(id);
        if (l.status != CreditManager.Status.Active) return;
        vm.prank(l.borrower);
        try manager.repay(id) {
            ghostRepays += 1;
        } catch {}
    }

    function writeOffLoan(uint256 loanSeed) external {
        if (loanIds.length == 0) return;
        uint256 id = loanIds[bound(loanSeed, 0, loanIds.length - 1)];
        try manager.markDefault(id) {
            ghostDefaults += 1;
        } catch {}
    }

    function advanceTime(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 45 days));
    }

    // ------------------------------------------------------------------ views

    function identitiesLength() external view returns (uint256) {
        return identities.length;
    }

    function loanIdsLength() external view returns (uint256) {
        return loanIds.length;
    }

    function lendersLength() external view returns (uint256) {
        return lenders.length;
    }

    // ------------------------------------------------------------------ setup

    function _addLender(string memory label, bytes32 kycHash) private {
        address who = makeAddr(label);
        lenders.push(who);
        _onboard(who, kycHash);
    }

    function _addBorrower(string memory label, bytes32 kycHash) private {
        address who = makeAddr(label);
        borrowers.push(who);
        _onboard(who, kycHash);
    }

    function _onboard(address who, bytes32 kycHash) private {
        // A very distant expiry, so time-travel in the fuzzer does not silently disable every actor.
        apass.issue(who, 1, 80, 50, block.timestamp + 3650 days, block.timestamp - 365 days, kycHash);
        asset.mint(who, 5_000_000e6);
        vm.startPrank(who);
        asset.approve(address(pool), type(uint256).max);
        asset.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }
}
