// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../helpers/Fixture.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";

/// @notice `syncIdentity` is permissionless, writes to the registry, and moves exposure between
///         keys. This file attacks that.
contract SyncIdentityTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant TERM = 30 days;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    function _credentialOf(address who) internal view returns (ApassReader.Credential memory) {
        return manager.credentialOf(who);
    }

    // ==================================================================== behaves as advertised

    function test_SyncIdentity_IsANoOpForAWalletWithNoPreviousHash() public {
        manager.syncIdentity(alice);
        assertEq(registry.supersedes(KYC_ALICE), bytes32(0), "nothing to link");
        assertEq(manager.resolveIdentity(_credentialOf(alice)), KYC_ALICE);
    }

    function test_SyncIdentity_IsANoOpForAWalletWithNoCredential() public {
        manager.syncIdentity(stranger);
        assertEq(manager.resolveIdentity(_credentialOf(stranger)), bytes32(0));
    }

    function test_SyncIdentity_IsIdempotent() public {
        apass.rotateKycHash(alice, keccak256("kyc:alice:v2"));

        manager.syncIdentity(alice);
        bytes32 first = registry.supersedes(keccak256("kyc:alice:v2"));
        manager.syncIdentity(alice);
        manager.syncIdentity(alice);

        assertEq(registry.supersedes(keccak256("kyc:alice:v2")), first, "stable");
        assertEq(first, KYC_ALICE);
    }

    function test_SyncIdentity_MigratesExposureOntoTheCanonicalIdentity() public {
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
        assertEq(manager.drawnByIdentity(KYC_ALICE), PRINCIPAL);

        // The borrower re-verifies. The new hash carries no exposure yet, so nothing moves.
        bytes32 v2 = keccak256("kyc:alice:v2");
        apass.rotateKycHash(alice, v2);
        manager.syncIdentity(alice);

        assertEq(registry.canonicalIdentity(v2), KYC_ALICE, "folded into the old identity");
        assertEq(manager.drawnByIdentity(KYC_ALICE), PRINCIPAL, "exposure stayed where the loan is");
        assertEq(manager.drawnByIdentity(v2), 0);
    }

    /// @dev Front-running a borrower's `open()` with a standalone `syncIdentity` must not change the
    ///      identity the loan ends up booked against.
    function test_SyncIdentity_FrontRunningAnOpenDoesNotChangeTheBookedIdentity() public {
        bytes32 v2 = keccak256("kyc:alice:v2");
        apass.rotateKycHash(alice, v2);

        bytes32 expected = manager.resolveIdentity(_credentialOf(alice));

        vm.prank(stranger);
        manager.syncIdentity(alice);

        assertEq(manager.resolveIdentity(_credentialOf(alice)), expected, "resolution unchanged");

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        assertEq(manager.loan(loanId).kycHash, expected, "booked against the same identity");
        assertEq(expected, KYC_ALICE);
    }

    /// @dev Whatever `resolveIdentity` says before a sync is what the registry ends up agreeing with
    ///      after one. If these could diverge, `open()` would book a loan against one identity while
    ///      the registry recorded it against another.
    function testFuzz_ResolveIdentityAgreesWithWhatSyncCommits(bytes32 kyc, bytes32 prev) public {
        vm.assume(kyc != bytes32(0));

        address w = makeAddr("fuzzWallet");
        apass.issue(w, 1, 50, 0, block.timestamp + ONE_YEAR, block.timestamp - ONE_YEAR, kyc);
        apass.setPreviousKycHash(w, prev);

        ApassReader.Credential memory c = _credentialOf(w);
        bytes32 before = manager.resolveIdentity(c);

        manager.syncIdentity(w);

        bytes32 afterSync = manager.resolveIdentity(c);
        assertEq(afterSync, before, "resolution is stable across the commit");
        assertEq(
            afterSync, registry.canonicalIdentity(c.kycHash), "and matches what the registry now holds"
        );
        assertEq(
            registry.canonicalIdentity(afterSync), afterSync, "the answer is always a canonical root"
        );
    }

    /// @dev Two wallets sharing a current hash must not migrate the same exposure twice.
    function test_SyncIdentity_DoesNotDoubleCountWhenTwoWalletsShareAKycHash() public {
        bytes32 shared = keccak256("kyc:shared");
        bytes32 older = keccak256("kyc:shared:previous");

        address w1 = makeAddr("shareW1");
        address w2 = makeAddr("shareW2");
        onboard(w1, 50, 0, shared, START_BALANCE);
        onboard(w2, 50, 0, shared, START_BALANCE);
        apass.setPreviousKycHash(w1, older);
        apass.setPreviousKycHash(w2, older);

        vm.prank(w1);
        manager.open(PRINCIPAL, TERM);
        uint256 total = manager.drawnByIdentity(older) + manager.drawnByIdentity(shared);
        assertEq(total, PRINCIPAL, "one draw, one exposure");

        manager.syncIdentity(w1);
        manager.syncIdentity(w2);
        manager.syncIdentity(w1);

        assertEq(
            manager.drawnByIdentity(older) + manager.drawnByIdentity(shared),
            PRINCIPAL,
            "exposure is never duplicated by repeated syncs"
        );
        assertEq(manager.drawnByIdentity(older), PRINCIPAL, "and lives on the canonical key");
        assertEq(manager.drawnByIdentity(shared), 0);
    }

    // ==================================================================== criticals, now closed

    /// @dev WAS: `syncIdentity` re-parented the aggregate while every loan kept the key captured at
    ///      `open()`, so `repay` and `markDefault` both underflowed against a key that was now zero
    ///      and the loan could neither be repaid nor written off. NOW: both settle against
    ///      `canonicalIdentity(l.kycHash)`, which follows the same union-find the migration followed.
    function test_Fixed_MigratedExposureStillLetsTheLoanBeRepaid() public {
        bytes32 shared = keccak256("kyc:twins:current");
        bytes32 older = keccak256("kyc:twins:previous");

        address w1 = makeAddr("twinNoPrevious");
        address w2 = makeAddr("twinWithPrevious");
        onboard(w1, 50, 0, shared, START_BALANCE);
        onboard(w2, 50, 0, shared, START_BALANCE);
        apass.setPreviousKycHash(w2, older);

        vm.prank(w1);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        assertEq(manager.loan(loanId).kycHash, shared, "booked against the current hash");
        assertEq(manager.drawnByIdentity(shared), PRINCIPAL);

        // Anybody, at any time, with no permission and no cost.
        vm.expectEmit(true, true, false, true, address(manager));
        emit CreditManager.ExposureMigrated(shared, older, PRINCIPAL);
        vm.prank(stranger);
        manager.syncIdentity(w2);

        assertEq(manager.drawnByIdentity(shared), 0, "exposure moved off the loan's key");
        assertEq(manager.drawnByIdentity(older), PRINCIPAL, "and onto the canonical one");

        // The loan settles anyway, because settlement follows the same union-find.
        vm.warp(block.timestamp + registry.MIN_QUALIFYING_HOLD());
        vm.prank(w1);
        manager.repay(loanId);

        assertEq(uint256(manager.loan(loanId).status), uint256(CreditManager.Status.Repaid));
        assertEq(manager.drawnByIdentity(older), 0, "exposure released from the canonical key");
        assertEq(manager.drawnByIdentity(shared), 0, "and nothing reappeared on the stale one");
        assertEq(pool.outstandingPrincipal(), 0, "the pool's book is clear");
        assertEq(asset.balanceOf(address(manager)), 0, "and the collateral came back");
    }

    /// @dev The same loan must also remain write-off-able after a migration.
    function test_Fixed_MigratedExposureStillLetsTheLoanBeWrittenOff() public {
        bytes32 shared = keccak256("kyc:twins3:current");
        bytes32 older = keccak256("kyc:twins3:previous");

        address w1 = makeAddr("twin3NoPrevious");
        address w2 = makeAddr("twin3WithPrevious");
        onboard(w1, 50, 0, shared, START_BALANCE);
        onboard(w2, 50, 0, shared, START_BALANCE);
        apass.setPreviousKycHash(w2, older);

        vm.prank(w1);
        uint256 loanId = manager.open(PRINCIPAL, TERM);

        vm.prank(stranger);
        manager.syncIdentity(w2);

        vm.warp(block.timestamp + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        assertEq(uint256(manager.loan(loanId).status), uint256(CreditManager.Status.Defaulted));
        assertEq(pool.outstandingPrincipal(), 0, "book cleared");
        assertEq(historyOf(older).loansDefaulted, 1, "recorded against the canonical identity");
        assertEq(registry.walletDefaults(w1), 1, "and against the wallet that drew it");
    }

    /// @dev Repeated migrations, chained: the exposure must keep following the loan's key however
    ///      many times the identity is re-parented before it settles.
    function test_Fixed_ExposureSurvivesRepeatedMigrationsBeforeSettlement() public {
        bytes32 gen2 = keccak256("kyc:chain:gen2");
        bytes32 gen1 = keccak256("kyc:chain:gen1");
        bytes32 gen0 = keccak256("kyc:chain:gen0");

        address borrowerWallet = makeAddr("chainBorrower");
        address sibling1 = makeAddr("chainSibling1");
        address sibling2 = makeAddr("chainSibling2");
        onboard(borrowerWallet, 50, 0, gen2, START_BALANCE);
        onboard(sibling1, 50, 0, gen2, START_BALANCE);
        onboard(sibling2, 50, 0, gen1, START_BALANCE);
        apass.setPreviousKycHash(sibling1, gen1);
        apass.setPreviousKycHash(sibling2, gen0);

        vm.prank(borrowerWallet);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        assertEq(manager.drawnByIdentity(gen2), PRINCIPAL);

        // gen2 -> gen1, then gen1 -> gen0. The exposure moves twice.
        manager.syncIdentity(sibling1);
        assertEq(manager.drawnByIdentity(gen1), PRINCIPAL, "first migration");
        manager.syncIdentity(sibling2);
        assertEq(manager.drawnByIdentity(gen0), PRINCIPAL, "second migration");
        assertEq(registry.canonicalIdentity(gen2), gen0, "two hops");

        vm.warp(block.timestamp + registry.MIN_QUALIFYING_HOLD());
        vm.prank(borrowerWallet);
        manager.repay(loanId);

        assertEq(manager.drawnByIdentity(gen0), 0, "settled against the far end of the chain");
        assertEq(pool.outstandingPrincipal(), 0);
    }

    /// @dev The ordinary path: the sibling wallet simply borrows, which migrates the key. The
    ///      first wallet's loan has to survive that.
    function test_Fixed_ASiblingWalletBorrowingDoesNotFreezeTheFirstLoan() public {
        bytes32 shared = keccak256("kyc:twins2:current");
        bytes32 older = keccak256("kyc:twins2:previous");

        address w1 = makeAddr("twin2NoPrevious");
        address w2 = makeAddr("twin2WithPrevious");
        onboard(w1, 50, 0, shared, START_BALANCE);
        onboard(w2, 50, 0, shared, START_BALANCE);
        apass.setPreviousKycHash(w2, older);

        vm.prank(w1);
        uint256 first = manager.open(PRINCIPAL, TERM);

        // No attacker: the second wallet of the same person draws against the same line.
        vm.prank(w2);
        uint256 second = manager.open(PRINCIPAL, TERM);
        assertEq(manager.drawnByIdentity(older), 2 * PRINCIPAL, "one shared exposure counter");

        vm.warp(block.timestamp + registry.MIN_QUALIFYING_HOLD());
        vm.prank(w1);
        manager.repay(first);
        vm.prank(w2);
        manager.repay(second);

        assertEq(manager.drawnByIdentity(older), 0, "both settled");
        assertEq(pool.outstandingPrincipal(), 0);
    }

    /// @dev WAS: the first `syncIdentity` to reach a hash decided which identity it folded into,
    ///      so a person holding a clean lineage alongside a defaulted one could commit the clean one
    ///      and shed the write-off. NOW: the wallet that drew the loan carries its own flag, so the
    ///      lineage choice buys that wallet nothing.
    function test_Fixed_LineagePickingIsDefeatedByTheWalletFlag() public {
        bytes32 defaultedLineage = keccak256("kyc:lineage:defaulted");
        bytes32 cleanLineage = keccak256("kyc:lineage:clean");
        bytes32 current = keccak256("kyc:lineage:current");

        address dirty = makeAddr("lineageDirty");
        onboard(dirty, 50, 0, defaultedLineage, START_BALANCE);

        vm.prank(dirty);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        vm.warp(block.timestamp + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);
        assertEq(historyOf(defaultedLineage).loansDefaulted, 1, "the write-off is real");

        // Both wallets re-verify into the same current hash, each naming its own prior lineage.
        apass.rotateKycHash(dirty, current);
        address clean = makeAddr("lineageClean");
        onboard(clean, 50, 0, current, START_BALANCE);
        apass.setPreviousKycHash(clean, cleanLineage);

        // Whoever commits first wins. The borrower commits the lineage without the write-off.
        manager.syncIdentity(clean);
        assertEq(registry.canonicalIdentity(current), cleanLineage, "folded into the clean lineage");

        // And the defaulted lineage can now never be attached.
        manager.syncIdentity(dirty);
        assertEq(registry.canonicalIdentity(current), cleanLineage, "still clean");

        // The identity side really has been shed...
        assertEq(historyOf(current).loansDefaulted, 0, "the identity record no longer shows it");
        // ...and the wallet side catches it anyway.
        assertEq(registry.walletDefaults(dirty), 1, "the wallet that drew it still carries the flag");

        CreditManager.Quote memory q = manager.quote(dirty, 1_000e6, TERM);
        assertEq(q.score, SCORE_TIER50 - StandingMath.DEFAULT_PENALTY, "penalty still applied");
        assertFalse(q.approved, "and the defaulter is still refused");

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BelowMinimumStanding.selector,
                SCORE_TIER50 - StandingMath.DEFAULT_PENALTY,
                StandingMath.MIN_SCORE
            )
        );
        vm.prank(dirty);
        manager.open(1_000e6, TERM);
    }

    // ==================================================================== residual

    /// @dev STILL OPEN, narrower. The wallet flag only follows the wallet that drew the loan. A
    ///      person who defaults on one wallet and borrows from a *second* wallet whose credential
    ///      names a different, clean prior lineage still escapes: neither the wallet flag nor the
    ///      identity record follows them.
    ///
    ///      It is a strictly smaller hole than before -- it costs a second wallet with its own
    ///      enrollment history, and it is closed for free by any observer calling `syncIdentity` on
    ///      the defaulted wallet first -- but it is not closed by the flag alone.
    function test_BUG_LineagePickingStillWorksFromAnUnflaggedSiblingWallet() public {
        bytes32 defaultedLineage = keccak256("kyc:lineage2:defaulted");
        bytes32 cleanLineage = keccak256("kyc:lineage2:clean");
        bytes32 current = keccak256("kyc:lineage2:current");

        address dirty = makeAddr("lineage2Dirty");
        onboard(dirty, 50, 0, defaultedLineage, START_BALANCE);

        vm.prank(dirty);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        vm.warp(block.timestamp + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        apass.rotateKycHash(dirty, current);
        address clean = makeAddr("lineage2Clean");
        onboard(clean, 50, 0, current, START_BALANCE);
        apass.setPreviousKycHash(clean, cleanLineage);

        // The clean lineage is committed first.
        manager.syncIdentity(clean);
        assertEq(registry.canonicalIdentity(current), cleanLineage);

        // The wallet that defaulted is still refused...
        assertFalse(manager.quote(dirty, 1_000e6, TERM).approved, "flagged wallet stays out");

        // ...but the sibling, which never drew anything, is not.
        assertEq(registry.walletDefaults(clean), 0, "no flag on this wallet");
        CreditManager.Quote memory q = manager.quote(clean, 1_000e6, TERM);
        assertEq(q.score, SCORE_TIER50, "and no penalty from the identity either");
        assertTrue(q.approved, "so the person borrows again on their other key");

        vm.prank(clean);
        manager.open(LINE_TIER50, TERM);
        assertEq(manager.drawnByIdentity(cleanLineage), LINE_TIER50, "a whole fresh line");
    }

    /// @dev And the mitigation, for the same scenario: commit the defaulted wallet's lineage first
    ///      and the sibling inherits the write-off like it should.
    function test_Mitigation_SyncingTheDefaultedWalletFirstClosesTheLineageHole() public {
        bytes32 defaultedLineage = keccak256("kyc:lineage3:defaulted");
        bytes32 cleanLineage = keccak256("kyc:lineage3:clean");
        bytes32 current = keccak256("kyc:lineage3:current");

        address dirty = makeAddr("lineage3Dirty");
        onboard(dirty, 50, 0, defaultedLineage, START_BALANCE);

        vm.prank(dirty);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        vm.warp(block.timestamp + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        apass.rotateKycHash(dirty, current);
        address clean = makeAddr("lineage3Clean");
        onboard(clean, 50, 0, current, START_BALANCE);
        apass.setPreviousKycHash(clean, cleanLineage);

        // Any observer, before the borrower gets there.
        vm.prank(stranger);
        manager.syncIdentity(dirty);
        assertEq(registry.canonicalIdentity(current), defaultedLineage, "anchored to the write-off");

        assertFalse(manager.quote(clean, 1_000e6, TERM).approved, "the sibling inherits it too");
    }
}
