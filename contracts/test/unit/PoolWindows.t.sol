// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Fixture} from "../helpers/Fixture.sol";
import {MidTransferTrader} from "../mocks/Attackers.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";

/// @title PoolWindows
/// @notice The three moments where the pool's books and its balance disagree, attacked from inside
///         the token transfer that creates them.
///
/// @dev A Cleanverse Verified Asset hands control to its policy contract mid-transfer, so every one
///      of these windows is reachable by attacker code. The first attempt at a fix put `nonReentrant`
///      on the ERC-4626 entry points, which did nothing: none of the three windows had the pool on
///      the stack, so the guard was never entered. Each test below therefore asserts the specific
///      revert data — `ReentrancyGuardReentrantCall()` — rather than merely that the trade failed.
///      Anything else, and the guard is not the thing doing the stopping.
contract PoolWindowsTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant COLLATERAL = 2_800e6;
    uint256 internal constant TERM = 180 days;

    MidTransferTrader internal trader;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);

        trader = new MidTransferTrader(pool, IERC20(address(asset)));
        onboard(address(trader), 50, 0, keccak256("kyc:windows"), 500_000e6);
    }

    function _assertGuardEntered() internal view {
        assertTrue(trader.fired(), "the attack ran");
        assertTrue(trader.blocked(), "and the pool refused it");
        assertEq(
            trader.blockedError(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "stopped by the reentrancy guard, not by anything incidental"
        );
    }

    // ------------------------------------------------------------------ repay

    function test_Fixed_RepayWindow_DepositIsBlockedWhileTheBooksAndBalanceDisagree() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        uint256 interest = manager.loan(loanId).interestDue;

        trader.setDepositAmount(100_000e6);
        trader.arm(MidTransferTrader.Action.Deposit, address(pool));
        asset.setPreObserver(address(trader));
        vm.warp(START_TS + TERM);
        vm.prank(alice);
        manager.repay(loanId);
        asset.setPreObserver(address(0));

        _assertGuardEntered();
        assertEq(trader.sharesMinted(), 0, "no shares were minted at the stale price");
        assertEq(pool.balanceOf(address(trader)), 0, "the attacker holds no position");
        assertEq(pool.totalAssets(), DEPOSIT + interest, "LPs kept the whole interest");
        assertApproxEqAbs(
            pool.previewRedeem(pool.balanceOf(lp)), DEPOSIT + interest, 1, "and all of it went to them"
        );
    }

    function test_Fixed_RepayWindow_RedeemIsBlockedToo() public {
        vm.prank(address(trader));
        trader.lend(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);

        trader.arm(MidTransferTrader.Action.Redeem, address(pool));
        asset.setPreObserver(address(trader));
        vm.warp(START_TS + TERM);
        vm.prank(alice);
        manager.repay(loanId);
        asset.setPreObserver(address(0));

        _assertGuardEntered();
        assertEq(trader.assetsRedeemed(), 0, "nothing was taken out mid-repayment");
    }

    /// @dev The borrower's assets land on the credit manager before the pool collects them. That leg
    ///      is outside the pool entirely — and it has to be, because at that instant the pool's books
    ///      and its balance still agree: the loan has not been settled yet.
    function test_RepayWindow_FirstLegLeavesThePoolConsistent() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);

        uint256 assetsBefore = pool.totalAssets();

        trader.arm(MidTransferTrader.Action.None, address(manager));
        asset.setPreObserver(address(trader));
        vm.warp(START_TS + TERM);
        vm.prank(alice);
        manager.repay(loanId);
        asset.setPreObserver(address(0));

        assertTrue(trader.fired(), "observed the borrower -> manager leg");
        assertEq(
            trader.totalAssetsSeen(), assetsBefore, "the pool is untouched until it collects"
        );
    }

    // ------------------------------------------------------------------ markDefault

    function test_Fixed_SeizureWindow_RedeemIsBlockedWhileCollateralIsCollected() public {
        vm.prank(address(trader));
        trader.lend(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, 30 days);
        vm.warp(START_TS + 30 days + manager.GRACE_PERIOD());

        trader.arm(MidTransferTrader.Action.Redeem, address(pool));
        asset.setPreObserver(address(trader));
        manager.markDefault(loanId);
        asset.setPreObserver(address(0));

        _assertGuardEntered();
        assertEq(trader.assetsRedeemed(), 0, "nothing was taken out mid-seizure");

        // Both LPs are equal and both eat exactly half the shortfall.
        uint256 shortfall = PRINCIPAL - COLLATERAL;
        assertEq(pool.lifetimeLosses(), shortfall, "loss booked once");
        assertApproxEqAbs(
            pool.previewRedeem(pool.balanceOf(lp)), DEPOSIT - shortfall / 2, 1, "honest LP"
        );
        assertApproxEqAbs(
            pool.previewRedeem(pool.balanceOf(address(trader))),
            DEPOSIT - shortfall / 2,
            1,
            "attacker took no more than its share"
        );
    }

    function test_Fixed_SeizureWindow_DepositIsBlockedToo() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, 30 days);
        vm.warp(START_TS + 30 days + manager.GRACE_PERIOD());

        trader.setDepositAmount(50_000e6);
        trader.arm(MidTransferTrader.Action.Deposit, address(pool));
        asset.setPreObserver(address(trader));
        manager.markDefault(loanId);
        asset.setPreObserver(address(0));

        _assertGuardEntered();
        assertEq(trader.sharesMinted(), 0, "no discounted entry");
    }

    // ------------------------------------------------------------------ fundLoan

    function test_Fixed_DisbursementWindow_RedeemIsBlockedWhileTheLoanIsPaidOut() public {
        vm.prank(address(trader));
        trader.lend(DEPOSIT);

        trader.arm(MidTransferTrader.Action.Redeem, alice);
        asset.setPreObserver(address(trader));
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
        asset.setPreObserver(address(0));

        _assertGuardEntered();
        assertEq(trader.assetsRedeemed(), 0, "nothing was taken out mid-disbursement");
        assertEq(pool.outstandingPrincipal(), PRINCIPAL, "the loan still went out cleanly");
    }

    function test_Fixed_DisbursementWindow_DepositIsBlockedToo() public {
        trader.setDepositAmount(50_000e6);
        trader.arm(MidTransferTrader.Action.Deposit, alice);
        asset.setPreObserver(address(trader));
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
        asset.setPreObserver(address(0));

        _assertGuardEntered();
        assertEq(trader.sharesMinted(), 0);
    }

    // ------------------------------------------------------------------ collection arithmetic

    /// @dev `collectSeizure` retires `recovered + shortfall` in one statement and only pulls tokens
    ///      for the recovered part. The two have to add up to the principal or the pool's book drifts.
    function test_CollectSeizure_RetiresExactlyThePrincipalAndPullsExactlyTheCollateral() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, 30 days);

        uint256 poolBalBefore = asset.balanceOf(address(pool));
        uint256 managerBalBefore = asset.balanceOf(address(manager));
        assertEq(managerBalBefore, COLLATERAL, "manager holds the collateral");

        vm.warp(START_TS + 30 days + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        assertEq(pool.outstandingPrincipal(), 0, "the whole principal is retired");
        assertEq(pool.lifetimeLosses(), PRINCIPAL - COLLATERAL, "shortfall booked");
        assertEq(asset.balanceOf(address(pool)), poolBalBefore + COLLATERAL, "only the collateral moved");
        assertEq(asset.balanceOf(address(manager)), 0, "and the manager kept nothing");
        assertEq(pool.totalAssets(), DEPOSIT - (PRINCIPAL - COLLATERAL), "share price down by the loss");
    }

    /// @dev A top-of-the-curve borrower posts nothing, so a default collects nothing: the seizure
    ///      path has to work with `recovered == 0` and skip the transfer entirely.
    function test_CollectSeizure_HandlesAZeroCollateralDefault() public {
        _buildPerfectRecord(vip, KYC_VIP);
        assertEq(manager.quote(vip, 1e6, 30 days).collateralRequired, 0, "nothing to post");

        vm.prank(vip);
        uint256 loanId = manager.open(PRINCIPAL, 30 days);
        assertEq(manager.loan(loanId).collateral, 0, "fully unsecured");
        assertEq(asset.balanceOf(address(manager)), 0, "manager custodies nothing");

        uint256 assetsBefore = pool.totalAssets();
        vm.warp(block.timestamp + 30 days + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        assertEq(pool.outstandingPrincipal(), 0, "principal retired");
        assertEq(pool.lifetimeLosses(), PRINCIPAL, "the whole loan is the loss");
        assertEq(pool.totalAssets(), assetsBefore - PRINCIPAL, "and all of it lands on the LPs");
    }

    /// @dev The manager grants the pool an unlimited allowance so the pool can pull. Nothing but the
    ///      bound manager can trigger a pull, so the allowance is inert in anyone else's hands.
    function test_ManagerAllowanceToThePoolIsUnusableByAnyoneElse() public {
        assertEq(
            asset.allowance(address(manager), address(pool)),
            type(uint256).max,
            "the approval exists, by design"
        );

        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
        assertEq(asset.balanceOf(address(manager)), COLLATERAL, "a collateral pot worth taking");

        // Only the bound manager may ask the pool to pull, so the pot cannot be reached.
        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(stranger);
        pool.collectRepayment(address(manager), COLLATERAL, 0);

        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(admin);
        pool.collectSeizure(address(manager), COLLATERAL, 0);

        // And a second pool pointed at the same manager has no allowance and no authority.
        StandingPool rogue = new StandingPool(address(asset), address(apass), address(policy), stranger);
        vm.prank(stranger);
        rogue.setCreditManager(stranger);
        vm.expectRevert();
        vm.prank(stranger);
        rogue.collectRepayment(address(manager), COLLATERAL, 0);

        assertEq(asset.balanceOf(address(manager)), COLLATERAL, "the pot is untouched");
    }

    // ------------------------------------------------------------------ helpers

    function _buildPerfectRecord(address wallet, bytes32 kycHash) internal {
        // Ten qualifying repayments of 1_000 aUSDC each: maxes both the repayment count and the
        // repaid-volume component, which together with a tier-99 identity reaches MAX_SCORE.
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(wallet);
            uint256 id = manager.open(1_000e6, 1 days);
            vm.warp(block.timestamp + registry.MIN_QUALIFYING_HOLD());
            vm.prank(wallet);
            manager.repay(id);
        }
        assertEq(historyOf(kycHash).loansRepaid, 10, "record built");
        assertEq(manager.quote(wallet, 1e6, 1 days).score, 1000, "top of the curve");
    }
}
