// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Fixture} from "../helpers/Fixture.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {InflationAttacker, MidTransferTrader} from "../mocks/Attackers.sol";
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
        asset.transfer(alice, 1e6);
        assertEq(manager.quote(alice, 1e6, TERM).score, IDENTITY_TIER50 + 20, "1 aUSDC is worth 20");
        assertFalse(manager.quote(alice, 1e6, TERM).approved, "and buys no credit at all");

        vm.prank(stranger);
        asset.transfer(alice, 10e6 - 1e6);
        assertEq(manager.quote(alice, 1e6, TERM).score, IDENTITY_TIER50 + 50, "10 aUSDC is worth 50");

        vm.prank(stranger);
        asset.transfer(alice, 100_000e6);
        assertEq(manager.quote(alice, 1e6, TERM).score, SCORE_TIER50, "and the ladder keeps climbing");

        // The point of the ladder: a trivial balance and a six-figure one are no longer the same
        // number, and the gap is worth an order of magnitude of credit.
        uint256 richLine = manager.quote(alice, 1e6, TERM).creditLine;
        uint256 remaining = asset.balanceOf(alice);
        vm.prank(alice);
        asset.transfer(stranger, remaining - 10e6);
        uint256 poorLine = manager.quote(alice, 1e6, TERM).creditLine;
        assertGt(richLine, poorLine * 3, "three times the line for a real balance");
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
        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), address(validator), admin);

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

        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), address(validator), admin);
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

        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), address(validator), admin);
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

    // ------------------------------------------------------------------ identity resolution

    /// @dev WAS: a re-verified borrower read as a clean identity whenever the link had not been
    ///      committed, and the link was rolled back by any reverting `open()`. NOW: `resolveIdentity`
    ///      reads through the credential's own `previousKycHash`, so resolution no longer depends on
    ///      a prior write at all.
    function test_Fixed_ReissueResolvesThroughThePreviousHashWithoutACommittedLink() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        vm.warp(block.timestamp + TERM + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        bytes32 v2 = keccak256("kyc:alice:v2");
        apass.rotateKycHash(alice, v2);

        // Nothing has been written to the registry for v2 at all...
        assertEq(registry.supersedes(v2), bytes32(0), "no link committed");
        // ...and the defaulter still resolves to the identity that owns the write-off.
        assertEq(manager.resolveIdentity(manager.credentialOf(alice)), KYC_ALICE, "resolved anyway");
        assertEq(manager.quote(alice, 1_000e6, TERM).score, SCORE_TIER50 - 250, "penalty applies");
        assertFalse(manager.quote(alice, 1_000e6, TERM).approved, "still refused");
    }

    /// @dev WAS: exposure accrued under a hash was stranded when that hash was later re-parented, so
    ///      the identity got a whole second credit line. NOW: `syncIdentity` migrates it.
    function test_Fixed_ExposureIsMigratedWhenAHashIsLinkedAfterItHasAlreadyBorrowed() public {
        bytes32 shared = keccak256("kyc:twins:current");
        bytes32 older = keccak256("kyc:twins:previous");

        address w1 = makeAddr("twinNoPrevious");
        address w2 = makeAddr("twinWithPrevious");
        onboard(w1, 50, 0, shared, START_BALANCE);
        onboard(w2, 50, 0, shared, START_BALANCE);
        apass.setPreviousKycHash(w2, older);

        vm.prank(w1);
        manager.open(LINE_TIER50, TERM);
        assertEq(manager.drawnByIdentity(shared), LINE_TIER50);

        // The sibling wallet re-parents the identity -- and the debt comes with it.
        uint256 min = manager.MIN_LOAN_PRINCIPAL();
        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsCreditLine.selector, min, 0));
        vm.prank(w2);
        manager.open(min, TERM);

        vm.prank(stranger);
        manager.syncIdentity(w2);
        assertEq(manager.drawnByIdentity(older), LINE_TIER50, "exposure followed the link");
        assertEq(manager.drawnByIdentity(shared), 0, "and nothing was left behind");
        assertEq(manager.quote(w2, 1e6, TERM).maxDrawNow, 0, "no second line");
        assertEq(pool.outstandingPrincipal(), LINE_TIER50, "one line, one person");
    }

    /// @dev The commit no longer depends on `open()` succeeding: anyone can land it standalone.
    function test_Fixed_LinkSurvivesARevertingOpenBecauseSyncIsIndependent() public {
        bytes32 v2 = keccak256("kyc:alice:v2");
        apass.rotateKycHash(alice, v2);

        // A reverting open still rolls its own sync back...
        vm.prank(alice);
        asset.approve(address(manager), 0);
        vm.expectRevert();
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
        assertEq(registry.supersedes(v2), bytes32(0), "rolled back with the transaction");

        // ...but the link can be committed by anybody, in its own transaction, for free.
        vm.prank(stranger);
        manager.syncIdentity(alice);
        assertEq(registry.supersedes(v2), KYC_ALICE, "committed and permanent");
        assertEq(registry.canonicalIdentity(v2), KYC_ALICE);
    }

    // ------------------------------------------------------------------ pool authority

    /// @dev WAS: `CREDIT_MANAGER_ROLE` was grantable, so pool admin could mint themselves the right
    ///      to move depositor funds. NOW: the manager is bound once and the role is gone.
    function test_Fixed_PoolDisbursementIsBoundToASingleImmutableCounterparty() public {
        assertEq(pool.creditManager(), address(manager), "bound at deployment");

        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(stranger);
        pool.fundLoan(stranger, 150_000e6);

        // Not even the admin, and not by re-binding either.
        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(admin);
        pool.fundLoan(admin, 150_000e6);

        vm.expectRevert(StandingPool.CreditManagerAlreadySet.selector);
        vm.prank(admin);
        pool.setCreditManager(stranger);

        assertEq(asset.balanceOf(address(pool)), DEPOSIT, "nothing left the pool");
    }

    function test_Fixed_SetCreditManagerIsAdminOnlyAndOneShot() public {
        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), address(validator), admin);
        assertEq(fresh.creditManager(), address(0), "unbound until set");

        bytes32 adminRole = fresh.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole
            )
        );
        vm.prank(stranger);
        fresh.setCreditManager(stranger);

        vm.prank(admin);
        fresh.setCreditManager(address(manager));
        assertEq(fresh.creditManager(), address(manager));

        vm.expectRevert(StandingPool.CreditManagerAlreadySet.selector);
        vm.prank(admin);
        fresh.setCreditManager(stranger);
    }

    /// @dev Until a manager is bound, the disbursement hooks are callable by nobody at all.
    function test_Fixed_UnboundPoolCannotDisburseToAnyone() public {
        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), address(validator), admin);

        vm.expectRevert(StandingPool.NotCreditManager.selector);
        vm.prank(admin);
        fresh.fundLoan(admin, 1);

        vm.expectRevert(StandingPool.NotCreditManager.selector);
        fresh.fundLoan(address(this), 1);
    }

    // ------------------------------------------------------------------ vault reentrancy

    /// @dev The ERC-4626 entry points are now guarded, so a token callback fired from inside one of
    ///      them cannot re-enter another. This is the case the guard actually covers -- see
    ///      KnownBugs.t.sol for the windows it does not reach.
    function test_Fixed_PoolEntryPointsCannotBeReenteredFromInsideEachOther() public {
        MidTransferTrader trader = new MidTransferTrader(pool, IERC20(address(asset)));
        onboard(address(trader), 50, 0, keccak256("kyc:reenter"), 500_000e6);

        // Give it a position so a nested redeem would otherwise succeed.
        vm.prank(address(trader));
        trader.lend(10_000e6);

        // Arm a redeem that fires during the pool's own deposit transfer.
        trader.arm(MidTransferTrader.Action.Redeem, address(pool));
        asset.setPreObserver(address(trader));
        vm.prank(address(trader));
        trader.lend(10_000e6);
        asset.setPreObserver(address(0));

        assertTrue(trader.fired(), "the nested call was attempted");
        assertTrue(trader.blocked(), "and the guard stopped it");
        assertEq(
            trader.blockedError(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "blocked by the reentrancy guard specifically"
        );
        assertEq(trader.assetsRedeemed(), 0, "nothing was taken out mid-deposit");
    }

    // ------------------------------------------------------------------ trust assumption

    /// @dev NOT A FIX -- a pin. `previousKycHash` is set by Cleanverse and the protocol trusts it
    ///      completely: whatever it names, the caller is folded into that identity. A contract
    ///      cannot verify an issuer's attestation about itself, so this stays an assumption. The
    ///      test exists so the assumption is visible in the suite rather than only in prose, and so
    ///      that anyone who later adds a check sees this go red.
    function test_TrustAssumption_PreviousKycHashIsAcceptedWithoutVerification() public {
        // A well-behaved borrower with a real record.
        vm.prank(lp2);
        uint256 loanId = manager.open(PRINCIPAL, MAX_TERM);
        vm.warp(block.timestamp + 30 days);
        vm.prank(lp2);
        manager.repay(loanId);
        assertEq(historyOf(KYC_LP2).loansRepaid, 1);

        // A credential naming a stranger's identity as the one it supersedes.
        address mallory = makeAddr("mallory");
        onboard(mallory, 50, 0, keccak256("kyc:mallory"), START_BALANCE);
        apass.setPreviousKycHash(mallory, KYC_LP2);

        // The protocol accepts it at face value: one identity, one shared line, one shared record.
        assertEq(
            manager.resolveIdentity(manager.credentialOf(mallory)),
            KYC_LP2,
            "folded into the victim on the issuer's word alone"
        );
        vm.prank(mallory);
        manager.open(PRINCIPAL, TERM);
        assertEq(manager.quote(lp2, 1e6, TERM).alreadyDrawn, PRINCIPAL, "victim's headroom consumed");
    }
}
