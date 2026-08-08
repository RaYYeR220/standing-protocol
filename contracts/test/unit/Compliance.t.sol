// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../helpers/Fixture.sol";
import {ComplianceGate} from "../../src/ComplianceGate.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";

/// @notice Every way the gate can say no, on every path that moves value.
contract ComplianceTest is Fixture {
    uint256 internal constant DEPOSIT = 50_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant TERM = 180 days;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    // ------------------------------------------------------------------ both ends are checked

    function test_Gate_ChecksTheSendingPartyToo() public view {
        (bool allowed, ComplianceGate.Refusal reason, address party) =
            pool.checkTransferDetailed(stranger, lp, 1e6);
        assertFalse(allowed, "an uncredentialed sender is a refusal");
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.NoCredential));
        assertEq(party, stranger, "and the sender is named as the failing party");
    }

    function test_Gate_NamesTheFailingPartyNotJustTheReason() public {
        apass.setStatus(alice, ApassReader.STATUS_FROZEN);

        (bool allowed, ComplianceGate.Refusal reason, address party) =
            pool.checkTransferDetailed(alice, lp, 1e6);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialFrozen));
        assertEq(party, alice, "the frozen end is identified");

        (,, address party2) = pool.checkTransferDetailed(lp, alice, 1e6);
        assertEq(party2, alice, "whichever end it is");
    }

    function test_CheckParty_ReportsEachConditionSeparately() public {
        (bool ok, ComplianceGate.Refusal reason) = pool.checkParty(alice);
        assertTrue(ok);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.None));

        (ok, reason) = pool.checkParty(stranger);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.NoCredential));

        apass.setStatus(aliceB, ApassReader.STATUS_FROZEN);
        (ok, reason) = pool.checkParty(aliceB);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialFrozen));

        apass.setExpiry(vip, block.timestamp);
        (ok, reason) = pool.checkParty(vip);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialExpired));
    }

    /// @dev The pool is a party to every disbursement. If it loses its credential the protocol
    ///      stops, by design.
    function test_Gate_RefusesEverythingIfThePoolLosesItsCredential() public {
        apass.setStatus(address(pool), ApassReader.STATUS_FROZEN);

        expectRefusal(address(pool), ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    // ------------------------------------------------------------------ borrow: refusal paths

    function test_Borrow_RefusedWhenNoCredential() public {
        (bool allowed, ComplianceGate.Refusal reason) =
            manager.checkTransfer(address(pool), stranger, PRINCIPAL);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.NoCredential));

        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(stranger);
        manager.open(PRINCIPAL, TERM);
    }

    /// @dev The live registry reverts for an unknown holder rather than returning zeroes; the reader
    ///      must turn that into an ordinary refusal, not an exception.
    function test_Borrow_RefusedWhenRegistryReturnsAnAllZeroRecord() public {
        apass.setZeroForUnknown(true);

        ApassReader.Credential memory c = manager.credentialOf(stranger);
        assertFalse(c.exists, "all-zero record must not count as a credential");

        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(stranger);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Borrow_RefusedWhenRegistryReturnsMalformedRecord() public {
        apass.setTruncate(true);

        assertFalse(manager.credentialOf(alice).exists, "short record is not a credential");

        // The pool's credential now reads as absent too, and it is checked first.
        expectRefusal(address(pool), ComplianceGate.Refusal.NoCredential);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Borrow_RefusedWhenRegistryIsUnreachable() public {
        apass.setDown(true);

        expectRefusal(address(pool), ComplianceGate.Refusal.NoCredential);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Borrow_RefusedWhenCredentialFrozen() public {
        apass.setStatus(alice, ApassReader.STATUS_FROZEN);

        (bool allowed, ComplianceGate.Refusal reason) =
            manager.checkTransfer(address(pool), alice, PRINCIPAL);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialFrozen));

        expectRefusal(alice, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Borrow_RefusedWhenCredentialExpired() public {
        apass.setExpiry(alice, block.timestamp);

        (bool allowed, ComplianceGate.Refusal reason) =
            manager.checkTransfer(address(pool), alice, PRINCIPAL);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialExpired));

        expectRefusal(alice, ComplianceGate.Refusal.CredentialExpired);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Borrow_RefusedWhenAssetPolicyDenies() public {
        policy.setSubjectDenied(address(asset), true);

        expectRefusal(alice, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Borrow_RefusedWhenAssetPolicyDeniesThePartyRatherThanTheAsset() public {
        policy.setPartyDenied(alice, true);

        expectRefusal(alice, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Borrow_RefusedWhenProtocolPolicyDenies() public {
        // The asset's own rules still permit the transfer; the protocol's do not.
        validator.setRegistered(address(manager), true);
        validator.setPartyDenied(alice, true);

        (bool allowed, ComplianceGate.Refusal reason) =
            manager.checkTransfer(address(pool), alice, PRINCIPAL);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.ProtocolPolicyDenied));

        expectRefusal(alice, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    /// @dev Unregistered means the protocol rule set simply does not apply — not that it denies.
    function test_Borrow_AllowedWhenProtocolIsNotRegisteredEvenIfItsRulesWouldDeny() public {
        validator.setRegistered(address(manager), false);
        validator.setPartyDenied(alice, true);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        assertEq(manager.loan(loanId).principal, PRINCIPAL);
    }

    function test_Borrow_RefusedWhenPolicyReverts_FailsClosed() public {
        policy.setDown(true);

        (bool allowed, ComplianceGate.Refusal reason) =
            manager.checkTransfer(address(pool), alice, PRINCIPAL);
        assertFalse(allowed, "a reverting policy is a refusal, not an inconclusive result");
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.AssetPolicyDenied));

        expectRefusal(alice, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    /// @dev The live engine refuses by reverting with a custom error, not by returning false.
    function test_Borrow_RefusedWhenPolicyRevertsWithARefusalError() public {
        policy.setRevertInsteadOfDeny(true);
        policy.setPartyDenied(alice, true);

        expectRefusal(alice, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    /// @dev A registration lookup that reverts must not be read as "registered".
    function test_Borrow_AllowedWhenOnlyRegistrationLookupReverts() public {
        validator.setDown(true);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        assertEq(manager.loan(loanId).principal, PRINCIPAL);
    }

    // ------------------------------------------------------------------ LP deposit: refusal paths

    function test_Deposit_RefusedWhenNoCredential() public {
        (bool allowed, ComplianceGate.Refusal reason) = pool.checkTransfer(stranger, stranger, 1e6);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.NoCredential));

        // The gate now lives in `_deposit`, so the refusal reason survives to the caller.
        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(stranger);
        pool.deposit(1e6, stranger);
    }

    function test_Deposit_RefusedWhenCredentialFrozen() public {
        apass.setStatus(lp2, ApassReader.STATUS_FROZEN);

        expectRefusal(lp2, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
    }

    function test_Deposit_RefusedWhenCredentialExpired() public {
        apass.setExpiry(lp2, block.timestamp);

        expectRefusal(lp2, ComplianceGate.Refusal.CredentialExpired);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
    }

    function test_Deposit_RefusedWhenTheDepositorIsUncredentialedEvenIfTheReceiverIsNot() public {
        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(stranger);
        pool.deposit(1_000e6, lp);
    }

    function test_Deposit_RefusedWhenCallerDeniedByAssetPolicy() public {
        policy.setPartyDenied(lp2, true);

        expectRefusal(lp, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp);
    }

    function test_Deposit_RefusedWhenProtocolPolicyDenies() public {
        validator.setRegistered(address(pool), true);
        validator.setPartyDenied(lp2, true);

        expectRefusal(lp2, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
    }

    function test_Deposit_RefusedWhenPolicyReverts_FailsClosed() public {
        policy.setDown(true);

        expectRefusal(lp2, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
    }

    function test_Mint_RefusedWhenPolicyReverts_FailsClosed() public {
        policy.setDown(true);

        expectRefusal(lp2, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp2);
        pool.mint(1_000e12, lp2);
    }

    // ------------------------------------------------------------------ LP withdrawal: refusals

    function test_Withdraw_RefusedWhenCredentialFrozen() public {
        apass.setStatus(lp, ApassReader.STATUS_FROZEN);

        expectRefusal(lp, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(lp);
        pool.withdraw(1_000e6, lp, lp);
    }

    function test_Withdraw_RefusedWhenCredentialExpired() public {
        apass.setExpiry(lp, block.timestamp);

        expectRefusal(lp, ComplianceGate.Refusal.CredentialExpired);
        vm.prank(lp);
        pool.withdraw(1_000e6, lp, lp);
    }

    function test_Withdraw_RefusedWhenReceiverHasNoCredential() public {
        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(lp);
        pool.withdraw(1_000e6, stranger, lp);
    }

    function test_Withdraw_RefusedWhenAssetPolicyDenies() public {
        policy.setSubjectDenied(address(asset), true);

        expectRefusal(lp, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp);
        pool.withdraw(1_000e6, lp, lp);
    }

    function test_Withdraw_RefusedWhenProtocolPolicyDenies() public {
        validator.setRegistered(address(pool), true);
        validator.setPartyDenied(lp, true);

        expectRefusal(lp, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(lp);
        pool.withdraw(1_000e6, lp, lp);
    }

    function test_Withdraw_RefusedWhenPolicyReverts_FailsClosed() public {
        policy.setDown(true);

        expectRefusal(lp, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp);
        pool.withdraw(1_000e6, lp, lp);
    }

    function test_Redeem_RefusedWhenPolicyReverts_FailsClosed() public {
        policy.setDown(true);

        expectRefusal(lp, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp);
        pool.redeem(1_000e12, lp, lp);
    }

    /// @dev A third party redeeming on an owner's behalf is a party to the exit and is checked.
    function test_Withdraw_RefusedWhenTheSpenderIsUncredentialed() public {
        uint256 shares = pool.balanceOf(lp);
        vm.prank(lp);
        pool.approve(stranger, shares);

        expectRefusal(stranger, ComplianceGate.Refusal.NoCredential);
        vm.prank(stranger);
        pool.withdraw(1_000e6, lp, lp);
    }

    // ------------------------------------------------------------------ repayment leg

    function test_Repay_RefusedWhenPolicyReverts_FailsClosed() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);

        policy.setDown(true);

        expectRefusal(address(pool), ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(alice);
        manager.repay(loanId);
    }

    /// @dev The repay leg now checks the borrower as well, so a frozen borrower is stopped.
    function test_Repay_RefusedWhenBorrowerCredentialFrozen() public {
        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);

        apass.setStatus(alice, ApassReader.STATUS_FROZEN);

        expectRefusal(alice, ComplianceGate.Refusal.CredentialFrozen);
        vm.prank(alice);
        manager.repay(loanId);
    }

    // ------------------------------------------------------------------ credential decoding

    function test_CredentialOf_DecodesTheRegistryRecord() public view {
        ApassReader.Credential memory c = manager.credentialOf(alice);
        assertTrue(c.exists, "exists");
        assertEq(c.status, ApassReader.STATUS_ACTIVE, "status");
        assertEq(c.tier, 50, "tier");
        assertEq(c.subTier, 0, "subTier");
        assertEq(c.expiresAt, START_TS + ONE_YEAR, "expiry");
        assertEq(c.issuedAt, START_TS - ONE_YEAR, "issuedAt");
        assertEq(c.kycHash, KYC_ALICE, "kyc hash");
        assertEq(c.previousKycHash, bytes32(0), "never rotated");
    }

    function test_CredentialOf_ClampsOutOfRangeTierToNinetyNine() public {
        apass.setTier(alice, 250, 250);
        ApassReader.Credential memory c = manager.credentialOf(alice);
        assertEq(c.tier, 99, "tier clamped");
        assertEq(c.subTier, 99, "subTier clamped");
    }

    /// @dev The registry lays `group`/`subGroup` out left-aligned, which is what `bytes2(word)`
    ///      reads. Live confirmation on real data is in the fork suite.
    function test_CredentialOf_DecodesTheLeftAlignedGroupTags() public {
        apass.setGroups(alice, bytes2("RD"), bytes2("CD"));

        ApassReader.Credential memory c = manager.credentialOf(alice);
        assertEq(c.group, bytes2("RD"), "group");
        assertEq(c.subGroup, bytes2("CD"), "subGroup");
    }

    function test_CredentialOf_CarriesThePreviousKycHash() public {
        apass.rotateKycHash(alice, keccak256("kyc:alice:v2"));

        ApassReader.Credential memory c = manager.credentialOf(alice);
        assertEq(c.kycHash, keccak256("kyc:alice:v2"), "current");
        assertEq(c.previousKycHash, KYC_ALICE, "previous is no longer discarded");
    }
}
