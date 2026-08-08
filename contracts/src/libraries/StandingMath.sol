// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ApassReader} from "./ApassReader.sol";
import {StandingRegistry} from "../StandingRegistry.sol";

/// @title StandingMath
/// @notice Turns a verified identity plus its credit history into a score and loan terms.
///
/// @dev Pure and deterministic on purpose. Underwriting a loan nobody has collateralized is exactly
///      the place where a model would be asked to "use judgement", and exactly the place where that
///      judgement cannot be allowed to move money. Every input here is on-chain state — the A-Pass
///      credential, this protocol's own repayment record, and the borrower's verified asset balance
///      — and the arithmetic is fixed. Two callers on the same block get the same number.
///
///      The protocol does run a language model over the same inputs, but only to write the
///      explanation a lender reads. It has no path to the number, and the number is what the
///      contract enforces.
library StandingMath {
    uint256 internal constant MAX_SCORE = 1000;

    /// @notice Below this, no amount of collateral buys a loan. Identity is the entry ticket.
    uint256 internal constant MIN_SCORE = 400;

    /// @dev Component ceilings. They sum to MAX_SCORE.
    uint256 internal constant IDENTITY_MAX = 400;
    uint256 internal constant HISTORY_MAX = 350;
    uint256 internal constant ASSETS_MAX = 250;

    /// @dev Identity sub-weights.
    uint256 internal constant TIER_MAX = 300;
    uint256 internal constant SUBTIER_MAX = 50;
    uint256 internal constant TENURE_MAX = 50;
    uint256 internal constant TENURE_FULL_CREDIT = 365 days;

    /// @dev History sub-weights.
    uint256 internal constant REPAID_POINTS = 25;
    uint256 internal constant REPAID_CAP = 10;
    uint256 internal constant VOLUME_POINTS = 10;
    uint256 internal constant VOLUME_CAP = 10;
    uint256 internal constant DEFAULT_PENALTY = 250;

    /// @dev Asset sub-weights. Denominated in the verified asset's smallest unit (aUSDC has 6dp).
    uint256 internal constant ASSET_UNIT = 1e6;
    uint256 internal constant ASSET_POINTS = 25;
    uint256 internal constant ASSET_CAP = 10;

    /// @dev Term curve bounds. Collateral required falls to zero as standing rises; even the
    ///      weakest accepted borrower posts less than the loan is worth, so every approved loan is
    ///      under-collateralized by construction.
    uint256 internal constant MAX_COLLATERAL_BPS = 8000;
    uint256 internal constant MIN_APR_BPS = 500;
    uint256 internal constant MAX_APR_BPS = 2500;

    /// @notice Every term of the score, kept so the console can show a lender the actual inputs.
    struct Breakdown {
        uint256 tierPoints;
        uint256 subTierPoints;
        uint256 tenurePoints;
        uint256 repaymentPoints;
        uint256 volumePoints;
        uint256 defaultPenalty;
        uint256 assetPoints;
        uint256 identitySubtotal;
        uint256 historySubtotal;
        uint256 assetSubtotal;
        uint256 score;
    }

    /// @notice The terms the contract is willing to offer at a given score.
    /// @param eligible False when the score is below MIN_SCORE; the other fields are then meaningless.
    /// @param creditLine Maximum total principal this identity may owe at once, in asset units.
    /// @param collateralBps Collateral required as a fraction of principal, in basis points.
    /// @param aprBps Interest rate in basis points per year.
    struct Terms {
        bool eligible;
        uint256 creditLine;
        uint256 collateralBps;
        uint256 aprBps;
    }

    /// @notice Scores an identity from its credential, its history and its verified holdings.
    /// @param c The A-Pass credential, already read from the registry.
    /// @param h This protocol's record for the identity behind that credential.
    /// @param verifiedBalance The borrower's balance of the verified asset.
    /// @param nowTs Current block timestamp.
    function score(
        ApassReader.Credential memory c,
        StandingRegistry.History memory h,
        uint256 verifiedBalance,
        uint256 nowTs
    ) internal pure returns (Breakdown memory b) {
        // A credential that is missing, frozen or expired scores zero. There is no partial credit
        // for identity: it is the collateral, and absent collateral is not a discount.
        if (!ApassReader.isLive(c, nowTs)) return b;

        // Identity — what the issuing bank vouched for.
        b.tierPoints = (uint256(c.tier) * TIER_MAX) / 99;
        b.subTierPoints = (uint256(c.subTier) * SUBTIER_MAX) / 99;
        uint256 age = nowTs > c.issuedAt ? nowTs - c.issuedAt : 0;
        if (age > TENURE_FULL_CREDIT) age = TENURE_FULL_CREDIT;
        b.tenurePoints = (age * TENURE_MAX) / TENURE_FULL_CREDIT;
        b.identitySubtotal = _cap(b.tierPoints + b.subTierPoints + b.tenurePoints, IDENTITY_MAX);

        // History — what this identity has actually done with borrowed money.
        uint256 repaid = h.loansRepaid > REPAID_CAP ? REPAID_CAP : h.loansRepaid;
        b.repaymentPoints = repaid * REPAID_POINTS;
        uint256 volumeUnits = h.totalRepaid / (1000 * ASSET_UNIT);
        if (volumeUnits > VOLUME_CAP) volumeUnits = VOLUME_CAP;
        b.volumePoints = volumeUnits * VOLUME_POINTS;
        b.defaultPenalty = uint256(h.loansDefaulted) * DEFAULT_PENALTY;
        uint256 historyGross = _cap(b.repaymentPoints + b.volumePoints, HISTORY_MAX);
        b.historySubtotal = historyGross > b.defaultPenalty ? historyGross - b.defaultPenalty : 0;

        // Assets — verified, compliantly-originated holdings. Unverified wealth counts for nothing
        // here, which is the point: the balance is evidence only because of where it came from.
        uint256 assetUnits = verifiedBalance / ASSET_UNIT;
        if (assetUnits > ASSET_CAP) assetUnits = ASSET_CAP;
        b.assetPoints = assetUnits * ASSET_POINTS;
        b.assetSubtotal = _cap(b.assetPoints, ASSETS_MAX);

        uint256 gross = b.identitySubtotal + b.historySubtotal + b.assetSubtotal;

        // A default outruns the component caps: it is subtracted from the whole score, not just
        // from the history bucket, so one write-off cannot be papered over with a large balance.
        uint256 wholeScorePenalty = b.defaultPenalty > historyGross ? b.defaultPenalty - historyGross : 0;
        b.score = gross > wholeScorePenalty ? _cap(gross - wholeScorePenalty, MAX_SCORE) : 0;
    }

    /// @notice Maps a score onto the terms the contract will enforce.
    /// @param s The score, 0-1000.
    /// @param maxCreditLine The protocol-wide ceiling on a single identity's exposure.
    function terms(uint256 s, uint256 maxCreditLine) internal pure returns (Terms memory t) {
        if (s < MIN_SCORE) return t;

        t.eligible = true;

        uint256 span = MAX_SCORE - MIN_SCORE; // 600
        uint256 above = s - MIN_SCORE;

        // Credit line scales from a tenth of the ceiling at the threshold up to the full ceiling.
        t.creditLine = (maxCreditLine / 10) + ((maxCreditLine * 9 / 10) * above) / span;

        // Collateral falls from 80% of principal to nothing.
        t.collateralBps = MAX_COLLATERAL_BPS - ((MAX_COLLATERAL_BPS * above) / span);

        // Rate falls from 25% to 5%.
        t.aprBps = MAX_APR_BPS - (((MAX_APR_BPS - MIN_APR_BPS) * above) / span);
    }

    function _cap(uint256 v, uint256 max) private pure returns (uint256) {
        return v > max ? max : v;
    }
}
