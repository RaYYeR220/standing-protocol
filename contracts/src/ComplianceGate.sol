// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ApassReader} from "./libraries/ApassReader.sol";
import {ICleanversePolicy} from "./interfaces/ICleanverse.sol";

/// @title ComplianceGate
/// @notice The check every party and every movement of value in this protocol has to pass.
///
/// @dev The usual shape of "compliant DeFi" is a one-time KYC gate at the door: prove yourself
///      once, receive a permanent allowance, and transact unchecked forever after. That fails the
///      moment anything changes — a credential expires, an account is frozen, a jurisdiction rule
///      is updated — because nothing re-reads it.
///
///      Here the check runs inside the transaction that moves the money, against live state, every
///      time. Three conditions, all evaluated on-chain:
///
///        1. the party holds an A-Pass that is present, active and unexpired;
///        2. Cleanverse's policy engine permits the transfer under the asset's own rules;
///        3. if this protocol has been registered as a policy subject, its own rule set permits it too.
///
///      Condition 3 is what makes the protocol a first-class participant in the compliance system
///      rather than a consumer of it: an operator can tighten who may borrow or lend by changing a
///      rule at Cleanverse, and the contracts obey without being redeployed.
///
///      Every failure path denies. A policy call that reverts is treated as a refusal, not as an
///      inconclusive result to be retried or ignored — if compliance cannot be established, value
///      does not move.
abstract contract ComplianceGate {
    using ApassReader for ApassReader.Credential;

    /// @notice The Cleanverse A-Pass registry (CVI).
    address public immutable apassRegistry;

    /// @notice The Cleanverse policy engine (CCP).
    ICleanversePolicy public immutable policy;

    /// @notice The Cleanverse Verified Asset this protocol denominates everything in (CVA).
    address public immutable verifiedAsset;

    /// @notice Why a party or a transfer was refused.
    enum Refusal {
        None,
        NoCredential,
        CredentialFrozen,
        CredentialExpired,
        AssetPolicyDenied,
        ProtocolPolicyDenied
    }

    event ComplianceRefused(address indexed party, Refusal reason, uint256 amount);

    error NotCompliant(address party, Refusal reason);

    constructor(address apassRegistry_, address policy_, address verifiedAsset_) {
        apassRegistry = apassRegistry_;
        policy = ICleanversePolicy(policy_);
        verifiedAsset = verifiedAsset_;
    }

    /// @notice Reads the live credential of a party.
    function credentialOf(address party) public view returns (ApassReader.Credential memory) {
        return ApassReader.read(apassRegistry, party);
    }

    /// @notice Evaluates the full gate without reverting, so a UI can show a lender exactly which
    ///         condition a counterparty fails before anyone signs a transaction.
    function checkTransfer(address from, address to, uint256 amount)
        public
        view
        returns (bool allowed, Refusal reason)
    {
        ApassReader.Credential memory c = credentialOf(to);
        if (!c.exists) return (false, Refusal.NoCredential);
        if (c.status != ApassReader.STATUS_ACTIVE) return (false, Refusal.CredentialFrozen);
        if (c.expiresAt <= block.timestamp) return (false, Refusal.CredentialExpired);

        if (!_policyAllows(verifiedAsset, from, to, amount)) return (false, Refusal.AssetPolicyDenied);

        if (_isProtocolRegistered() && !_policyAllows(address(this), from, to, amount)) {
            return (false, Refusal.ProtocolPolicyDenied);
        }

        return (true, Refusal.None);
    }

    /// @notice Same as {checkTransfer} but reverts, for use on the path that actually moves value.
    function _requireCompliant(address from, address to, uint256 amount) internal {
        (bool allowed, Refusal reason) = checkTransfer(from, to, amount);
        if (!allowed) {
            emit ComplianceRefused(to, reason, amount);
            revert NotCompliant(to, reason);
        }
    }

    /// @dev Fails closed: an unreachable or reverting policy engine is a refusal.
    function _policyAllows(address subject, address from, address to, uint256 amount)
        private
        view
        returns (bool)
    {
        try policy.canTransfer(subject, from, to, amount) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    /// @dev Whether this protocol carries its own rule set at the policy engine. Registration is an
    ///      off-chain administrative act, so the contracts must work either way — unregistered they
    ///      still enforce the asset's rules, registered they additionally enforce the protocol's.
    function _isProtocolRegistered() private view returns (bool) {
        try policy.isTokenRegistered(address(this)) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
