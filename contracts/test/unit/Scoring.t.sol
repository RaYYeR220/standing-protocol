// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";

/// @notice Fuzzed shape checks on the underwriting model.
/// @dev These are the properties a lender is being asked to believe: the model is monotone in the
///      things it claims to reward, monotone in the things it claims to punish, and can never offer
///      terms that are not under-collateralized.
contract ScoringTest is Test {
    uint256 internal constant NOW = 1_800_000_000;
    uint256 internal constant MAX_LINE = 50_000e6;

    function _cred(uint8 tier, uint8 subTier, uint64 issuedAt)
        internal
        pure
        returns (ApassReader.Credential memory c)
    {
        c.exists = true;
        c.status = ApassReader.STATUS_ACTIVE;
        c.tier = tier;
        c.subTier = subTier;
        c.issuedAt = issuedAt;
        c.expiresAt = type(uint64).max;
        c.kycHash = keccak256("identity");
    }

    function _hist(uint32 repaid, uint32 defaulted, uint128 totalRepaid)
        internal
        pure
        returns (StandingRegistry.History memory h)
    {
        h.loansOriginated = repaid;
        h.loansRepaid = repaid;
        h.loansDefaulted = defaulted;
        h.totalRepaid = totalRepaid;
    }

    // ------------------------------------------------------------------ monotonicity

    function testFuzz_Score_HigherTierNeverLowersTheScore(
        uint8 tierA,
        uint8 tierB,
        uint8 subTier,
        uint32 repaid,
        uint32 defaulted,
        uint96 balance
    ) public pure {
        tierA = uint8(bound(tierA, 0, 99));
        tierB = uint8(bound(tierB, 0, 99));
        subTier = uint8(bound(subTier, 0, 99));
        if (tierA > tierB) (tierA, tierB) = (tierB, tierA);

        StandingRegistry.History memory h = _hist(repaid, defaulted, 0);
        uint256 low = StandingMath.score(_cred(tierA, subTier, 0), h, balance, NOW).score;
        uint256 high = StandingMath.score(_cred(tierB, subTier, 0), h, balance, NOW).score;

        assertLe(low, high, "a better-verified identity must never score worse");
    }

    function testFuzz_Score_HigherSubTierNeverLowersTheScore(
        uint8 tier,
        uint8 subA,
        uint8 subB,
        uint96 balance
    ) public pure {
        tier = uint8(bound(tier, 0, 99));
        subA = uint8(bound(subA, 0, 99));
        subB = uint8(bound(subB, 0, 99));
        if (subA > subB) (subA, subB) = (subB, subA);

        StandingRegistry.History memory h = _hist(0, 0, 0);
        assertLe(
            StandingMath.score(_cred(tier, subA, 0), h, balance, NOW).score,
            StandingMath.score(_cred(tier, subB, 0), h, balance, NOW).score
        );
    }

    function testFuzz_Score_LongerTenureNeverLowersTheScore(uint8 tier, uint64 ageA, uint64 ageB)
        public
        pure
    {
        tier = uint8(bound(tier, 0, 99));
        ageA = uint64(bound(ageA, 0, NOW - 1));
        ageB = uint64(bound(ageB, 0, NOW - 1));
        if (ageA > ageB) (ageA, ageB) = (ageB, ageA);

        StandingRegistry.History memory h = _hist(0, 0, 0);
        uint256 younger = StandingMath.score(_cred(tier, 0, uint64(NOW - ageA)), h, 0, NOW).score;
        uint256 older = StandingMath.score(_cred(tier, 0, uint64(NOW - ageB)), h, 0, NOW).score;

        assertLe(younger, older, "an older credential must never score worse");
    }

    function testFuzz_Score_MoreRepaymentsNeverLowerTheScore(
        uint8 tier,
        uint32 repaidA,
        uint32 repaidB,
        uint32 defaulted,
        uint96 balance
    ) public pure {
        tier = uint8(bound(tier, 0, 99));
        if (repaidA > repaidB) (repaidA, repaidB) = (repaidB, repaidA);

        ApassReader.Credential memory c = _cred(tier, 0, 0);
        uint256 fewer = StandingMath.score(c, _hist(repaidA, defaulted, 0), balance, NOW).score;
        uint256 more = StandingMath.score(c, _hist(repaidB, defaulted, 0), balance, NOW).score;

        assertLe(fewer, more, "paying loans back must never hurt");
    }

    function testFuzz_Score_MoreRepaidVolumeNeverLowersTheScore(
        uint8 tier,
        uint128 volA,
        uint128 volB,
        uint32 defaulted
    ) public pure {
        tier = uint8(bound(tier, 0, 99));
        if (volA > volB) (volA, volB) = (volB, volA);

        ApassReader.Credential memory c = _cred(tier, 0, 0);
        assertLe(
            StandingMath.score(c, _hist(0, defaulted, volA), 0, NOW).score,
            StandingMath.score(c, _hist(0, defaulted, volB), 0, NOW).score
        );
    }

    function testFuzz_Score_LargerVerifiedBalanceNeverLowersTheScore(
        uint8 tier,
        uint96 balA,
        uint96 balB,
        uint32 repaid,
        uint32 defaulted
    ) public pure {
        tier = uint8(bound(tier, 0, 99));
        if (balA > balB) (balA, balB) = (balB, balA);

        ApassReader.Credential memory c = _cred(tier, 0, 0);
        StandingRegistry.History memory h = _hist(repaid, defaulted, 0);

        assertLe(
            StandingMath.score(c, h, balA, NOW).score,
            StandingMath.score(c, h, balB, NOW).score,
            "more verified capital must never hurt"
        );
    }

    function testFuzz_Score_ADefaultNeverRaisesTheScore(
        uint8 tier,
        uint8 subTier,
        uint32 repaid,
        uint32 defaulted,
        uint128 volume,
        uint96 balance
    ) public pure {
        tier = uint8(bound(tier, 0, 99));
        subTier = uint8(bound(subTier, 0, 99));
        defaulted = uint32(bound(defaulted, 0, type(uint32).max - 1));

        ApassReader.Credential memory c = _cred(tier, subTier, 0);
        uint256 before = StandingMath.score(c, _hist(repaid, defaulted, volume), balance, NOW).score;
        uint256 afterOneMore =
            StandingMath.score(c, _hist(repaid, defaulted + 1, volume), balance, NOW).score;

        assertLe(afterOneMore, before, "a write-off must never improve standing");
    }

    function testFuzz_Score_OneDefaultCostsAtLeastAsMuchAsTheHistoryItErases(
        uint8 tier,
        uint32 repaid,
        uint96 balance
    ) public pure {
        tier = uint8(bound(tier, 0, 99));
        repaid = uint32(bound(repaid, 0, 50));

        ApassReader.Credential memory c = _cred(tier, 0, 0);
        uint256 clean = StandingMath.score(c, _hist(repaid, 0, 0), balance, NOW).score;
        uint256 dirty = StandingMath.score(c, _hist(repaid, 1, 0), balance, NOW).score;

        // The penalty is applied to the whole score, so it is never diluted by the history cap.
        uint256 expectedDrop = clean < StandingMath.DEFAULT_PENALTY ? clean : StandingMath.DEFAULT_PENALTY;
        assertEq(clean - dirty, expectedDrop, "a default costs the full penalty");
    }

    // ------------------------------------------------------------------ bounds

    function testFuzz_Score_NeverExceedsTheMaximum(
        uint8 tier,
        uint8 subTier,
        uint32 repaid,
        uint128 volume,
        uint96 balance,
        uint64 issuedAt
    ) public pure {
        tier = uint8(bound(tier, 0, 99));
        subTier = uint8(bound(subTier, 0, 99));
        issuedAt = uint64(bound(issuedAt, 0, NOW));

        uint256 s =
            StandingMath.score(_cred(tier, subTier, issuedAt), _hist(repaid, 0, volume), balance, NOW).score;
        assertLe(s, StandingMath.MAX_SCORE, "score is bounded");
    }

    function testFuzz_Score_DeadCredentialAlwaysScoresZero(
        uint8 tier,
        uint8 status,
        uint32 repaid,
        uint96 balance
    ) public pure {
        tier = uint8(bound(tier, 0, 99));
        status = uint8(bound(status, 2, 255)); // anything other than ACTIVE

        ApassReader.Credential memory c = _cred(tier, 99, 0);
        c.status = status;
        assertEq(StandingMath.score(c, _hist(repaid, 0, 0), balance, NOW).score, 0, "frozen scores zero");

        ApassReader.Credential memory expired = _cred(tier, 99, 0);
        expired.expiresAt = uint64(NOW);
        assertEq(
            StandingMath.score(expired, _hist(repaid, 0, 0), balance, NOW).score, 0, "expired scores zero"
        );

        ApassReader.Credential memory missing;
        assertEq(
            StandingMath.score(missing, _hist(repaid, 0, 0), balance, NOW).score, 0, "absent scores zero"
        );
    }

    // ------------------------------------------------------------------ terms curve

    /// @dev The whole premise: every set of terms the contract will ever offer asks for less
    ///      collateral than the loan is worth.
    function testFuzz_Terms_EveryApprovedLoanIsUnderCollateralized(uint256 s) public pure {
        s = bound(s, 0, StandingMath.MAX_SCORE);
        StandingMath.Terms memory t = StandingMath.terms(s, MAX_LINE);
        if (!t.eligible) return;

        assertLe(t.collateralBps, StandingMath.MAX_COLLATERAL_BPS, "collateral capped at 80%");
        assertLt(t.collateralBps, 10_000, "collateral is always less than principal");
        assertLe(t.aprBps, StandingMath.MAX_APR_BPS, "rate ceiling");
        assertGe(t.aprBps, StandingMath.MIN_APR_BPS, "rate floor");
        assertLe(t.creditLine, MAX_LINE, "line ceiling");
        assertGt(t.creditLine, 0, "an eligible identity gets a line");
    }

    function testFuzz_Terms_BelowMinimumScoreThereAreNoTerms(uint256 s) public pure {
        s = bound(s, 0, StandingMath.MIN_SCORE - 1);
        StandingMath.Terms memory t = StandingMath.terms(s, MAX_LINE);
        assertFalse(t.eligible);
        assertEq(t.creditLine, 0);
    }

    function testFuzz_Terms_BetterScoreNeverGetsWorseTerms(uint256 sA, uint256 sB) public pure {
        sA = bound(sA, StandingMath.MIN_SCORE, StandingMath.MAX_SCORE);
        sB = bound(sB, StandingMath.MIN_SCORE, StandingMath.MAX_SCORE);
        if (sA > sB) (sA, sB) = (sB, sA);

        StandingMath.Terms memory low = StandingMath.terms(sA, MAX_LINE);
        StandingMath.Terms memory high = StandingMath.terms(sB, MAX_LINE);

        assertLe(low.creditLine, high.creditLine, "line rises with standing");
        assertGe(low.collateralBps, high.collateralBps, "collateral falls with standing");
        assertGe(low.aprBps, high.aprBps, "rate falls with standing");
    }

    function test_Terms_EndpointsAreExact() public pure {
        StandingMath.Terms memory floorTerms = StandingMath.terms(StandingMath.MIN_SCORE, MAX_LINE);
        assertEq(floorTerms.creditLine, MAX_LINE / 10);
        assertEq(floorTerms.collateralBps, 8000);
        assertEq(floorTerms.aprBps, 2500);

        StandingMath.Terms memory topTerms = StandingMath.terms(StandingMath.MAX_SCORE, MAX_LINE);
        assertEq(topTerms.creditLine, MAX_LINE);
        assertEq(topTerms.collateralBps, 0);
        assertEq(topTerms.aprBps, 500);
    }
}
