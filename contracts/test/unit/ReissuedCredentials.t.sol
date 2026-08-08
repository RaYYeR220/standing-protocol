// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../helpers/Fixture.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";

/// @notice Re-verification, end to end through the credit manager.
/// @dev A defaulter re-doing KYC is the one escape route that would make the protocol unsound, so
///      this is where the identity plumbing has to hold. It holds for a single re-issue. It does not
///      hold for two — see the BUG_ tests.
contract ReissuedCredentialsTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant TERM = 30 days;

    bytes32 internal constant ALICE_V2 = keccak256("kyc:alice:v2");
    bytes32 internal constant ALICE_V3 = keccak256("kyc:alice:v3");

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    function _defaultAlice() internal returns (uint256 loanId) {
        vm.prank(alice);
        loanId = manager.open(PRINCIPAL, TERM);
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);
    }

    // ==================================================================== fixed

    function test_Fixed_SingleReissueDoesNotLaunderADefault() public {
        _defaultAlice();
        assertEq(historyOf(KYC_ALICE).loansDefaulted, 1);

        apass.rotateKycHash(alice, ALICE_V2);
        assertEq(manager.credentialOf(alice).previousKycHash, KYC_ALICE, "the link is on the credential");

        // The quote already resolves through the previous hash, so the UI does not lie either.
        CreditManager.Quote memory q = manager.quote(alice, 1_000e6, TERM);
        assertEq(q.score, SCORE_TIER50 - StandingMath.DEFAULT_PENALTY, "penalty still applies");
        assertFalse(q.approved, "still refused");

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BelowMinimumStanding.selector,
                SCORE_TIER50 - StandingMath.DEFAULT_PENALTY,
                StandingMath.MIN_SCORE
            )
        );
        vm.prank(alice);
        manager.open(1_000e6, TERM);
    }

    function test_Fixed_SingleReissueDoesNotResetTheCreditLine() public {
        vm.prank(alice);
        manager.open(LINE_TIER50, TERM);
        assertEq(manager.drawnByIdentity(KYC_ALICE), LINE_TIER50);

        apass.rotateKycHash(alice, ALICE_V2);

        CreditManager.Quote memory q = manager.quote(alice, 1e6, TERM);
        assertEq(q.alreadyDrawn, LINE_TIER50, "exposure follows the person across the re-issue");
        assertEq(q.maxDrawNow, 0, "no fresh line");

        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsCreditLine.selector, min, 0));
        vm.prank(alice);
        manager.open(min, TERM);
    }

    function test_Fixed_ReissueCarriesGoodStandingForwardToo() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, MAX_TERM);
        vm.warp(START_TS + 30 days);
        vm.prank(alice);
        manager.repay(loanId);
        assertEq(historyOf(KYC_ALICE).loansRepaid, 1);

        apass.rotateKycHash(alice, ALICE_V2);

        // Opening under the new hash persists the link and keeps the earned history.
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);

        assertEq(registry.supersedes(ALICE_V2), KYC_ALICE, "link persisted");
        assertEq(registry.canonicalIdentity(ALICE_V2), KYC_ALICE);
        assertEq(historyOf(ALICE_V2).loansRepaid, 1, "history carried forward");
        assertEq(historyOf(ALICE_V2).loansOriginated, 2, "and kept accruing");
    }

    /// @dev With the link persisted, a *second* re-issue chains correctly and stays anchored.
    function test_Fixed_ChainedReissuesStayAnchoredWhenEachHopIsPersisted() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, MAX_TERM);
        vm.warp(START_TS + 30 days);
        vm.prank(alice);
        manager.repay(loanId);

        apass.rotateKycHash(alice, ALICE_V2);
        vm.prank(alice);
        uint256 second = manager.open(PRINCIPAL, MAX_TERM);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        manager.repay(second);

        apass.rotateKycHash(alice, ALICE_V3);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);

        assertEq(registry.supersedes(ALICE_V3), KYC_ALICE, "compressed straight to the root");
        assertEq(historyOf(ALICE_V3).loansRepaid, 2, "two re-issues, one record");
    }

    // ==================================================================== not fixed

    /// @dev WAS: two re-verifications shed a default completely, because a credential carries only
    ///      one previous hash and the intermediate link was never committed. NOW: the wallet that
    ///      drew the loan carries its own write-off flag, and no amount of credential churn moves it.
    ///      The identity chain is still broken by the second re-issue — the assertions below show
    ///      that explicitly — but the borrower is refused anyway.
    function test_Fixed_SameWalletCannotLaunderADefaultByReissuingTwice() public {
        _defaultAlice();
        assertEq(historyOf(KYC_ALICE).loansDefaulted, 1, "the write-off is real");

        // First re-issue. The borrower tries to draw and is correctly refused...
        apass.rotateKycHash(alice, ALICE_V2);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BelowMinimumStanding.selector,
                SCORE_TIER50 - StandingMath.DEFAULT_PENALTY,
                StandingMath.MIN_SCORE
            )
        );
        vm.prank(alice);
        manager.open(1_000e6, TERM);

        // ...and the link that refusal established is rolled back with it.
        assertEq(registry.supersedes(ALICE_V2), bytes32(0), "the link did not survive the revert");

        // Second re-issue. Its `previousKycHash` points at the orphan, which has no history.
        apass.rotateKycHash(alice, ALICE_V3);

        // The identity side really is laundered: resolution stops at an orphan that has no record.
        assertEq(
            manager.resolveIdentity(manager.credentialOf(alice)),
            ALICE_V2,
            "resolves to the uncommitted intermediate hash"
        );
        assertEq(historyOf(ALICE_V2).loansDefaulted, 0, "which carries no write-off");
        assertEq(historyOf(KYC_ALICE).loansDefaulted, 1, "while it still sits on the old identity");

        // And the wallet flag catches it regardless.
        assertEq(registry.walletDefaults(alice), 1, "the wallet that drew it is still marked");

        CreditManager.Quote memory q = manager.quote(alice, 1_000e6, TERM);
        assertEq(q.score, SCORE_TIER50 - StandingMath.DEFAULT_PENALTY, "penalty applied anyway");
        assertFalse(q.approved, "the defaulter stays refused");

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BelowMinimumStanding.selector,
                SCORE_TIER50 - StandingMath.DEFAULT_PENALTY,
                StandingMath.MIN_SCORE
            )
        );
        vm.prank(alice);
        manager.open(1_000e6, TERM);
    }

    /// @dev STILL OPEN. The wallet flag follows the wallet, and the identity chain is still severed
    ///      by a second re-issue, so a defaulter who moves to a fresh key launders the write-off:
    ///      neither record follows them. This is the case that still needs the keeper.
    function test_BUG_Default_StillLaunderedByTwoReissuesOntoAFreshWallet() public {
        _defaultAlice();
        assertEq(registry.walletDefaults(alice), 1);

        // First re-issue: refused, so the link is rolled back and never committed.
        apass.rotateKycHash(alice, ALICE_V2);
        vm.expectRevert();
        vm.prank(alice);
        manager.open(1_000e6, TERM);
        assertEq(registry.supersedes(ALICE_V2), bytes32(0), "link lost with the revert");

        // Second re-issue, and the person moves to a key the protocol has never seen.
        apass.rotateKycHash(alice, ALICE_V3);
        address freshWallet = makeAddr("aliceFreshKey");
        onboard(freshWallet, 50, 0, ALICE_V3, START_BALANCE);
        apass.setPreviousKycHash(freshWallet, ALICE_V2);

        assertEq(registry.walletDefaults(freshWallet), 0, "no wallet flag on a new key");
        CreditManager.Quote memory q = manager.quote(freshWallet, 1_000e6, TERM);
        assertEq(q.score, SCORE_TIER50, "and no identity penalty either");
        assertTrue(q.approved, "so the write-off is shed after all");

        vm.prank(freshWallet);
        manager.open(1_000e6, TERM);
    }

    /// @dev STILL OPEN. The same severed chain, used against the exposure cap instead of the
    ///      score. The wallet flag does not help here: it records write-offs, not drawn principal,
    ///      and this borrower has defaulted on nothing. One person, two full lines, simultaneously.
    function test_BUG_CreditLine_DoubledByTwoConsecutiveReissues() public {
        vm.prank(alice);
        manager.open(LINE_TIER50, TERM);
        assertEq(manager.drawnByIdentity(KYC_ALICE), LINE_TIER50);

        // First re-issue: refused because the line is already drawn, so the link is rolled back.
        apass.rotateKycHash(alice, ALICE_V2);
        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsCreditLine.selector, min, 0));
        vm.prank(alice);
        manager.open(min, TERM);
        assertEq(registry.supersedes(ALICE_V2), bytes32(0), "link lost");

        // Second re-issue: attaches to the orphan, which has drawn nothing.
        apass.rotateKycHash(alice, ALICE_V3);
        assertEq(manager.quote(alice, 1e6, TERM).maxDrawNow, LINE_TIER50, "a whole second line");

        vm.prank(alice);
        manager.open(LINE_TIER50, TERM);

        assertEq(manager.drawnByIdentity(KYC_ALICE), LINE_TIER50);
        assertEq(manager.drawnByIdentity(ALICE_V2), LINE_TIER50);
        assertEq(pool.outstandingPrincipal(), 2 * LINE_TIER50, "double the intended exposure");
    }

    /// @dev A single `syncIdentity` call while the intermediate credential is live closes the hole
    ///      above completely. It is permissionless, idempotent and costs one transaction, so this is
    ///      a keeper job rather than an unfixable flaw — but nothing in the protocol performs it, and
    ///      the party with the incentive to skip it is the defaulter.
    function test_Mitigation_OneSyncDuringTheWindowDefeatsTheTwoReissueLaundering() public {
        _defaultAlice();

        apass.rotateKycHash(alice, ALICE_V2);

        // Anyone at all, watching credential rotations, commits the link.
        vm.prank(stranger);
        manager.syncIdentity(alice);
        assertEq(registry.supersedes(ALICE_V2), KYC_ALICE, "committed");

        // The second re-issue now resolves all the way back to the write-off -- and the check is
        // made from a FRESH wallet, so it is the identity chain doing the work, not the wallet flag.
        apass.rotateKycHash(alice, ALICE_V3);
        address freshWallet = makeAddr("aliceFreshKeyMitigated");
        onboard(freshWallet, 50, 0, ALICE_V3, START_BALANCE);
        apass.setPreviousKycHash(freshWallet, ALICE_V2);

        assertEq(registry.walletDefaults(freshWallet), 0, "unflagged wallet");
        CreditManager.Quote memory q = manager.quote(freshWallet, 1_000e6, TERM);
        assertEq(q.score, SCORE_TIER50 - StandingMath.DEFAULT_PENALTY, "penalty survives both hops");
        assertFalse(q.approved, "and the defaulter stays refused");

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BelowMinimumStanding.selector,
                SCORE_TIER50 - StandingMath.DEFAULT_PENALTY,
                StandingMath.MIN_SCORE
            )
        );
        vm.prank(freshWallet);
        manager.open(1_000e6, TERM);
    }

    /// @dev Any revert in `open()` after the sync drops it, not just a refusal on standing. Here the
    ///      borrower simply has not approved enough collateral. Harmless on its own now that
    ///      `syncIdentity` is callable standalone, but it is why `open()` cannot be relied on to
    ///      commit the link.
    function test_Link_IsStillLostWheneverOpenRevertsForAnyReason() public {
        apass.rotateKycHash(alice, ALICE_V2);

        vm.prank(alice);
        asset.approve(address(manager), 0);

        vm.expectRevert();
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);

        assertEq(registry.supersedes(ALICE_V2), bytes32(0), "no link recorded");
    }

    // ==================================================================== poisoning

    /// @dev A credential's `previousKycHash` is set by Cleanverse, and the protocol trusts it
    ///      completely: whatever it names, `open()` folds the caller into that identity. If an
    ///      attacker ever obtains a credential whose previous hash is a stranger's, the two records
    ///      become one — the attacker inherits the stranger's standing, and the stranger inherits
    ///      the attacker's write-offs.
    function test_BUG_ReissuePointingAtAStrangerMergesTwoUnrelatedIdentities() public {
        // A well-behaved borrower builds a record.
        vm.prank(lp2);
        uint256 loanId = manager.open(PRINCIPAL, MAX_TERM);
        vm.warp(START_TS + 30 days);
        vm.prank(lp2);
        manager.repay(loanId);

        uint256 victimScoreBefore = manager.quote(lp2, 1e6, TERM).score;
        uint256 victimLineBefore = manager.quote(lp2, 1e6, TERM).creditLine;
        assertEq(historyOf(KYC_LP2).loansRepaid, 1);

        // The attacker's credential claims to supersede the victim's identity.
        address mallory = makeAddr("mallory");
        onboard(mallory, 50, 0, keccak256("kyc:mallory"), START_BALANCE);
        apass.setPreviousKycHash(mallory, KYC_LP2);

        // Drawing folds the attacker into the victim's record and inherits their standing.
        assertEq(manager.quote(mallory, 1e6, TERM).score, victimScoreBefore, "inherits the good record");
        vm.prank(mallory);
        uint256 stolen = manager.open(PRINCIPAL, TERM);
        assertEq(registry.canonicalIdentity(keccak256("kyc:mallory")), KYC_LP2, "identities merged");

        // The attacker is now spending the victim's credit line...
        assertEq(manager.quote(lp2, 1e6, TERM).alreadyDrawn, PRINCIPAL, "victim's headroom consumed");

        // ...and the write-off lands on the victim.
        vm.warp(block.timestamp + TERM + manager.GRACE_PERIOD());
        manager.markDefault(stolen);

        assertEq(historyOf(KYC_LP2).loansDefaulted, 1, "the victim now carries a default");
        assertLt(manager.quote(lp2, 1e6, TERM).score, victimScoreBefore, "victim's standing damaged");
        assertLt(manager.quote(lp2, 1e6, TERM).creditLine, victimLineBefore, "victim's line cut");

        address[] memory wallets = registry.walletsOf(KYC_LP2);
        assertEq(wallets.length, 2, "the victim's record now names the attacker's wallet");
    }

    /// @dev The depth of the supersession chain is attacker-controllable: using a newer-generation
    ///      credential before an older one skips the path compression that keeps forward-built chains
    ///      one hop deep. This is what makes the registry's 8-hop resolution bound reachable in
    ///      principle -- see IdentityLinking.t.sol for what happens past it.
    function test_ChainDepthIsControlledByTheOrderWalletsDraw() public {
        bytes32 gen0 = keccak256("kyc:gen0");
        bytes32 gen1 = keccak256("kyc:gen1");
        bytes32 gen2 = keccak256("kyc:gen2");

        address newer = makeAddr("newerWallet");
        address older = makeAddr("olderWallet");
        onboard(newer, 50, 0, gen2, START_BALANCE);
        onboard(older, 50, 0, gen1, START_BALANCE);
        apass.setPreviousKycHash(newer, gen1);
        apass.setPreviousKycHash(older, gen0);

        // Newest generation draws first: gen2 -> gen1, and gen1 is still a root.
        vm.prank(newer);
        manager.open(1_000e6, TERM);
        assertEq(registry.supersedes(gen2), gen1, "one hop");

        // The older generation then draws, pushing a second level underneath it.
        vm.prank(older);
        manager.open(1_000e6, TERM);
        assertEq(registry.supersedes(gen1), gen0, "two levels");
        assertEq(registry.canonicalIdentity(gen2), gen0, "resolution still reaches the root at depth 2");
    }
}
