// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../helpers/Fixture.sol";
import {ComplianceGate} from "../../src/ComplianceGate.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";

/// @title ValidatorGate
/// @notice Condition 4 of the gate: the protocol's own rule set, held by Cleanverse's validator.
///
/// @dev This is the condition that makes the protocol a policy subject rather than a policy consumer
///      — an operator changes a rule at Cleanverse and the contracts obey without a redeploy. It is
///      also the newest and least-exercised path, and it is bound by raw selector with a hand-rolled
///      staticcall, so it gets its own file.
contract ValidatorGateTest is Fixture {
    uint256 internal constant DEPOSIT = 50_000e6;
    uint256 internal constant PRINCIPAL = 5_000e6;
    uint256 internal constant TERM = 180 days;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    // ------------------------------------------------------------------ registration gates it

    function test_Validator_ProtocolIsUnregisteredByDefault() public view {
        assertFalse(pool.isProtocolRegistered(), "a fresh pool carries no rule set");
        assertFalse(manager.isProtocolRegistered(), "nor does the manager");
    }

    /// @dev Unregistered means the rule set does not apply, not that it denies. A validator that
    ///      would refuse everyone is irrelevant until the protocol is actually a subject.
    function test_Validator_RulesAreSkippedEntirelyWhenUnregistered() public {
        validator.setPartyDenied(alice, true);
        validator.setPartyDenied(address(pool), true);
        validator.setPartyDenied(lp, true);

        assertFalse(manager.isProtocolRegistered());

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        assertEq(manager.loan(loanId).principal, PRINCIPAL, "borrowing is unaffected");

        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);
        vm.prank(lp);
        pool.withdraw(1_000e6, lp, lp);
    }

    function test_Validator_RegisteringTurnsTheRuleSetOn() public {
        validator.setRegistered(address(manager), true);
        assertTrue(manager.isProtocolRegistered(), "now a policy subject");

        // Still allowed while the rules pass...
        (bool allowed,,) = manager.checkTransferDetailed(address(pool), alice, PRINCIPAL);
        assertTrue(allowed);

        // ...and refused the moment they do not, with no redeploy.
        validator.setPartyDenied(alice, true);
        (bool nowAllowed, ComplianceGate.Refusal reason, address party) =
            manager.checkTransferDetailed(address(pool), alice, PRINCIPAL);
        assertFalse(nowAllowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.ProtocolPolicyDenied));
        assertEq(party, alice);
    }

    // ------------------------------------------------------------------ both parties, named

    function test_Validator_DeniesTheSenderAndNamesTheSender() public {
        validator.setRegistered(address(pool), true);
        validator.setPartyDenied(lp2, true);

        (bool allowed, ComplianceGate.Refusal reason, address party) =
            pool.checkTransferDetailed(lp2, lp, 1_000e6);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.ProtocolPolicyDenied));
        assertEq(party, lp2, "the sender is the one that failed");

        expectRefusal(lp2, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp);
    }

    function test_Validator_DeniesTheRecipientAndNamesTheRecipient() public {
        validator.setRegistered(address(pool), true);
        validator.setPartyDenied(lp, true);

        (bool allowed, ComplianceGate.Refusal reason, address party) =
            pool.checkTransferDetailed(lp2, lp, 1_000e6);
        assertFalse(allowed);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.ProtocolPolicyDenied));
        assertEq(party, lp, "the recipient is the one that failed");

        expectRefusal(lp, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp);
    }

    /// @dev When both ends fail, the sender is reported: it is checked first, and a refusal has to
    ///      name one party deterministically or a front end cannot render it.
    function test_Validator_ReportsTheSenderWhenBothPartiesFail() public {
        validator.setRegistered(address(pool), true);
        validator.setPartyDenied(lp2, true);
        validator.setPartyDenied(lp, true);

        (,, address party) = pool.checkTransferDetailed(lp2, lp, 1_000e6);
        assertEq(party, lp2, "sender first, deterministically");
    }

    function test_Validator_DeniesTheBorrowerOnTheDisbursementLeg() public {
        validator.setRegistered(address(manager), true);
        validator.setPartyDenied(alice, true);

        expectRefusal(alice, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    /// @dev The pool is the sending party on a disbursement, so a rule that refuses the pool stops
    ///      lending even though the borrower is impeccable.
    function test_Validator_DeniesTheProtocolItselfAsAParty() public {
        validator.setRegistered(address(manager), true);
        validator.setPartyDenied(address(pool), true);

        expectRefusal(address(pool), ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    /// @dev Each contract is its own subject: registering the pool must not silently apply the
    ///      manager's rules or vice versa.
    function test_Validator_SubjectsAreIndependent() public {
        validator.setRegistered(address(pool), true);
        validator.setPartyDenied(alice, true);

        assertTrue(pool.isProtocolRegistered());
        assertFalse(manager.isProtocolRegistered(), "the manager is a separate subject");

        // Borrowing goes through the manager's gate, which carries no rules yet.
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    // ------------------------------------------------------------------ fail-closed

    function test_Validator_VerdictRevertIsARefusal() public {
        validator.setRegistered(address(manager), true);
        validator.setVerdictDown(true);

        (bool allowed, ComplianceGate.Refusal reason,) =
            manager.checkTransferDetailed(address(pool), alice, PRINCIPAL);
        assertFalse(allowed, "an unreachable verdict is a refusal");
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.ProtocolPolicyDenied));

        expectRefusal(address(pool), ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    function test_Validator_ShortReturnPayloadIsARefusal() public {
        validator.setRegistered(address(manager), true);
        validator.setTruncate(true);

        (bool allowed, ComplianceGate.Refusal reason,) =
            manager.checkTransferDetailed(address(pool), alice, PRINCIPAL);
        assertFalse(allowed, "half a word is not a verdict");
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.ProtocolPolicyDenied));
    }

    /// @dev A longer-than-a-word payload with a valid verdict in the first slot is honoured, so the
    ///      binding does not break if Cleanverse ever widens the return.
    function test_Validator_LongerReturnPayloadIsStillDecoded() public {
        validator.setRegistered(address(manager), true);
        validator.setLongPayload(true);

        (bool allowed,,) = manager.checkTransferDetailed(address(pool), alice, PRINCIPAL);
        assertTrue(allowed, "extra trailing data does not invalidate the verdict");

        validator.setPartyDenied(alice, true);
        (bool denied, ComplianceGate.Refusal reason,) =
            manager.checkTransferDetailed(address(pool), alice, PRINCIPAL);
        assertFalse(denied);
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.ProtocolPolicyDenied));
    }

    /// @dev BUG (medium). Every other external call in the gate is wrapped so a bad answer denies.
    ///      This one is a raw `staticcall` followed by a bare `abi.decode(ret, (bool))`, and the ABI
    ///      decoder *reverts* on a word that is neither 0 nor 1. So a validator that returns a dirty
    ///      word does not deny — it reverts the whole gate, including the `view` preflight a front
    ///      end calls. Every entry point becomes uncallable rather than refusing.
    /// @dev A verdict word that is neither 0 nor 1 has to deny, not explode. Decoding it as a bool
    ///      would revert inside the gate and escape, turning a malformed answer from Cleanverse into
    ///      an uncallable protocol — including the non-reverting preflight a front end relies on to
    ///      show a reason at all.
    function test_Fixed_DirtyBooleanFromTheValidatorDeniesInsteadOfReverting() public {
        validator.setRegistered(address(manager), true);
        validator.setDirtyBool(true);

        (bool allowed, ComplianceGate.Refusal reason, address party) =
            manager.checkTransferDetailed(address(pool), alice, PRINCIPAL);
        assertFalse(allowed, "a dirty verdict is not a permission");
        assertEq(uint8(reason), uint8(ComplianceGate.Refusal.ProtocolPolicyDenied));
        assertEq(party, address(pool), "the first party checked is named");

        expectRefusal(address(pool), ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);
    }

    /// @dev The registration lookup takes the opposite trade to the verdict, on purpose: an
    ///      unreachable *registration check* falls back to "unregistered" so a protocol with no
    ///      rules is not bricked by a Cleanverse outage, while an unreachable *verdict* denies.
    function test_Validator_RegistrationLookupRevertFallsBackToUnregistered() public {
        validator.setRegistered(address(manager), true);
        validator.setPartyDenied(alice, true);

        // With the validator reachable, the rule bites.
        expectRefusal(alice, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);

        // With it unreachable, the protocol keeps working under the asset's rules alone.
        validator.setDown(true);
        assertFalse(manager.isProtocolRegistered(), "reads as unregistered, not as denied");

        vm.prank(alice);
        uint256 loanId = manager.open(PRINCIPAL, TERM);
        assertEq(manager.loan(loanId).principal, PRINCIPAL, "availability over strictness");
    }

    /// @dev The consequence of that trade, stated so it is not a surprise: an operator who tightens
    ///      their rule set is relying on the validator being up. While it is down the tightening is
    ///      not enforced. `isProtocolRegistered()` is public so this is monitorable.
    function test_Validator_OutageSilentlyRelaxesATightenedRuleSet() public {
        validator.setRegistered(address(manager), true);
        validator.setPartyDenied(alice, true);
        assertTrue(manager.isProtocolRegistered(), "rules on");

        validator.setDown(true);
        assertFalse(manager.isProtocolRegistered(), "rules off, observably");

        vm.prank(alice);
        manager.open(PRINCIPAL, TERM); // a party the rule set refuses, borrowing anyway
    }

    // ------------------------------------------------------------------ consistency

    /// @dev The preflight and the enforcing path must never disagree: anything `checkTransfer`
    ///      allows, `_requireCompliant` must permit, and anything it refuses must revert.
    function testFuzz_PreflightAndEnforcementAlwaysAgree(
        uint8 mode,
        bool registerSubject,
        bool denySender,
        bool denyReceiver
    ) public {
        mode = uint8(bound(mode, 0, 4));
        validator.setRegistered(address(pool), registerSubject);
        validator.setPartyDenied(lp2, denySender);
        validator.setPartyDenied(lp, denyReceiver);

        if (mode == 1) apass.setStatus(lp2, ApassReader.STATUS_FROZEN);
        if (mode == 2) apass.setExpiry(lp, block.timestamp);
        if (mode == 3) policy.setPartyDenied(lp2, true);
        if (mode == 4) validator.setVerdictDown(true);

        (bool allowed, ComplianceGate.Refusal reason, address party) =
            pool.checkTransferDetailed(lp2, lp, 1_000e6);

        if (allowed) {
            assertEq(uint256(reason), uint256(ComplianceGate.Refusal.None), "no reason when allowed");
            assertEq(party, address(0), "and nobody to blame");
            vm.prank(lp2);
            pool.deposit(1_000e6, lp);
        } else {
            assertTrue(reason != ComplianceGate.Refusal.None, "a refusal always carries a reason");
            assertTrue(party != address(0), "and always names a party");
            expectRefusal(party, reason);
            vm.prank(lp2);
            pool.deposit(1_000e6, lp);
        }
    }

    /// @dev A refusal at condition 4 happens before any state moves, so nothing is half-applied:
    ///      no shares, no tokens, no registry write, no exposure.
    function test_Validator_RefusalAtConditionFourLeavesNoPartialState() public {
        validator.setRegistered(address(manager), true);
        validator.setPartyDenied(alice, true);

        uint256 aliceBalBefore = asset.balanceOf(alice);
        uint256 poolBalBefore = asset.balanceOf(address(pool));

        expectRefusal(alice, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(alice);
        manager.open(PRINCIPAL, TERM);

        assertEq(asset.balanceOf(alice), aliceBalBefore, "no collateral taken");
        assertEq(asset.balanceOf(address(pool)), poolBalBefore, "no principal paid out");
        assertEq(asset.balanceOf(address(manager)), 0, "no custody");
        assertEq(manager.loanCount(), 0, "no loan booked");
        assertEq(manager.drawnByIdentity(KYC_ALICE), 0, "no exposure");
        assertEq(pool.outstandingPrincipal(), 0, "no pool book entry");
        assertEq(historyOf(KYC_ALICE).loansOriginated, 0, "no registry write");
    }

    /// @dev Condition 3 passing and condition 4 failing is the interesting ordering, because the
    ///      asset policy has already said yes. It must still be a clean refusal.
    function test_Validator_ConditionThreePassesAndConditionFourRefusesCleanly() public {
        validator.setRegistered(address(pool), true);
        validator.setPartyDenied(lp2, true);

        // The asset's own rules are perfectly happy with this transfer.
        assertTrue(policy.canTransfer(address(asset), lp2, lp2, 1_000e6), "condition 3 passes");

        uint256 supplyBefore = pool.totalSupply();
        expectRefusal(lp2, ComplianceGate.Refusal.ProtocolPolicyDenied);
        vm.prank(lp2);
        pool.deposit(1_000e6, lp2);

        assertEq(pool.totalSupply(), supplyBefore, "no shares minted");
        assertEq(pool.balanceOf(lp2), 0);
    }
}
