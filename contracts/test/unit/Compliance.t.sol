// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

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

        expectRefusal(alice, ComplianceGate.Refusal.NoCredential);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Borrow_RefusedWhenRegistryIsUnreachable() public {
        apass.setDown(true);

        expectRefusal(alice, ComplianceGate.Refusal.NoCredential);
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
        policy.setRegistered(address(manager), true);
        policy.setSubjectDenied(address(manager), true);

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
        policy.setRegistered(address(manager), false);
        policy.setSubjectDenied(address(manager), true);

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
        policy.setRegistrationLookupDown(true);

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        assertEq(manager.loan(loanId).principal, PRINCIPAL);
    }

    // ------------------------------------------------------------------ LP deposit: refusal paths

    function test_Deposit_RefusedWhenNoCredential() public {
        (bool allowed, ComplianceGate.Refusal reason) = pool.checkTransfer(address(pool), stranger, 0);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.NoCredential));

        assertEq(pool.maxDeposit(stranger), 0, "an unverified party may not hold a position");
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, stranger, 1e6, 0)
        );
        vm.prank(stranger);
        pool.deposit(1e6, stranger);
    }

    function test_Deposit_RefusedWhenCredentialFrozen() public {
        apass.setStatus(lp2, ApassReader.STATUS_FROZEN);

        (bool allowed, ComplianceGate.Refusal reason) = pool.checkTransfer(address(pool), lp2, 0);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialFrozen));
        assertEq(pool.maxDeposit(lp2), 0);
        assertEq(pool.maxMint(lp2), 0);
    }

    function test_Deposit_RefusedWhenCredentialExpired() public {
        apass.setExpiry(lp2, block.timestamp);

        (bool allowed, ComplianceGate.Refusal reason) = pool.checkTransfer(address(pool), lp2, 0);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.CredentialExpired));
        assertEq(pool.maxDeposit(lp2), 0);
    }

    /// @dev `maxDeposit` probes with `from = pool`, but `_deposit` checks with `from = caller`.
    ///      Denying only the caller therefore slips past the ceiling and reaches the gate itself,
    ///      which is where `NotCompliant` comes from.
    function test_Deposit_RefusedWithNotCompliantWhenCallerDeniedByAssetPolicy() public {
        policy.setPartyDenied(lp2, true);

        assertEq(pool.maxDeposit(lp), type(uint256).max, "receiver alone still looks fine");

        expectRefusal(lp, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp);
    }

    function test_Deposit_RefusedWithNotCompliantWhenProtocolPolicyDenies() public {
        policy.setRegistered(address(pool), true);
        policy.setSubjectDenied(address(pool), true);

        (bool allowed, ComplianceGate.Refusal reason) = pool.checkTransfer(lp2, lp2, 1_000e6);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.ProtocolPolicyDenied));

        // `maxDeposit` reports zero, so the ERC-4626 ceiling fires first.
        assertEq(pool.maxDeposit(lp2), 0);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, lp2, 1_000e6, 0)
        );
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
    }

    /// @dev Fail-closed on deposit: with the policy engine down, no capital enters. The gate's own
    ///      `NotCompliant` never surfaces because `maxDeposit` already collapsed to zero, so the
    ///      refusal reason is only observable through `checkTransfer`.
    function test_Deposit_RefusedWhenPolicyReverts_FailsClosed() public {
        policy.setDown(true);

        (bool allowed, ComplianceGate.Refusal reason) = pool.checkTransfer(lp2, lp2, 1_000e6);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.AssetPolicyDenied));

        assertEq(pool.maxDeposit(lp2), 0, "deposits closed while compliance cannot be established");
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, lp2, 1_000e6, 0)
        );
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
    }

    /// @dev The same, reached through `_deposit` so the gate's own error is the one that reverts:
    ///      the policy only objects once the amount is non-zero, which `maxDeposit` never probes.
    function test_Deposit_RefusedWithNotCompliantWhenPolicyOnlyDeniesNonZeroAmounts() public {
        policy.setDenyAtOrAbove(1);

        assertEq(pool.maxDeposit(lp2), type(uint256).max, "maxDeposit probes with amount 0 and passes");

        expectRefusal(lp2, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
    }

    function test_Mint_RefusedWithNotCompliantWhenPolicyOnlyDeniesNonZeroAmounts() public {
        policy.setDenyAtOrAbove(1);

        expectRefusal(lp2, ComplianceGate.Refusal.AssetPolicyDenied);
        vm.prank(lp2);
        pool.mint(1_000e6, lp2);
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
        policy.setRegistered(address(pool), true);
        policy.setSubjectDenied(address(pool), true);

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
        pool.redeem(1_000e6, lp, lp);
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
    }

    function test_CredentialOf_ClampsOutOfRangeTierToNinetyNine() public {
        apass.setTier(alice, 250, 250);
        ApassReader.Credential memory c = manager.credentialOf(alice);
        assertEq(c.tier, 99, "tier clamped");
        assertEq(c.subTier, 99, "subTier clamped");
    }

    function test_Gate_ChecksTheReceivingPartyOnly() public view {
        // `from` is never credential-checked. Documented here because several refusal paths in this
        // file depend on knowing it, and because it is the root of the withdrawal bypass in
        // KnownBugs.t.sol.
        (bool allowed,) = pool.checkTransfer(stranger, lp, 1e6);
        assertTrue(allowed, "an uncredentialed sender is not itself a refusal");
    }
}
