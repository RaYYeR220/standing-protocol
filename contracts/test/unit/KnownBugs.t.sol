// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Fixture} from "../helpers/Fixture.sol";
import {InflationAttacker, RepaymentFrontRunner} from "../mocks/Attackers.sol";
import {MockApass} from "../mocks/MockApass.sol";
import {ComplianceGate} from "../../src/ComplianceGate.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";

/// @title KnownBugs
/// @notice Findings against `src/`. Every test in this file passes because it asserts the buggy
///         behaviour that exists today; each one is a defect report with a repro, not a spec.
contract KnownBugsTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    // =================================================================================
    // BUG 1 (critical) -- `repay()` runs the compliance gate against the POOL, not the borrower.
    //
    // `_requireCompliant(msg.sender, address(pool), principal + interest)` and `checkTransfer`
    // credential-checks the `to` party. On the repayment leg `to` is the pool contract, which has no
    // A-Pass. script/Deploy.s.sol issues one to nobody, so on a real deployment no loan can ever be
    // repaid: every borrower is forced into default, every identity takes a 250-point write-off, and
    // every LP eats the shortfall.
    // =================================================================================

    function test_BUG_Repay_BrickedWhenPoolHasNoApass() public {
        vm.prank(alice);
        uint256 loanId = manager.open(5_000e6, 30 days);

        // Take away the credential the fixture hands the pool purely to work around this bug -- i.e.
        // put the pool in the state script/Deploy.s.sol actually leaves it in.
        apass.revoke(address(pool));
        assertFalse(manager.credentialOf(address(pool)).exists, "a fresh pool holds no A-Pass");

        expectRefusal(address(pool), ComplianceGate.Refusal.NoCredential);
        vm.prank(alice);
        manager.repay(loanId);
    }

    function test_BUG_Repay_BrickedLoanIsThenForcedIntoDefault() public {
        vm.prank(alice);
        uint256 loanId = manager.open(5_000e6, 30 days);
        apass.revoke(address(pool));

        // The borrower keeps trying, right up to the wire.
        vm.warp(START_TS + 30 days);
        expectRefusal(address(pool), ComplianceGate.Refusal.NoCredential);
        vm.prank(alice);
        manager.repay(loanId);

        // And is written off anyway, through no fault of their own.
        vm.warp(START_TS + 30 days + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        assertEq(historyOf(KYC_ALICE).loansDefaulted, 1, "solvent borrower defaulted");
        assertEq(pool.lifetimeLosses(), 5_000e6 - 3_660e6, "and the LPs paid for it");
    }

    /// @dev The same asymmetry stated directly: the borrow leg checks the borrower, the repay leg
    ///      checks the pool. A frozen borrower can repay; a pool with no credential cannot be repaid.
    function test_BUG_Repay_DoesNotCheckTheBorrowerAtAll() public {
        vm.prank(alice);
        uint256 loanId = manager.open(5_000e6, 30 days);

        apass.setStatus(alice, ApassReader.STATUS_FROZEN);
        (bool allowed, ComplianceGate.Refusal reason) = manager.checkTransfer(address(pool), alice, 1);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialFrozen));

        // Frozen, and the repayment sails through.
        vm.prank(alice);
        manager.repay(loanId);
        assertEq(uint256(manager.loan(loanId).status), uint256(CreditManager.Status.Repaid));
    }

    // =================================================================================
    // BUG 2 (critical) -- a re-issued A-Pass resets both the credit line and the credit history.
    //
    // StandingRegistry keys everything off `kycHash` and calls that "history follows the person".
    // But the registry publishes BOTH `previousKycHash` and `currentKycHash`, and ApassReader throws
    // the previous one away ("superseded by the current one"). A credential re-issue under a new
    // hash is therefore a clean slate: fresh line, no defaults.
    // =================================================================================

    function test_BUG_CreditLine_ResetsWhenTheCredentialIsReissuedUnderANewKycHash() public {
        vm.prank(alice);
        manager.open(LINE_TIER50, 30 days);
        assertEq(manager.quote(alice, 1, 30 days).maxDrawNow, 0, "fully drawn");

        // Same wallet, same person, new credential.
        bytes32 rotated = keccak256("kyc:alice:v2");
        apass.rotateKycHash(alice, rotated);
        assertEq(apass.recordOf(alice).previousKycHash, KYC_ALICE, "the link is on-chain and ignored");

        assertEq(manager.quote(alice, 1e6, 30 days).alreadyDrawn, 0, "exposure forgotten");
        assertEq(manager.quote(alice, 1e6, 30 days).maxDrawNow, LINE_TIER50, "a whole new line");

        vm.prank(alice);
        manager.open(LINE_TIER50, 30 days);

        // One human, two full credit lines, simultaneously outstanding.
        assertEq(manager.drawnByIdentity(KYC_ALICE), LINE_TIER50);
        assertEq(manager.drawnByIdentity(rotated), LINE_TIER50);
        assertEq(pool.outstandingPrincipal(), 2 * LINE_TIER50, "double the intended exposure");
    }

    function test_BUG_Default_IsLaunderedByReissuingTheCredential() public {
        vm.prank(alice);
        uint256 loanId = manager.open(5_000e6, 30 days);
        vm.warp(START_TS + 30 days + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        assertFalse(manager.quote(alice, 1_000e6, 30 days).approved, "defaulter is refused");

        apass.rotateKycHash(alice, keccak256("kyc:alice:v2"));

        CreditManager.Quote memory q = manager.quote(alice, 1_000e6, 30 days);
        assertEq(q.score, SCORE_TIER50, "the write-off has vanished");
        assertTrue(q.approved, "same wallet, same person, lending again");

        vm.prank(alice);
        manager.open(1_000e6, 30 days);
    }

    // =================================================================================
    // BUG 3 (high) -- the gate only ever checks the RECEIVER, so a frozen lender exits freely and a
    // pool share is a bearer instrument.
    // =================================================================================

    function test_BUG_Withdraw_FrozenLenderExitsThroughTheirOwnSecondWallet() public {
        vm.prank(alice);
        pool.deposit(10_000e6, alice);

        apass.setStatus(alice, ApassReader.STATUS_FROZEN);

        // Direct exit is refused, exactly as documented...
        expectRefusal(alice, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(alice);
        pool.withdraw(10_000e6, alice, alice);

        // ...and naming the same person's other wallet walks straight out.
        uint256 before = asset.balanceOf(aliceB);
        vm.prank(alice);
        pool.withdraw(10_000e6, aliceB, alice);
        assertEq(asset.balanceOf(aliceB), before + 10_000e6, "frozen lender slipped out");
    }

    function test_BUG_Shares_TransferFreelyToAnUncredentialedAddressAndCashOut() public {
        vm.prank(alice);
        uint256 shares = pool.deposit(10_000e6, alice);

        // The share token itself has no gate at all.
        vm.prank(alice);
        pool.transfer(stranger, shares);
        assertEq(pool.balanceOf(stranger), shares, "gated position now held by a stranger");

        // The stranger has no A-Pass and cannot receive -- but only the receiver is checked, so any
        // credentialed address will do as a mule.
        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(stranger);
        pool.redeem(shares, stranger, stranger);

        uint256 before = asset.balanceOf(aliceB);
        vm.prank(stranger);
        pool.redeem(shares, aliceB, stranger);
        assertGt(asset.balanceOf(aliceB), before, "an uncredentialed holder liquidated the position");
    }

    // =================================================================================
    // BUG 4 (high) -- `CREDIT_MANAGER_ROLE` can move pool assets to any address with no gate, and
    // the theft is invisible in `totalAssets()` because `outstandingPrincipal` absorbs it.
    // =================================================================================

    function test_BUG_Pool_RogueCreditManagerDrainsWithoutMovingTheSharePrice() public {
        uint256 assetsBefore = pool.totalAssets();
        uint256 priceBefore = pool.convertToAssets(1e6);

        bytes32 role = pool.CREDIT_MANAGER_ROLE();
        vm.prank(admin);
        pool.grantRole(role, stranger);

        // No credential, no policy check, no loan, no borrower.
        vm.prank(stranger);
        pool.fundLoan(stranger, 150_000e6);

        assertEq(asset.balanceOf(stranger), 1_000_000e6 + 150_000e6, "money is gone");
        assertEq(pool.totalAssets(), assetsBefore, "vault still claims the assets are there");
        assertEq(pool.convertToAssets(1e6), priceBefore, "share price does not flinch");
        assertEq(pool.outstandingPrincipal(), 150_000e6, "booked as a loan that does not exist");

        // And it can never be cleaned up: no loan id maps to it.
        assertEq(manager.loanCount(), 0);
    }

    // =================================================================================
    // BUG 5 (high) -- "An operator may make this contract stricter. Nobody can make it more
    // generous." An admin can make it arbitrarily more generous by forging registry history.
    // =================================================================================

    function test_BUG_Registry_AdminCanForgeHistoryAndInflateTheCreditLine() public {
        assertEq(manager.quote(vip, 1e6, 30 days).creditLine, LINE_VIP);
        assertGt(manager.quote(vip, MAX_LOAN_PRINCIPAL, 30 days).collateralRequired, 0);

        bytes32 recorder = registry.RECORDER_ROLE();
        vm.startPrank(admin);
        registry.grantRole(recorder, admin);
        for (uint256 i = 0; i < 10; i++) {
            registry.recordRepayment(KYC_VIP, vip, 10_000e6, 0);
        }
        vm.stopPrank();

        CreditManager.Quote memory q = manager.quote(vip, MAX_LOAN_PRINCIPAL, 30 days);
        assertEq(q.score, StandingMath.MAX_SCORE, "invented a perfect record");
        assertEq(q.creditLine, MAX_CREDIT_LINE, "top of the curve");
        assertEq(q.collateralRequired, 0, "and no collateral at all");
        assertEq(historyOf(KYC_VIP).loansOriginated, 0, "against loans that were never originated");

        vm.prank(vip);
        uint256 loanId = manager.open(MAX_LOAN_PRINCIPAL, 30 days);
        assertEq(manager.loan(loanId).collateral, 0, "fully unsecured, on forged standing");
    }

    // =================================================================================
    // BUG 6 (high) -- the history component is farmable at zero cost.
    //
    // A 1-unit loan rounds collateral and interest to zero, so open+repay in the same block is free
    // and still counts as a repaid loan. Ten of them is the whole 250-point repayment bucket.
    // =================================================================================

    function test_BUG_Score_HistoryIsFarmableWithFreeDustLoans() public {
        uint256 balanceBefore = asset.balanceOf(alice);
        uint256 lineBefore = manager.quote(alice, 1e6, 30 days).creditLine;
        uint256 collatBefore = manager.quote(alice, 10_000e6, 30 days).collateralRequired;

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            uint256 id = manager.open(1, 1 days);
            assertEq(manager.loan(id).collateral, 0, "no collateral on a dust loan");
            assertEq(manager.loan(id).interestDue, 0, "no interest either");
            vm.prank(alice);
            manager.repay(id);
        }

        assertEq(asset.balanceOf(alice), balanceBefore, "the whole exercise cost nothing");

        CreditManager.Quote memory q = manager.quote(alice, 10_000e6, 30 days);
        assertEq(q.score, SCORE_TIER50 + 250, "the entire repayment bucket, free");
        assertGt(q.creditLine, lineBefore * 3, "credit line more than tripled");
        assertLt(q.collateralRequired, collatBefore * 55 / 100, "collateral requirement cut by ~45%");
        assertEq(q.collateralRequired, 3_987e6, "7_320e6 of collateral becomes 3_987e6, for free");
    }

    // =================================================================================
    // BUG 7 (medium) -- the asset component saturates at 10 aUSDC.
    //
    // ASSET_UNIT = 1e6 and ASSET_CAP = 10, so ten dollars of verified balance is worth the full 250
    // points -- a quarter of the maximum score, and for a tier-50 identity the difference between no
    // credit at all and a five-figure line. The balance is read from `msg.sender` at `open()` time
    // and is never locked, so it can be borrowed for one transaction.
    // =================================================================================

    function test_BUG_Score_AssetComponentSaturatesAtTenDollars() public {
        uint256 bal = asset.balanceOf(alice);
        vm.prank(alice);
        asset.transfer(stranger, bal);
        assertEq(manager.quote(alice, 1e6, 30 days).score, 201, "no balance, no credit");

        vm.prank(stranger);
        asset.transfer(alice, 10e6);
        uint256 tenDollarScore = manager.quote(alice, 1e6, 30 days).score;

        asset.mint(alice, 10_000_000e6);
        uint256 tenMillionScore = manager.quote(alice, 1e6, 30 days).score;

        assertEq(tenDollarScore, SCORE_TIER50, "10 aUSDC maxes the asset bucket");
        assertEq(tenMillionScore, tenDollarScore, "10 million aUSDC is worth exactly the same");
    }

    function test_BUG_Score_EightDollarsIsTheDifferenceBetweenNoCreditAndAFiveFigureLine() public {
        uint256 bal = asset.balanceOf(alice);
        vm.prank(alice);
        asset.transfer(stranger, bal);

        vm.prank(stranger);
        asset.transfer(alice, 7e6);
        assertFalse(manager.quote(alice, 1e6, 30 days).approved, "7 aUSDC: refused");

        vm.prank(stranger);
        asset.transfer(alice, 1e6);
        CreditManager.Quote memory q = manager.quote(alice, 1e6, 30 days);
        assertEq(q.score, StandingMath.MIN_SCORE + 1, "8 aUSDC: eligible");
        assertEq(q.creditLine, 5_075e6, "on a 5,075 aUSDC line");
    }

    // =================================================================================
    // BUG 8 (medium) -- `repay()` moves the money before it books it, so `totalAssets()` counts the
    // returned principal twice for the duration of the transfer. With any asset that can call out
    // during a transfer -- and a Cleanverse Verified Asset does call its policy contract -- an LP can
    // redeem inside that window at a share price that has not happened yet.
    // =================================================================================

    function test_BUG_Repay_TotalAssetsIsOverstatedMidRepayment() public {
        RepaymentFrontRunner observer = new RepaymentFrontRunner(pool, IERC20(address(asset)));
        issueCredential(address(observer), 50, 0, keccak256("kyc:observer"));
        asset.mint(address(observer), 200_000e6);
        vm.prank(address(observer));
        observer.lend(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(5_000e6, 180 days);
        uint256 interest = manager.loan(loanId).interestDue;
        assertGt(interest, 0);

        uint256 assetsBeforeRepay = pool.totalAssets();

        asset.setObserver(address(observer));
        observer.arm();
        vm.prank(alice);
        manager.repay(loanId);

        assertTrue(observer.fired(), "the observer ran inside the repayment");
        assertEq(
            observer.totalAssetsDuringRepay(),
            assetsBeforeRepay + 5_000e6 + interest,
            "totalAssets counts the principal twice mid-repayment"
        );
        assertGt(observer.sharePriceDuringRepay(), pool.convertToAssets(1e6), "at a price that never was");
    }

    function test_BUG_Repay_MidRepaymentRedemptionStealsFromTheOtherLps() public {
        RepaymentFrontRunner observer = new RepaymentFrontRunner(pool, IERC20(address(asset)));
        issueCredential(address(observer), 50, 0, keccak256("kyc:observer"));
        asset.mint(address(observer), 200_000e6);
        vm.prank(address(observer));
        observer.lend(DEPOSIT);

        vm.prank(alice);
        uint256 loanId = manager.open(5_000e6, 180 days);
        uint256 interest = manager.loan(loanId).interestDue;

        // What each LP is honestly owed once the repayment has settled.
        uint256 fairClaim = (2 * DEPOSIT + interest) / 2;

        asset.setObserver(address(observer));
        observer.arm();
        vm.prank(alice);
        manager.repay(loanId);
        asset.setObserver(address(0));

        assertGt(observer.assetsRedeemed(), fairClaim, "the attacker took more than its share");
        assertLt(
            pool.previewRedeem(pool.balanceOf(lp)), fairClaim, "the honest LP is left holding the hole"
        );
        assertApproxEqAbs(
            observer.assetsRedeemed() - fairClaim,
            fairClaim - pool.previewRedeem(pool.balanceOf(lp)),
            2,
            "one for one, straight out of the other LP"
        );
    }

    // =================================================================================
    // BUG 9 (medium) -- `totalAssets()` reads `balanceOf`, so anyone -- credentialed or not -- can
    // move the share price of a compliance-gated vault with a plain transfer.
    // =================================================================================

    function test_BUG_Pool_SharePriceIsMovedByAnUngatedDonationFromAnUncredentialedAddress() public {
        assertFalse(manager.credentialOf(stranger).exists, "no A-Pass at all");
        uint256 priceBefore = pool.convertToAssets(1e6);

        vm.prank(stranger);
        asset.transfer(address(pool), 50_000e6);

        assertGt(pool.convertToAssets(1e6), priceBefore, "share price moved by a party the gate refuses");
        assertEq(pool.totalAssets(), DEPOSIT + 50_000e6, "counted as vault assets");
    }

    function test_BUG_Pool_FirstDepositorCanBeGriefedToZeroShares() public {
        // A fresh vault, before anyone has deposited.
        StandingPool fresh = new StandingPool(address(asset), address(apass), address(policy), admin);

        InflationAttacker attackerC = new InflationAttacker(fresh, IERC20(address(asset)));
        issueCredential(address(attackerC), 50, 0, keccak256("kyc:inflate"));
        asset.mint(address(attackerC), 100_000e6);

        attackerC.seed(1, 20_001e6);

        uint256 victimBefore = asset.balanceOf(lp2);
        vm.startPrank(lp2);
        asset.approve(address(fresh), type(uint256).max);
        fresh.deposit(10_000e6, lp2);
        vm.stopPrank();

        assertEq(fresh.balanceOf(lp2), 0, "victim received no shares whatsoever");
        assertEq(asset.balanceOf(lp2), victimBefore - 10_000e6, "and paid in full for them");
        assertEq(fresh.maxWithdraw(lp2), 0, "with nothing to withdraw");
    }

    // =================================================================================
    // BUG 10 (low) -- ApassReader decodes `group` / `subGroup` from the wrong end of the word.
    //
    // The registry returns these right-aligned (live Monad testnet: 0x…4344 and 0x…5244), but the
    // reader takes `bytes2(word)`, i.e. the two HIGH-order bytes. Every real credential decodes to
    // 0x0000. The library's note claims the layout was checked "word-for-word"; these two were not.
    // =================================================================================

    function test_BUG_ApassReader_GroupAndSubGroupAlwaysDecodeToZero() public {
        MockApass.Record memory r;
        r.status = 1;
        r.tier = 50;
        r.subTier = 30;
        r.group = bytes32(uint256(0x5244)); // "RD", exactly as the live registry encodes it
        r.subGroup = bytes32(uint256(0x4344)); // "CD"
        r.expiresAt = block.timestamp + ONE_YEAR;
        r.issuedAt = block.timestamp - ONE_YEAR;
        r.currentKycHash = keccak256("kyc:grouped");
        apass.issueFull(stranger, r);

        ApassReader.Credential memory c = manager.credentialOf(stranger);
        assertTrue(c.exists, "record decoded");
        assertEq(c.tier, 50, "tier is fine");
        assertEq(c.group, bytes2(0), "group is silently lost");
        assertEq(c.subGroup, bytes2(0), "so is subGroup");
    }

    // =================================================================================
    // BUG 11 (low) -- `SERVICER_ROLE` is declared and granted but guards nothing.
    // =================================================================================

    function test_BUG_CreditManager_ServicerRoleIsDeadCode() public view {
        assertTrue(manager.hasRole(manager.SERVICER_ROLE(), admin), "granted at deployment");
        // ...and there is no function anywhere in CreditManager that requires it.
    }
}
