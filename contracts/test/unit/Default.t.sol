// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../helpers/Fixture.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";

/// @notice Write-offs: when they may be recognised, who pays for them, and what they cost the
///         identity that caused them.
contract DefaultTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant TERM = 30 days;
    uint256 internal constant COLLATERAL = 2_800e6; // 56% of 5_000e6
    uint256 internal constant SHORTFALL = PRINCIPAL - COLLATERAL;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    function _openAliceLoan() internal returns (uint256 loanId) {
        vm.prank(alice);
        loanId = manager.open(PRINCIPAL, TERM);
    }

    // ------------------------------------------------------------------ timing

    function test_MarkDefault_RevertsBeforeMaturity() public {
        uint256 loanId = _openAliceLoan();
        uint256 defaultableAt = START_TS + TERM + manager.GRACE_PERIOD();

        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.NotYetDefaulted.selector, loanId, defaultableAt)
        );
        manager.markDefault(loanId);
    }

    function test_MarkDefault_RevertsInsideTheGracePeriod() public {
        uint256 loanId = _openAliceLoan();
        uint256 defaultableAt = START_TS + TERM + manager.GRACE_PERIOD();

        vm.warp(defaultableAt - 1);
        assertFalse(manager.isDefaultable(loanId), "not defaultable one second early");

        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.NotYetDefaulted.selector, loanId, defaultableAt)
        );
        manager.markDefault(loanId);
    }

    function test_MarkDefault_AllowedExactlyAtTheEndOfGrace() public {
        uint256 loanId = _openAliceLoan();
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());

        assertTrue(manager.isDefaultable(loanId), "defaultable");
        manager.markDefault(loanId);
        assertEq(uint256(manager.loan(loanId).status), uint256(CreditManager.Status.Defaulted));
    }

    function test_MarkDefault_IsPermissionless() public {
        uint256 loanId = _openAliceLoan();
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());

        // Anyone, including a wallet with no credential at all, may recognise a bad debt.
        vm.prank(stranger);
        manager.markDefault(loanId);
        assertEq(uint256(manager.loan(loanId).status), uint256(CreditManager.Status.Defaulted));
    }

    function test_MarkDefault_RevertsOnAnAlreadyDefaultedLoan() public {
        uint256 loanId = _openAliceLoan();
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.LoanNotActive.selector, loanId));
        manager.markDefault(loanId);
    }

    function test_Repay_RevertsAfterTheLoanIsWrittenOff() public {
        uint256 loanId = _openAliceLoan();
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.LoanNotActive.selector, loanId));
        vm.prank(alice);
        manager.repay(loanId);
    }

    // ------------------------------------------------------------------ the write-off itself

    function test_MarkDefault_SeizesCollateralAndDropsTheSharePriceByTheShortfall() public {
        uint256 loanId = _openAliceLoan();
        uint256 interestDue = manager.loan(loanId).interestDue;

        uint256 assetsBefore = pool.totalAssets();
        uint256 priceBefore = sharePrice();
        uint256 supply = pool.totalSupply();
        uint256 poolBalBefore = asset.balanceOf(address(pool));

        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());

        vm.expectEmit(true, true, true, true, address(manager));
        emit CreditManager.LoanDefaulted(loanId, alice, KYC_ALICE, SHORTFALL, COLLATERAL);
        vm.expectEmit(true, true, true, true, address(manager));
        emit CreditManager.DefaultReportOpened(loanId, KYC_ALICE, alice, SHORTFALL + interestDue);
        manager.markDefault(loanId);

        // Collateral moved from the manager into the pool; the rest is simply gone.
        assertEq(asset.balanceOf(address(manager)), 0, "collateral seized in full");
        assertEq(asset.balanceOf(address(pool)), poolBalBefore + COLLATERAL, "pool received collateral");

        assertEq(pool.outstandingPrincipal(), 0, "loan is off the book");
        assertEq(pool.lifetimeLosses(), SHORTFALL, "loss recognised");
        assertEq(pool.totalAssets(), assetsBefore - SHORTFALL, "total assets fall by the shortfall");
        assertLt(sharePrice(), priceBefore, "LPs actually take the loss");
        assertEq(pool.totalSupply(), supply, "no shares minted or burned to hide it");

        assertEq(manager.drawnByIdentity(KYC_ALICE), 0, "exposure released");
    }

    function test_MarkDefault_LossIsSharedProRataBetweenLps() public {
        // A second LP joins at par before the loss lands.
        vm.prank(lp2);
        pool.deposit(DEPOSIT, lp2);

        uint256 loanId = _openAliceLoan();
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        uint256 shares1 = pool.balanceOf(lp);
        uint256 shares2 = pool.balanceOf(lp2);
        assertEq(shares1, shares2, "equal stakes");
        assertApproxEqAbs(pool.previewRedeem(shares1), pool.previewRedeem(shares2), 1, "equal losses");
        assertApproxEqAbs(
            pool.previewRedeem(shares1), DEPOSIT - SHORTFALL / 2, 1, "each LP eats half the shortfall"
        );
    }

    function test_MarkDefault_RecordsTheDefaultAgainstTheIdentity() public {
        uint256 loanId = _openAliceLoan();
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());

        vm.expectEmit(true, true, false, true, address(registry));
        emit StandingRegistry.LoanDefaulted(KYC_ALICE, alice, SHORTFALL);
        manager.markDefault(loanId);

        StandingRegistry.History memory h = historyOf(KYC_ALICE);
        assertEq(h.loansDefaulted, 1, "default counted");
        assertEq(h.totalDefaulted, SHORTFALL, "principal written off");
        assertEq(h.loansRepaid, 0, "no repayment credited");
        assertEq(h.lastActivityAt, block.timestamp, "last activity");
    }

    // ------------------------------------------------------------------ recourse across wallets

    function test_Default_RefusesTheSameIdentityOnAFreshWallet() public {
        uint256 loanId = _openAliceLoan();
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        // A wallet the protocol has never seen, funded, credentialed, same person.
        address aliceC = makeAddr("aliceC");
        onboard(aliceC, 50, 0, KYC_ALICE, START_BALANCE);

        CreditManager.Quote memory q = manager.quote(aliceC, 1_000e6, TERM);
        assertEq(q.score, SCORE_TIER50 - StandingMath.DEFAULT_PENALTY, "penalty follows the person");
        assertFalse(q.approved, "fresh wallet is refused");
        assertEq(q.creditLine, 0, "no line at all");

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BelowMinimumStanding.selector,
                SCORE_TIER50 - StandingMath.DEFAULT_PENALTY,
                StandingMath.MIN_SCORE
            )
        );
        vm.prank(aliceC);
        manager.open(1_000e6, TERM);
    }

    function test_Default_ShrinksTheLineOfAStrongIdentityOnAFreshWallet() public {
        // A tier-99 identity survives one default, but on much worse terms.
        uint256 lineBefore = manager.quote(vip, 1_000e6, TERM).creditLine;
        assertEq(lineBefore, LINE_VIP, "starting line");

        vm.prank(vip);
        uint256 loanId = manager.open(10_000e6, TERM);
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        address vipC = makeAddr("vipC");
        onboard(vipC, 99, 99, KYC_VIP, START_BALANCE);

        CreditManager.Quote memory q = manager.quote(vipC, 1_000e6, TERM);
        assertEq(q.score, SCORE_VIP - StandingMath.DEFAULT_PENALTY, "score dropped by the penalty");
        assertLt(q.creditLine, lineBefore, "a fresh wallet gets a smaller line");
        // 650 - 250 = 400, i.e. 100 points above MIN_SCORE on a 700-point span.
        assertEq(q.creditLine, 11_428_571_428, "close to the floor of the curve");
        assertGt(q.collateralRequired, 0, "and has to post collateral again");

        // It can still borrow -- but at a third of the size and with collateral again.
        assertLt(q.creditLine * 2, LINE_VIP, "the line is cut by more than half");
        vm.prank(vipC);
        uint256 second = manager.open(q.creditLine, TERM);
        assertEq(manager.loan(second).principal, q.creditLine);
    }

    function test_Default_IsCumulativeAcrossLoans() public {
        vm.prank(vip);
        uint256 a = manager.open(5_000e6, TERM);
        vm.prank(vipB);
        uint256 b = manager.open(5_000e6, TERM);

        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());
        manager.markDefault(a);
        assertEq(manager.quote(vip, 1e6, TERM).score, SCORE_VIP - StandingMath.DEFAULT_PENALTY);

        manager.markDefault(b);
        assertEq(manager.quote(vip, 1e6, TERM).score, SCORE_VIP - 2 * StandingMath.DEFAULT_PENALTY);
        assertFalse(manager.quote(vip, 1e6, TERM).approved, "two write-offs and the line is gone");
    }

    /// @dev A default outruns the component caps: a big verified balance cannot paper over it.
    function test_Default_CannotBePaperedOverWithABigBalance() public {
        uint256 loanId = _openAliceLoan();
        vm.warp(START_TS + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        asset.mint(alice, 10_000_000e6);
        assertEq(
            manager.quote(alice, 1e6, TERM).score,
            SCORE_TIER50 - StandingMath.DEFAULT_PENALTY,
            "wealth does not buy the penalty back"
        );
    }
}
