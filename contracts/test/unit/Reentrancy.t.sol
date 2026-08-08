// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Fixture} from "../helpers/Fixture.sol";
import {ReentrantBorrower} from "../mocks/Attackers.sol";
import {CreditManager} from "../../src/CreditManager.sol";

/// @notice A Cleanverse Verified Asset makes an external call to its policy contract on transfer, so
///         "this token never calls out" is not something the protocol gets for free. These tests put
///         attacker code in that window.
contract ReentrancyTest is Fixture {
    ReentrantBorrower internal attacker;
    bytes32 internal constant KYC_ATTACKER = keccak256("kyc:attacker");

    uint256 internal constant DEPOSIT = 200_000e6;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);

        attacker = new ReentrantBorrower(manager, IERC20(address(asset)), pool);
        issueCredential(address(attacker), 50, 0, KYC_ATTACKER);
        asset.mint(address(attacker), 100_000e6);
        asset.setObserver(address(attacker));
    }

    function test_Reentrancy_BorrowerCannotDoubleDrawDuringDisbursement() public {
        uint256 first = 5_000e6;
        uint256 second = 1_000e6;

        uint256 loanId = attacker.borrow(first, 30 days, second, 30 days);

        assertEq(attacker.attempts(), 1, "the attack ran");
        assertTrue(attacker.reenterBlocked(), "second draw blocked");
        assertFalse(attacker.reenterSucceeded(), "no second draw");
        assertEq(
            attacker.reenterError(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "blocked by the reentrancy guard specifically"
        );

        assertEq(manager.loanCount(), 1, "exactly one loan exists");
        assertEq(manager.loan(loanId).principal, first, "for the requested amount");
        assertEq(manager.drawnByIdentity(KYC_ATTACKER), first, "identity drew once");
        assertEq(pool.outstandingPrincipal(), first, "pool lent once");
        assertEq(asset.balanceOf(address(pool)), DEPOSIT - first, "pool paid out once");
    }

    /// @dev The disbursement leg increments `outstandingPrincipal` before it moves the tokens, so an
    ///      observer inside the transfer still sees a consistent balance sheet. Contrast with
    ///      KnownBugs.t.sol#test_BUG_Repay_TotalAssetsIsOverstatedMidRepayment.
    function test_Reentrancy_PoolAccountingStaysConsistentDuringDisbursement() public {
        uint256 assetsBefore = pool.totalAssets();

        attacker.borrow(5_000e6, 30 days, 1_000e6, 30 days);

        assertEq(
            attacker.poolAssetsDuringDisbursement(),
            assetsBefore,
            "lending must not move the share price, even transiently"
        );
        assertEq(attacker.poolOutstandingDuringDisbursement(), 5_000e6, "outstanding booked first");
    }

    function test_Reentrancy_BorrowerCannotRepayTheSameLoanTwice() public {
        uint256 loanId = attacker.borrowQuietly(5_000e6, 30 days);
        assertEq(manager.loanCount(), 1);

        uint256 managerBalBefore = asset.balanceOf(address(manager));
        assertEq(managerBalBefore, manager.loan(loanId).collateral, "collateral custodied");

        attacker.repayTwice(loanId);

        assertEq(attacker.attempts(), 1, "the attack ran");
        assertTrue(attacker.reenterBlocked(), "second repayment blocked");
        assertEq(
            attacker.reenterError(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "blocked by the reentrancy guard"
        );

        assertEq(
            uint256(manager.loan(loanId).status), uint256(CreditManager.Status.Repaid), "repaid once"
        );
        assertEq(asset.balanceOf(address(manager)), 0, "collateral returned exactly once");
        assertEq(pool.outstandingPrincipal(), 0, "book cleared once");
    }

    function test_Reentrancy_MarkDefaultCannotBeReenteredThroughTheCollateralSeizure() public {
        uint256 loanId = attacker.borrowQuietly(5_000e6, 30 days);
        vm.warp(START_TS + 30 days + manager.GRACE_PERIOD());

        // The observer is idle here; what matters is that a second write-off cannot be booked.
        manager.markDefault(loanId);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.LoanNotActive.selector, loanId));
        manager.markDefault(loanId);

        assertEq(pool.outstandingPrincipal(), 0, "principal removed exactly once");
        assertEq(historyOf(KYC_ATTACKER).loansDefaulted, 1, "one default recorded");
    }
}
