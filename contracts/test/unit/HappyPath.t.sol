// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../helpers/Fixture.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";

contract HappyPathTest is Fixture {
    uint256 internal constant DEPOSIT = 50_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant TERM = 180 days;

    /// @dev 5_000e6 * 7320 / 10_000
    uint256 internal constant COLLATERAL = 3_660e6;
    /// @dev 5_000e6 * 2330 * 180 days / (10_000 * 365 days), computed independently.
    uint256 internal constant INTEREST = 574_520_547;

    function test_Quote_MatchesTheTermsTheContractWillActuallyEnforce() public {
        seedPool(DEPOSIT);

        CreditManager.Quote memory q = manager.quote(alice, PRINCIPAL, TERM);

        assertTrue(q.approved, "quote should approve");
        assertEq(q.score, SCORE_TIER50, "score");
        assertEq(q.creditLine, LINE_TIER50, "credit line");
        assertEq(q.aprBps, APR_BPS_TIER50, "apr");
        assertEq(q.alreadyDrawn, 0, "nothing drawn yet");
        assertEq(q.maxDrawNow, LINE_TIER50, "headroom");
        assertEq(q.collateralRequired, COLLATERAL, "collateral");
        assertEq(q.interestForTerm, INTEREST, "interest");
        assertEq(q.breakdown.identitySubtotal, 201, "identity subtotal");
        assertEq(q.breakdown.assetSubtotal, 250, "asset subtotal");
        assertEq(q.breakdown.historySubtotal, 0, "history subtotal");
    }

    function test_LpDeposit_MintsSharesAtParIntoAnEmptyPool() public {
        vm.prank(lp);
        uint256 shares = pool.deposit(DEPOSIT, lp);

        // Six decimals of virtual offset: shares are denominated 1e6 finer than the asset.
        assertEq(pool.decimals(), 12, "share decimals");
        assertEq(shares, DEPOSIT * SHARE_UNIT, "first deposit is at par");
        assertEq(pool.totalAssets(), DEPOSIT, "total assets");
        assertEq(pool.availableLiquidity(), DEPOSIT, "liquidity");
        assertEq(pool.utilizationBps(), 0, "utilization");
        assertEq(sharePrice(), 1e6, "share price starts at par");
    }

    function test_Borrow_IsUnderCollateralized() public {
        seedPool(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);

        CreditManager.Loan memory l = manager.loan(loanId);

        assertLt(l.collateral, l.principal, "collateral must be less than principal");
        assertEq(l.collateral, COLLATERAL, "collateral amount");
        assertEq(l.principal, PRINCIPAL, "principal amount");
        assertEq(uint256(l.aprBps), APR_BPS_TIER50, "apr");
        assertEq(l.interestDue, INTEREST, "interest booked at open");
        assertEq(l.openedAt, START_TS, "opened at");
        assertEq(l.dueAt, START_TS + TERM, "maturity");
        assertEq(uint256(l.status), uint256(CreditManager.Status.Active), "active");
        assertEq(l.kycHash, KYC_ALICE, "identity anchor");

        // 73.2% collateral against 100% principal: the borrower is net long ~26.8% of the loan.
        assertEq(l.collateral * 10_000 / l.principal, COLLAT_BPS_TIER50, "collateral bps");
    }

    function test_Borrow_MovesTheRightMoneyAndBooksTheRightState() public {
        seedPool(DEPOSIT);
        uint256 aliceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);

        assertEq(asset.balanceOf(alice), aliceBefore - COLLATERAL + PRINCIPAL, "borrower net position");
        assertEq(asset.balanceOf(address(manager)), COLLATERAL, "collateral custodied by manager");
        assertEq(asset.balanceOf(address(pool)), DEPOSIT - PRINCIPAL, "pool liquidity down by principal");

        assertEq(pool.outstandingPrincipal(), PRINCIPAL, "outstanding");
        assertEq(pool.totalAssets(), DEPOSIT, "lending does not change total assets");
        assertEq(pool.utilizationBps(), PRINCIPAL * 10_000 / DEPOSIT, "utilization");
        assertEq(manager.drawnByIdentity(KYC_ALICE), PRINCIPAL, "drawn per identity");

        StandingRegistry.History memory h = historyOf(KYC_ALICE);
        assertEq(h.loansOriginated, 1, "originated");
        assertEq(h.totalBorrowed, PRINCIPAL, "total borrowed");
        assertEq(h.firstSeenAt, START_TS, "first seen");

        address[] memory wallets = registry.walletsOf(KYC_ALICE);
        assertEq(wallets.length, 1, "one wallet linked");
        assertEq(wallets[0], alice, "wallet linked to identity");
    }

    function test_Repay_ReturnsCollateralInFullAndRaisesSharePriceByExactlyTheInterest() public {
        seedPool(DEPOSIT);
        uint256 aliceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);

        vm.warp(START_TS + TERM);

        uint256 assetsBefore = pool.totalAssets();
        uint256 priceBefore = sharePrice();
        uint256 supplyBefore = pool.totalSupply();

        vm.expectEmit(true, true, false, true, address(manager));
        emit CreditManager.LoanRepaid(loanId, alice, PRINCIPAL, INTEREST);
        vm.prank(alice);
        manager.repay(loanId);

        // Collateral back in full, and the only thing the borrower is out of pocket is interest.
        assertEq(asset.balanceOf(alice), aliceBefore - INTEREST, "borrower paid exactly the interest");
        assertEq(asset.balanceOf(address(manager)), 0, "no collateral retained");

        // Share price rises by exactly the interest, no more and no less.
        assertEq(pool.totalAssets(), assetsBefore + INTEREST, "total assets += interest");
        assertEq(pool.totalSupply(), supplyBefore, "no shares minted or burned");
        assertGt(sharePrice(), priceBefore, "share price rose");
        assertApproxEqAbs(pool.previewRedeem(supplyBefore), DEPOSIT + INTEREST, 1, "LP claim");

        assertEq(pool.outstandingPrincipal(), 0, "nothing outstanding");
        assertEq(pool.lifetimeInterest(), INTEREST, "lifetime interest");
        assertEq(pool.lifetimeLosses(), 0, "no losses");
        assertEq(manager.drawnByIdentity(KYC_ALICE), 0, "identity line freed");

        CreditManager.Loan memory l = manager.loan(loanId);
        assertEq(uint256(l.status), uint256(CreditManager.Status.Repaid), "repaid");
    }

    function test_Repay_UpdatesRegistryHistoryAgainstTheIdentity() public {
        seedPool(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        vm.warp(START_TS + TERM);

        vm.expectEmit(true, true, false, true, address(registry));
        emit StandingRegistry.LoanRepaid(KYC_ALICE, alice, PRINCIPAL, INTEREST, true);
        vm.prank(alice);
        manager.repay(loanId);

        StandingRegistry.History memory h = historyOf(KYC_ALICE);
        assertEq(h.loansOriginated, 1, "originated");
        assertEq(h.loansRepaid, 1, "repaid");
        assertEq(h.loansDefaulted, 0, "no defaults");
        assertEq(h.totalBorrowed, PRINCIPAL, "total borrowed");
        assertEq(h.totalRepaid, PRINCIPAL + INTEREST, "total repaid");
        assertEq(h.lastActivityAt, block.timestamp, "last activity");
    }

    function test_LpWithdraw_RealisesTheInterest() public {
        seedPool(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        vm.warp(START_TS + TERM);
        vm.prank(alice);
        manager.repay(loanId);

        uint256 lpBefore = asset.balanceOf(lp);
        uint256 lpShares = pool.balanceOf(lp);
        vm.prank(lp);
        uint256 assetsOut = pool.redeem(lpShares, lp, lp);

        assertApproxEqAbs(assetsOut, DEPOSIT + INTEREST, 1, "LP gets principal plus interest");
        assertEq(asset.balanceOf(lp), lpBefore + assetsOut, "assets delivered");
        assertEq(pool.totalSupply(), 0, "all shares burned");
    }

    function test_RepaidLoan_RaisesTheNextCreditLineForTheSameIdentity() public {
        seedPool(DEPOSIT);

        uint256 lineBefore = manager.quote(alice, 1e6, 30 days).creditLine;

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        vm.warp(START_TS + TERM);
        vm.prank(alice);
        manager.repay(loanId);

        CreditManager.Quote memory q = manager.quote(alice, 1e6, 30 days);
        assertGt(q.score, SCORE_TIER50, "score rose on a clean repayment");
        assertGt(q.creditLine, lineBefore, "credit line rose");
    }

    /// @dev A loan closed before the minimum holding period is honoured, but buys no standing.
    function test_Repay_BelowTheMinimumHoldDoesNotCountTowardsStanding() public {
        seedPool(DEPOSIT);

        uint256 scoreBefore = manager.quote(alice, 1e6, 30 days).score;

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, MAX_TERM);
        vm.warp(START_TS + registry.MIN_QUALIFYING_HOLD() - 1);

        vm.expectEmit(true, true, false, true, address(registry));
        emit StandingRegistry.LoanRepaid(KYC_ALICE, alice, PRINCIPAL, INTEREST * 2, false);
        vm.prank(alice);
        manager.repay(loanId);

        StandingRegistry.History memory h = historyOf(KYC_ALICE);
        assertEq(h.loansOriginated, 1, "the origination is still on the record");
        assertEq(h.loansRepaid, 0, "but it earned no repayment credit");
        assertEq(h.totalRepaid, 0, "and no volume credit");
        assertEq(manager.quote(alice, 1e6, 30 days).score, scoreBefore, "score unmoved");
    }

    function test_Repay_ExactlyAtTheMinimumHoldQualifies() public {
        seedPool(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, MAX_TERM);
        vm.warp(START_TS + registry.MIN_QUALIFYING_HOLD());
        vm.prank(alice);
        manager.repay(loanId);

        assertEq(historyOf(KYC_ALICE).loansRepaid, 1, "qualifying at the boundary");
    }
}
