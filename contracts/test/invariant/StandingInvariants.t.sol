// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";

import {Fixture} from "../helpers/Fixture.sol";
import {StandingHandler} from "./handlers/StandingHandler.sol";
import {CreditManager} from "../../src/CreditManager.sol";

/// @notice Properties that must hold after any sequence of deposits, draws, repayments, write-offs
///         and time travel.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract StandingInvariantsTest is Fixture {
    StandingHandler internal handler;

    function setUp() public override {
        super.setUp();
        seedPool(500_000e6);

        handler = new StandingHandler(pool, manager, asset, apass);

        targetContract(address(handler));
    }

    /// @notice The vault's stated assets are exactly what it holds plus what it has lent out.
    function invariant_TotalAssetsEqualsIdleBalancePlusOutstanding() public view {
        assertEq(
            pool.totalAssets(),
            asset.balanceOf(address(pool)) + pool.outstandingPrincipal(),
            "totalAssets accounting"
        );
    }

    /// @notice Per-identity exposure adds up to the pool's book. If these ever diverge, either an
    ///         identity is holding money the pool does not know about, or the reverse.
    function invariant_DrawnByIdentitySumsToOutstandingPrincipal() public view {
        uint256 sum;
        uint256 n = handler.identitiesLength();
        for (uint256 i = 0; i < n; i++) {
            sum += manager.drawnByIdentity(handler.identities(i));
        }
        assertEq(sum, pool.outstandingPrincipal(), "identity exposure vs pool book");
    }

    /// @notice No loan is ever Active with nothing owed, and the active book reconciles to the pool.
    function invariant_ActiveLoansHavePrincipalAndReconcileToThePool() public view {
        uint256 n = manager.loanCount();
        uint256 activePrincipal;
        for (uint256 id = 1; id <= n; id++) {
            CreditManager.Loan memory l = manager.loan(id);
            if (l.status == CreditManager.Status.Active) {
                assertGt(l.principal, 0, "active loan with zero principal");
                assertTrue(l.borrower != address(0), "active loan with no borrower");
                assertTrue(l.kycHash != bytes32(0), "active loan with no identity");
                activePrincipal += l.principal;
            }
        }
        assertEq(activePrincipal, pool.outstandingPrincipal(), "active book vs pool book");
    }

    /// @notice The credit manager custodies exactly the collateral of the loans that are still live.
    function invariant_ManagerHoldsExactlyTheLiveCollateral() public view {
        uint256 n = manager.loanCount();
        uint256 held;
        for (uint256 id = 1; id <= n; id++) {
            CreditManager.Loan memory l = manager.loan(id);
            if (l.status == CreditManager.Status.Active) held += l.collateral;
        }
        assertEq(asset.balanceOf(address(manager)), held, "collateral custody");
    }

    /// @notice Every loan the protocol ever wrote was under-collateralized. This is the product.
    function invariant_EveryLoanIsUnderCollateralized() public view {
        uint256 n = manager.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            CreditManager.Loan memory l = manager.loan(id);
            if (l.principal == 0) continue;
            assertLt(l.collateral, l.principal, "a loan was fully collateralized");
        }
    }

    /// @notice Utilization can never breach the risk parameter.
    function invariant_UtilizationStaysWithinTheRiskLimit() public view {
        assertLe(pool.utilizationBps(), pool.maxUtilizationBps(), "utilization limit");
    }

    /// @notice Losses only ever come from real shortfalls, and shares are never created from nothing.
    function invariant_SharesAreOnlyBackedByRealAssets() public view {
        if (pool.totalSupply() == 0) return;
        assertLe(pool.previewRedeem(pool.totalSupply()), pool.totalAssets(), "shares overissued");
    }

    function afterInvariant() public view {
        console.log("deposits    ", handler.ghostDeposits());
        console.log("withdrawals ", handler.ghostWithdrawals());
        console.log("opens       ", handler.ghostOpens());
        console.log("repayments  ", handler.ghostRepays());
        console.log("write-offs  ", handler.ghostDefaults());
        console.log("loans       ", manager.loanCount());
    }
}
