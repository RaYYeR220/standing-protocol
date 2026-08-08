// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Fixture} from "../helpers/Fixture.sol";
import {InflationAttacker} from "../mocks/Attackers.sol";
import {ComplianceGate} from "../../src/ComplianceGate.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";

/// @title RegressionFixed
/// @notice One test per previously-reported defect, asserting the hole is actually closed.
/// @dev Each test states the original finding and then attempts the original exploit.
contract RegressionFixedTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant TERM = 30 days;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    // ------------------------------------------------------------------ the gate

    /// @dev WAS: `repay` checked only the receiving party, so the pool needed a credential and the
    ///      failure surfaced as an opaque policy denial. NOW: both ends are checked everywhere, and
    ///      the refusal names the party. The pool needing its own A-Pass is now the documented
    ///      design — see the deployment prerequisite test below.
    function test_Fixed_RepayNamesThePoolWhenThePoolIsTheUncredentialedParty() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);

        apass.revoke(address(pool));

        expectRefusal(address(pool), ComplianceGate.Refusal.NoCredential);
        vm.prank(alice);
        manager.repay(loanId);
    }

    /// @dev The protocol refuses everything until Cleanverse issues the pool a credential. That is
    ///      intended, but it is a hard deployment prerequisite: a deployment that skips it cannot
    ///      originate or repay a single loan.
    function test_Fixed_GateRefusesBothLegsUntilThePoolIsCredentialed() public {
        apass.revoke(address(pool));

        expectRefusal(address(pool), ComplianceGate.Refusal.NoCredential);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);

        (bool allowed, ComplianceGate.Refusal reason, address party) =
            manager.checkTransferDetailed(address(pool), alice, PRINCIPAL);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.NoCredential));
        assertEq(party, address(pool), "the diagnostic points straight at the missing credential");
    }

    /// @dev WAS: only the receiver was checked, so a frozen lender exited by naming their own second
    ///      wallet. NOW: the share owner is a party to the exit.
    function test_Fixed_FrozenLenderCannotExitThroughASecondWallet() public {
        vm.prank(alice);
        pool.deposit(10_000e6, alice);

        apass.setStatus(alice, ApassReader.STATUS_FROZEN);

        expectRefusal(alice, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(alice);
        pool.withdraw(10_000e6, alice, alice);

        // The original bypass: name a live wallet of the same person as receiver.
        expectRefusal(alice, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(alice);
        pool.withdraw(10_000e6, aliceB, alice);

        // And it cannot be laundered through a third party either.
        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.approve(aliceB, shares);
        expectRefusal(alice, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(aliceB);
        pool.redeem(shares, aliceB, alice);
    }

    /// @dev WAS: pool shares were ungated ERC-20, so a position could be handed to an address with
    ///      no credential and cashed out through any compliant receiver. NOW: `_update` gates both
    ///      ends of every share movement.
    function test_Fixed_SharesCannotBeTransferredToAnUncredentialedHolder() public {
        vm.prank(alice);
        uint256 shares = pool.deposit(10_000e6, alice);

        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(alice);
        pool.transfer(stranger, shares);

        assertEq(pool.balanceOf(stranger), 0, "no leakage");
        assertEq(pool.balanceOf(alice), shares, "position stays put");
    }

    /// @dev The gate is on the movement, not on the approval, so an allowance granted while healthy
    ///      does not survive the credential going away.
    function test_Fixed_ShareTransferFromCannotBypassTheGateWithAPreExistingAllowance() public {
        vm.prank(alice);
        uint256 shares = pool.deposit(10_000e6, alice);

        // Allowance granted while everyone is in good standing.
        vm.prank(alice);
        pool.approve(aliceB, shares);
        assertEq(pool.allowance(alice, aliceB), shares);

        // Recipient loses their credential afterwards.
        apass.setStatus(aliceB, ApassReader.STATUS_FROZEN);
        expectRefusal(aliceB, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(aliceB);
        pool.transferFrom(alice, aliceB, shares);

        // Or the sender does.
        apass.setStatus(aliceB, ApassReader.STATUS_ACTIVE);
        apass.setStatus(alice, ApassReader.STATUS_FROZEN);
        expectRefusal(alice, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(aliceB);
        pool.transferFrom(alice, aliceB, shares);

        // Or the destination never had one.
        apass.setStatus(alice, ApassReader.STATUS_ACTIVE);
        vm.prank(alice);
        pool.approve(stranger, shares);
        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(stranger);
        pool.transferFrom(alice, stranger, shares);
    }

    function test_Fixed_ShareTransfersStillWorkBetweenTwoCompliantParties() public {
        vm.prank(alice);
        uint256 shares = pool.deposit(10_000e6, alice);

        vm.prank(alice);
        pool.transfer(aliceB, shares);
        assertEq(pool.balanceOf(aliceB), shares, "compliant transfers are unaffected");
    }

    /// @dev WAS: `maxDeposit` collapsed to zero, so every refusal surfaced as
    ///      `ERC4626ExceededMaxDeposit` and the reason was unreachable. NOW: the gate lives in
    ///      `_deposit` and the caller gets the actual condition.
    function test_Fixed_DepositRefusalSurfacesTheReasonNotAnErc4626Cap() public {
        apass.setStatus(lp2, ApassReader.STATUS_FROZEN);

        assertEq(pool.maxDeposit(lp2), type(uint256).max, "no misleading cap");
        expectRefusal(lp2, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
    }

    // ------------------------------------------------------------------ scoring

    /// @dev WAS: 10 aUSDC bought the entire 250-point asset component, so a ten-dollar holder and a
    ///      ten-million-dollar holder scored identically and the balance could be flash-borrowed.
    ///      NOW: a base-10 ladder, and a tier-50 identity needs a real balance to clear MIN_SCORE.
    function test_Fixed_TenDollarsNoLongerBuysTheAssetScore() public {
        uint256 bal = asset.balanceOf(alice);
        vm.prank(alice);
        asset.transfer(stranger, bal);

        vm.prank(stranger);
        asset.transfer(alice, 10e6);
        assertEq(
            manager.quote(alice, 1e6, TERM).score, IDENTITY_TIER50 + 50, "10 aUSDC is worth 50 points now"
        );
        assertFalse(manager.quote(alice, 1e6, TERM).approved, "and buys no credit at all");

        vm.prank(stranger);
        asset.transfer(alice, 100e6 - 10e6);
        assertEq(manager.quote(alice, 1e6, TERM).score, IDENTITY_TIER50 + 100, "100 aUSDC");
        assertFalse(manager.quote(alice, 1e6, TERM).approved, "still short of the entry threshold");

        vm.prank(stranger);
        asset.transfer(alice, 1_000e6 - 100e6);
        assertEq(manager.quote(alice, 1e6, TERM).score, IDENTITY_TIER50 + 150, "1k aUSDC");
        assertTrue(manager.quote(alice, 1e6, TERM).approved, "a real balance does clear the bar");

        vm.prank(stranger);
        asset.transfer(alice, 100_000e6);
        assertEq(manager.quote(alice, 1e6, TERM).score, SCORE_TIER50, "and the ladder keeps climbing");
    }

    /// @dev WAS: 1-unit loans rounded collateral and interest to zero, so ten free open/repay cycles
    ///      in a single block bought the whole 250-point repayment bucket. NOW: a minimum principal
    ///      and a minimum holding period.
    function test_Fixed_HistoryCannotBeFarmedWithFreeDustLoans() public {
        uint256 scoreBefore = manager.quote(alice, 1e6, TERM).score;
        uint256 balanceBefore = asset.balanceOf(alice);

        // Dust is refused outright.
        vm.expectRevert(
            abi.encodeWithSelector(CreditManager.ExceedsLoanCeiling.selector, 1, MAX_LOAN_PRINCIPAL)
        );
        vm.prank(alice);
        manager.open(1, 1 days);

        // And a same-block round trip at the minimum size earns nothing.
        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            uint256 id = manager.open(min, 1 days);
            vm.prank(alice);
            manager.repay(id);
        }

        assertEq(historyOf(KYC_ALICE).loansRepaid, 0, "no repayment credit for instant round trips");
        assertEq(historyOf(KYC_ALICE).loansOriginated, 10, "the churn is still on the record");
        assertEq(manager.quote(alice, 1e6, TERM).score, scoreBefore, "score unmoved");
        // And it is no longer free either: the minimum principal is large enough that a day of
        // interest rounds to a real number, so the churn costs money and buys nothing.
        assertLt(asset.balanceOf(alice), balanceBefore, "the attempt cost the borrower money");
    }

    /// @dev Earning the same points now costs a day per loan and real interest.
    function test_Fixed_HistoryStillAccruesWhenLoansAreActuallyHeld() public {
        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            uint256 id = manager.open(min, 1 days);
            vm.warp(block.timestamp + registry.MIN_QUALIFYING_HOLD());
            vm.prank(alice);
            manager.repay(id);
        }
        assertEq(historyOf(KYC_ALICE).loansRepaid, 10, "ten days of real exposure");
        assertEq(manager.quote(alice, 1e6, TERM).score, SCORE_TIER50 + 250, "and the points are earned");
    }

    // ------------------------------------------------------------------ vault mechanics

    /// @dev WAS: `_decimalsOffset()` was 0, so a first depositor could be griefed to exactly zero
    ///      shares by a donation. NOW: six decimals of virtual offset.
    function test_Fixed_FirstDepositorCannotBeGriefedToZeroShares() public {
        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), admin);

        InflationAttacker attackerC = new InflationAttacker(fresh, IERC20(address(asset)));
        issueCredential(address(attackerC), 50, 0, keccak256("kyc:inflate"));
        asset.mint(address(attackerC), 500_000e6);

        // The original attack: 1 unit of shares, then a donation more than twice the victim deposit.
        attackerC.seed(1, 20_001e6);

        uint256 victimBefore = asset.balanceOf(lp2);
        vm.startPrank(lp2);
        asset.approve(address(fresh), type(uint256).max);
        uint256 shares = fresh.deposit(10_000e6, lp2);
        vm.stopPrank();

        assertGt(shares, 0, "the victim gets shares");
        assertEq(asset.balanceOf(lp2), victimBefore - 10_000e6, "and paid for them");
        // The donation is shared pro rata rather than confiscated; the victim keeps most of it.
        assertGt(fresh.previewRedeem(shares), 9_900e6, "victim retains substantially all of the deposit");
    }

    /// @dev The exact strength of the mitigation: with six decimals of offset a depositor is only
    ///      zeroed out once the donation exceeds their deposit by a factor of 1e6.
    function testFuzz_Fixed_DonationCannotZeroADepositorBelowAMillionToOne(
        uint256 donation,
        uint256 deposit
    ) public {
        deposit = bound(deposit, 1e6, 1_000_000e6);
        donation = bound(donation, 0, deposit * 1e6 - 1);

        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), admin);
        asset.mint(address(this), donation);
        asset.transfer(address(fresh), donation);

        asset.mint(lp2, deposit);
        vm.startPrank(lp2);
        asset.approve(address(fresh), type(uint256).max);
        uint256 shares = fresh.deposit(deposit, lp2);
        vm.stopPrank();

        assertGt(shares, 0, "a depositor is never zeroed out below the 1e6 ratio");
    }

    /// @dev Stated in money: griefing a 10_000 aUSDC depositor now costs 10 billion aUSDC, and the
    ///      griefer forfeits all of it to the victim's own pool.
    function test_Fixed_GriefingAFirstDepositorCostsAMillionToOne() public {
        uint256 victimDeposit = 10_000e6;

        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), admin);
        asset.mint(address(this), victimDeposit * 1e6);
        asset.transfer(address(fresh), victimDeposit * 1e6);

        asset.mint(lp2, victimDeposit);
        vm.startPrank(lp2);
        asset.approve(address(fresh), type(uint256).max);
        uint256 shares = fresh.deposit(victimDeposit, lp2);
        vm.stopPrank();

        assertEq(shares, 0, "only a 1e6-to-1 donation does it");
        assertEq(
            asset.balanceOf(address(fresh)) - victimDeposit,
            victimDeposit * 1e6,
            "and the attacker sank a million times the prize to get there"
        );
    }

    // ------------------------------------------------------------------ authority

    /// @dev WAS: the admin could grant themselves RECORDER_ROLE and invent a perfect repayment
    ///      history. NOW: the deployment renounces registry admin, so the recorder set is frozen.
    function test_Fixed_AdminCannotForgeRegistryHistoryAfterDeployment() public {
        assertFalse(
            registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), "admin renounced at deployment"
        );

        bytes32 recorder = registry.RECORDER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                admin,
                registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(admin);
        registry.grantRole(recorder, admin);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, recorder
            )
        );
        vm.prank(admin);
        registry.recordRepayment(KYC_ALICE, alice, 10_000e6, 0, 365 days);

        assertTrue(registry.hasRole(recorder, address(manager)), "the manager is still the recorder");
        assertFalse(registry.hasRole(recorder, admin), "and the admin never became one");
    }

    /// @dev WAS: `SERVICER_ROLE` was declared and granted but guarded nothing. NOW: removed.
    function test_Fixed_NoDeadServicerRoleRemains() public view {
        // The role no longer exists on the ABI; the manager's only role is the admin one.
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), admin));
    }

    /// @dev WAS: `_requireCompliant` emitted `ComplianceRefused` and then reverted in the same call,
    ///      so the event never survived. NOW: the gate is `view` and the event is gone; the refusal
    ///      reason is reachable through `checkTransferDetailed` instead.
    function test_Fixed_RefusalIsObservableWithoutASacrificialEvent() public {
        apass.setStatus(alice, ApassReader.STATUS_FROZEN);

        vm.recordLogs();
        (bool allowed, ComplianceGate.Refusal reason, address party) =
            pool.checkTransferDetailed(alice, lp, 1e6);
        assertEq(vm.getRecordedLogs().length, 0, "a view does not need to emit to be useful");

        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialFrozen));
        assertEq(party, alice);
    }

    // ------------------------------------------------------------------ retraction

    /// @dev RETRACTED. I previously reported that `ApassReader` decoded `group`/`subGroup` from the
    ///      wrong end of the word. It does not: the registry lays those two fields out LEFT-aligned
    ///      and `bytes2(word)` is the correct read. The earlier finding came from mis-splitting a
    ///      concatenated hex dump by hand. Live confirmation is in the fork suite.
    function test_Retracted_GroupTagsDecodeCorrectly() public {
        apass.setGroups(alice, bytes2("RD"), bytes2("CD"));

        ApassReader.Credential memory c = manager.credentialOf(alice);
        assertEq(c.group, bytes2("RD"), "group decodes");
        assertEq(c.subGroup, bytes2("CD"), "subGroup decodes");
    }
}
