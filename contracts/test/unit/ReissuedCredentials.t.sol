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

    /// @dev BUG (critical). `linkIdentity` is only ever called from inside `open()`, and `open()`
    ///      reverts whenever the borrower is refused — which is exactly what happens to a defaulter.
    ///      The link is rolled back with the rest of the transaction, so the intermediate hash is
    ///      never recorded as superseding anything. The next re-issue then attaches to that orphan
    ///      instead of to the identity that owns the write-off.
    ///
    ///      Two re-verifications launder a default completely.
    function test_BUG_Default_LaunderedByTwoConsecutiveReissues() public {
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

        CreditManager.Quote memory q = manager.quote(alice, 1_000e6, TERM);
        assertEq(q.score, SCORE_TIER50, "clean slate");
        assertTrue(q.approved, "the defaulter is approved again");

        vm.prank(alice);
        uint256 fresh = manager.open(1_000e6, TERM);
        assertEq(manager.loan(fresh).principal, 1_000e6, "and draws");

        assertEq(registry.canonicalIdentity(ALICE_V3), ALICE_V2, "anchored to the orphan");
        assertEq(historyOf(ALICE_V3).loansDefaulted, 0, "write-off invisible");
        assertEq(historyOf(KYC_ALICE).loansDefaulted, 1, "while it still sits on the old identity");
    }

    /// @dev The same rollback, used against the exposure cap instead of the score: one person ends
    ///      up holding two full credit lines at once.
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

    /// @dev Any revert in `open()` after the link is written drops it, not just a refusal on
    ///      standing. Here the borrower simply has not approved enough collateral.
    function test_BUG_Link_IsLostWheneverOpenRevertsForAnyReason() public {
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

    /// @dev BUG (high). `linkIdentity` re-parents a KYC hash inside the registry, but nothing
    ///      re-parents `drawnByIdentity`, which lives in the credit manager. Any link created AFTER a
    ///      hash has already borrowed strands that debt under a key the protocol never consults
    ///      again — and the identity gets a whole fresh line.
    ///
    ///      No revert trick and no backfill is needed: two wallets of the same person can legitimately
    ///      hold the same current `kycHash` with different `previousKycHash` values, because the
    ///      previous hash is a property of the wallet's own credential history. Whichever wallet
    ///      draws first decides which key the debt lands on.
    function test_BUG_Exposure_StrandedWhenAHashIsLinkedAfterItHasAlreadyBorrowed() public {
        bytes32 shared = keccak256("kyc:twins:current");
        bytes32 older = keccak256("kyc:twins:previous");

        address w1 = makeAddr("twinNoPrevious");
        address w2 = makeAddr("twinWithPrevious");
        onboard(w1, 50, 0, shared, START_BALANCE);
        onboard(w2, 50, 0, shared, START_BALANCE);
        apass.setPreviousKycHash(w2, older);

        // The wallet whose credential carries no previous hash draws the whole line.
        vm.prank(w1);
        manager.open(LINE_TIER50, TERM);
        assertEq(manager.drawnByIdentity(shared), LINE_TIER50);
        assertEq(manager.quote(w1, 1e6, TERM).maxDrawNow, 0, "correctly maxed out");

        // The sibling wallet re-parents the identity onto a hash that has never borrowed anything.
        assertEq(manager.quote(w2, 1e6, TERM).maxDrawNow, LINE_TIER50, "line reset by the link");
        vm.prank(w2);
        manager.open(LINE_TIER50, TERM);

        assertEq(registry.canonicalIdentity(shared), older, "re-parented");
        assertEq(manager.drawnByIdentity(shared), LINE_TIER50, "the first draw is stranded here");
        assertEq(manager.drawnByIdentity(older), LINE_TIER50, "and a fresh line was drawn here");
        assertEq(pool.outstandingPrincipal(), 2 * LINE_TIER50, "one person, twice the cap");

        // The registry's own history did merge -- it is only the exposure counter that is stranded.
        assertEq(historyOf(older).loansOriginated, 2, "history followed the link");
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
