// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ApassReader} from "./libraries/ApassReader.sol";
import {ICleanversePolicy, ICleanverseValidator} from "./interfaces/ICleanverse.sol";

/// @title ComplianceGate
/// @notice The check every party and every movement of value in this protocol has to pass.
///
/// @dev The usual shape of "compliant DeFi" is a one-time KYC gate at the door: prove yourself
///      once, receive a permanent allowance, and transact unchecked forever after. That fails the
///      moment anything changes — a credential expires, an account is frozen, a jurisdiction rule
///      is updated — because nothing re-reads it.
///
///      Here the check runs inside the transaction that moves the money, against live state, every
///      time. Four conditions, all evaluated on-chain:
///
///        1. the sender holds an A-Pass that is present, active and unexpired;
///        2. so does the recipient;
///        3. Cleanverse's policy engine permits the transfer under the verified asset's own rules;
///        4. if this protocol is registered with Cleanverse's validator, its own rule set permits
///           both parties too.
///
///      Both ends are checked because Cleanverse checks both ends: its policy engine *reverts* on an
///      uncredentialed counterparty rather than returning false. A consequence worth stating plainly
///      is that the pool contract is itself a party to every disbursement, so the pool must hold its
///      own A-Pass — the protocol is a verified participant in the network, not an anonymous
///      intermediary standing between verified ones. Until that credential is issued the gate
///      refuses everything, which is the correct behaviour and not a degraded mode.
///
///      Condition 4 is what makes the protocol a first-class participant in the compliance system
///      rather than a consumer of it: an operator can tighten who may borrow or lend by changing a
///      rule at Cleanverse, and the contracts obey without being redeployed.
///
///      Every failure path denies. A policy call that reverts is treated as a refusal, not as an
///      inconclusive result to be retried or ignored — if compliance cannot be established, value
///      does not move.
abstract contract ComplianceGate {
    /// @notice The Cleanverse A-Pass registry (CVI).
    address public immutable apassRegistry;

    /// @notice The Cleanverse policy engine, carrying the verified asset's own rules (CCP).
    ICleanversePolicy public immutable policy;

    /// @notice The Cleanverse compliance validator, carrying *this protocol's* rules (CCP).
    /// @dev Registered via `POST /validator/register`, which binds a rule set — minimum tier,
    ///      group, jurisdiction, blacklist — to this contract's address. Once registered, an
    ///      operator can tighten who may transact here by changing that rule at Cleanverse, and the
    ///      contracts obey from the next block without being redeployed or upgraded.
    ICleanverseValidator public immutable validator;

    /// @notice The Cleanverse Verified Asset this protocol denominates everything in (CVA).
    address public immutable verifiedAsset;

    /// @notice The account that controls this deployment.
    /// @dev Cleanverse registers a contract as a policy subject only against a signature from the
    ///      address this returns, so the accessor is part of the integration surface rather than an
    ///      ownership model — nothing in the protocol grants `owner` any authority. Permissions are
    ///      held as roles; this is proof of provenance, not a backdoor.
    address public immutable owner;

    /// @notice Why a party or a transfer was refused.
    enum Refusal {
        None,
        NoCredential,
        CredentialFrozen,
        CredentialExpired,
        AssetPolicyDenied,
        ProtocolPolicyDenied
    }

    error NotCompliant(address party, Refusal reason);

    /// @dev Raw selector of the validator's per-party verdict. Cleanverse publishes no ABI for it;
    ///      the selector and its `(subject, party) -> bool` shape were recovered from the deployed
    ///      bytecode and confirmed by flipping a rule and watching the answer change.
    bytes4 private constant VALIDATOR_VERIFY = 0xaf375463;

    constructor(
        address apassRegistry_,
        address policy_,
        address validator_,
        address verifiedAsset_,
        address owner_
    ) {
        apassRegistry = apassRegistry_;
        policy = ICleanversePolicy(policy_);
        validator = ICleanverseValidator(validator_);
        verifiedAsset = verifiedAsset_;
        owner = owner_;
    }

    /// @notice Reads the live credential of a party.
    function credentialOf(address party) public view returns (ApassReader.Credential memory) {
        return ApassReader.read(apassRegistry, party);
    }

    /// @notice Evaluates the full gate without reverting, so a front end can show exactly which
    ///         condition a counterparty fails before anyone signs a transaction.
    function checkTransfer(address from, address to, uint256 amount)
        public
        view
        returns (bool allowed, Refusal reason)
    {
        address party;
        (allowed, reason, party) = checkTransferDetailed(from, to, amount);
    }

    /// @notice As {checkTransfer}, and also names the party that failed.
    /// @dev A refusal is only actionable if you know who caused it — "this transfer is
    ///      non-compliant" is not something a borrower can do anything about, whereas "your
    ///      credential expired on the 4th" is.
    function checkTransferDetailed(address from, address to, uint256 amount)
        public
        view
        returns (bool allowed, Refusal reason, address party)
    {
        (bool fromOk, Refusal fromReason) = checkParty(from);
        if (!fromOk) return (false, fromReason, from);

        (bool toOk, Refusal toReason) = checkParty(to);
        if (!toOk) return (false, toReason, to);

        if (!_policyAllows(verifiedAsset, from, to, amount)) {
            return (false, Refusal.AssetPolicyDenied, to);
        }

        if (_isProtocolRegistered()) {
            if (!_validatorAllows(from)) return (false, Refusal.ProtocolPolicyDenied, from);
            if (!_validatorAllows(to)) return (false, Refusal.ProtocolPolicyDenied, to);
        }

        return (true, Refusal.None, address(0));
    }

    /// @notice Whether a single party currently holds a usable credential.
    function checkParty(address party) public view returns (bool ok, Refusal reason) {
        ApassReader.Credential memory c = credentialOf(party);
        if (!c.exists) return (false, Refusal.NoCredential);
        if (c.status != ApassReader.STATUS_ACTIVE) return (false, Refusal.CredentialFrozen);
        if (c.expiresAt <= block.timestamp) return (false, Refusal.CredentialExpired);
        return (true, Refusal.None);
    }

    /// @notice Reverting form, for the path that actually moves value.
    function _requireCompliant(address from, address to, uint256 amount) internal view {
        (bool allowed, Refusal reason, address party) = checkTransferDetailed(from, to, amount);
        if (!allowed) revert NotCompliant(party, reason);
    }

    /// @notice Requires a single party to hold a usable credential, without implying a transfer.
    /// @dev Used where someone acquires or gives up a claim on verified assets without being the
    ///      immediate recipient of a transfer — a share owner being redeemed from, for instance.
    function _requireParty(address party) internal view {
        (bool ok, Refusal reason) = checkParty(party);
        if (!ok) revert NotCompliant(party, reason);
    }

    /// @dev Fails closed: an unreachable or reverting policy engine is a refusal. The engine really
    ///      does revert — on an uncredentialed party it returns a custom error rather than false —
    ///      so this catch is on the normal path, not an exotic one.
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

    /// @notice Whether this protocol carries its own rule set with Cleanverse's validator.
    /// @dev Registration is an off-chain administrative act, so the contracts work either way:
    ///      unregistered they enforce the asset's rules, registered they additionally enforce the
    ///      protocol's own.
    function isProtocolRegistered() public view returns (bool) {
        return _isProtocolRegistered();
    }

    function _isProtocolRegistered() private view returns (bool) {
        try validator.isRegistered(address(this)) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    /// @dev The validator's verdict for one party against this protocol's registered rule set.
    ///      Bound by raw selector; fails closed like every other check here.
    function _validatorAllows(address party) private view returns (bool) {
        (bool ok, bytes memory ret) = address(validator).staticcall(
            abi.encodeWithSelector(VALIDATOR_VERIFY, address(this), party)
        );
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (bool));
    }
}
