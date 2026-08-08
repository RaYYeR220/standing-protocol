// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Fixture} from "../helpers/Fixture.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";

/// @notice The ceilings the contract advertises as unraisable. Each is attacked at the boundary.
contract CapsTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    // ------------------------------------------------------------------ principal bounds

    function test_Borrow_RevertsAboveMaxLoanPrincipal() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.ExceedsLoanCeiling.selector, MAX_LOAN_PRINCIPAL + 1, MAX_LOAN_PRINCIPAL
            )
        );
        vm.prank(vip);
        manager.open(MAX_LOAN_PRINCIPAL + 1, 30 days);
    }

    function test_Borrow_RevertsOnZeroPrincipal() public {
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.ExceedsLoanCeiling.selector, 0, MAX_LOAN_PRINCIPAL)
        );
        vm.prank(alice);
        manager.open(0, 30 days);
    }

    function test_Borrow_RevertsBelowMinLoanPrincipal() public {
        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.ExceedsLoanCeiling.selector, min - 1, MAX_LOAN_PRINCIPAL)
        );
        vm.prank(alice);
        manager.open(min - 1, 30 days);
    }

    function test_Borrow_AllowedExactlyAtMinLoanPrincipal() public {
        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        vm.prank(alice);
        uint256 loanId = manager.open(min, 30 days);
        assertEq(manager.loan(loanId).principal, min);
    }

    /// @dev `maxLoanPrincipal` binds even when the identity's line is larger.
    function test_Borrow_MaxLoanPrincipalBindsBeforeTheCreditLine() public {
        _buildStrongRecord(vip, KYC_VIP);

        CreditManager.Quote memory q = manager.quote(vip, MAX_LOAN_PRINCIPAL, 30 days);
        assertGt(q.creditLine, MAX_LOAN_PRINCIPAL, "line exceeds the per-loan ceiling");
        assertEq(q.maxDrawNow, MAX_LOAN_PRINCIPAL, "headroom is clipped to the ceiling");

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.ExceedsLoanCeiling.selector, MAX_LOAN_PRINCIPAL + 1, MAX_LOAN_PRINCIPAL
            )
        );
        vm.prank(vip);
        manager.open(MAX_LOAN_PRINCIPAL + 1, 30 days);
    }

    // ------------------------------------------------------------------ score-derived credit line

    function test_Borrow_RevertsAboveTheScoreDerivedCreditLine() public {
        assertEq(manager.quote(alice, 1e6, 30 days).creditLine, LINE_TIER50);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.ExceedsCreditLine.selector, LINE_TIER50 + 1, LINE_TIER50
            )
        );
        vm.prank(alice);
        manager.open(LINE_TIER50 + 1, 30 days);
    }

    function test_Borrow_AllowedExactlyAtTheCreditLine() public {
        vm.prank(alice);
        uint256 loanId = manager.open(LINE_TIER50, 30 days);
        assertEq(manager.loan(loanId).principal, LINE_TIER50);
        assertEq(manager.drawnByIdentity(KYC_ALICE), LINE_TIER50);
    }

    function test_Borrow_RevertsBelowMinimumStanding() public {
        // Strip the verified balance and the identity drops from 451 to 201.
        uint256 bal = asset.balanceOf(alice);
        vm.prank(alice);
        asset.transfer(stranger, bal);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.BelowMinimumStanding.selector, IDENTITY_TIER50, StandingMath.MIN_SCORE
            )
        );
        vm.prank(alice);
        manager.open(100e6, 30 days);
    }

    // ------------------------------------------------------------------ term bounds

    function test_Borrow_RevertsBelowMinTerm() public {
        uint256 term = manager.MIN_TERM_SECONDS() - 1;
        vm.expectRevert(abi.encodeWithSelector(CreditManager.InvalidTerm.selector, term));
        vm.prank(alice);
        manager.open(1_000e6, term);
    }

    function test_Borrow_RevertsAboveMaxTerm() public {
        vm.expectRevert(abi.encodeWithSelector(CreditManager.InvalidTerm.selector, MAX_TERM + 1));
        vm.prank(alice);
        manager.open(1_000e6, MAX_TERM + 1);
    }

    function test_Borrow_AllowedExactlyAtTheTermBounds() public {
        uint256 minTerm = manager.MIN_TERM_SECONDS();
        vm.prank(alice);
        uint256 a = manager.open(1_000e6, minTerm);
        vm.prank(aliceB);
        uint256 b = manager.open(1_000e6, MAX_TERM);

        assertEq(manager.loan(a).dueAt, START_TS + 1 days);
        assertEq(manager.loan(b).dueAt, START_TS + MAX_TERM);
    }

    // ------------------------------------------------------------------ pool utilization

    function test_Borrow_RevertsAbovePoolMaxUtilization() public {
        _buildStrongRecord(vip, KYC_VIP);
        vm.prank(admin);
        pool.setMaxUtilizationBps(1000); // 10% of total assets

        uint256 ceiling = pool.totalAssets() * 1000 / 10_000;

        vm.prank(vip);
        manager.open(19_000e6, 30 days);

        vm.expectRevert(
            abi.encodeWithSelector(StandingPool.UtilizationExceeded.selector, 19_000e6 + 2_000e6, ceiling)
        );
        vm.prank(vipB);
        manager.open(2_000e6, 30 days);
    }

    function test_Borrow_AllowedExactlyAtMaxUtilization() public {
        _buildStrongRecord(vip, KYC_VIP);
        vm.prank(admin);
        pool.setMaxUtilizationBps(1000);

        uint256 ceiling = pool.totalAssets() * 1000 / 10_000;

        vm.prank(vip);
        manager.open(ceiling, 30 days);
        assertEq(pool.outstandingPrincipal(), ceiling, "exactly at the ceiling");
        assertLe(pool.utilizationBps(), 1000, "never above the ceiling");

        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        vm.expectRevert(
            abi.encodeWithSelector(StandingPool.UtilizationExceeded.selector, ceiling + min, ceiling)
        );
        vm.prank(vipB);
        manager.open(min, 30 days);
    }

    function test_SetMaxUtilization_RejectsOutOfRangeValues() public {
        vm.prank(admin);
        vm.expectRevert(StandingPool.InvalidParameter.selector);
        pool.setMaxUtilizationBps(0);

        vm.prank(admin);
        vm.expectRevert(StandingPool.InvalidParameter.selector);
        pool.setMaxUtilizationBps(10_001);
    }

    // ------------------------------------------------------------------ access control

    function test_SetMaxUtilization_IsRoleGated() public {
        bytes32 role = pool.RISK_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role
            )
        );
        vm.prank(stranger);
        pool.setMaxUtilizationBps(5000);
    }

    function test_FundLoan_IsBoundToTheCreditManager() public {
        assertEq(pool.creditManager(), address(manager), "bound at deployment");

        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(stranger);
        pool.fundLoan(stranger, 1_000e6);

        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(admin);
        pool.fundLoan(admin, 1_000e6);

        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(stranger);
        pool.collectRepayment(stranger, 1, 0);

        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(stranger);
        pool.collectSeizure(stranger, 1, 0);
    }

    function test_RegistryWrites_AreRoleGated() public {
        bytes32 role = registry.RECORDER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role
            )
        );
        vm.prank(stranger);
        registry.recordRepayment(KYC_ALICE, alice, 1_000e6, 0, 365 days);
    }

    function test_LinkIdentity_IsRoleGated() public {
        bytes32 role = registry.RECORDER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role
            )
        );
        vm.prank(stranger);
        registry.linkIdentity(KYC_ALICE, keccak256("attacker"));
    }

    function test_Repay_RevertsForANonBorrower() public {
        vm.prank(alice);
        uint256 loanId = manager.open(1_000e6, 30 days);

        vm.expectRevert(CreditManager.NotBorrower.selector);
        vm.prank(aliceB);
        manager.repay(loanId);
    }

    function test_Repay_RevertsOnANonActiveLoan() public {
        vm.prank(alice);
        uint256 loanId = manager.open(1_000e6, 30 days);
        vm.prank(alice);
        manager.repay(loanId);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.LoanNotActive.selector, loanId));
        vm.prank(alice);
        manager.repay(loanId);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Ten qualifying repayments maxes the repayment bucket. Each loan must now be held for at
    ///      least a day and each costs real interest, so this is time and money rather than a loop.
    function _buildStrongRecord(address wallet, bytes32 kycHash) internal {
        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(wallet);
            uint256 id = manager.open(min, 1 days);
            vm.warp(block.timestamp + registry.MIN_QUALIFYING_HOLD());
            vm.prank(wallet);
            manager.repay(id);
        }
        assertEq(historyOf(kycHash).loansRepaid, 10, "record built");
        assertEq(manager.quote(wallet, 1e6, 1 days).score, 900, "identity 400 + history 250 + assets 250");
        assertGt(
            manager.quote(wallet, 1e6, 1 days).creditLine, MAX_LOAN_PRINCIPAL, "line clears the ceiling"
        );
    }
}
