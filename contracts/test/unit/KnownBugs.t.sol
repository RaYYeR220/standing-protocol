// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../helpers/Fixture.sol";
import {CreditManager} from "../../src/CreditManager.sol";

/// @title KnownBugs
/// @notice Defects that are still open against the current `src/`. Every test here passes because it
///         asserts the behaviour that exists today; each one is a repro, not a spec.
/// @dev The mid-transfer accounting windows that used to live here are closed; their regressions are
///      in PoolWindows.t.sol. Identity-linking defects are in ReissuedCredentials.t.sol.
contract KnownBugsTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant COLLATERAL = 2_800e6; // 56% of 5_000e6
    uint256 internal constant TERM = 180 days;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
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
