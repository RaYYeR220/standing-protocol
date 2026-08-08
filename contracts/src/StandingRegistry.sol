// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title StandingRegistry
/// @notice The credit history of a verified identity.
///
/// @dev Every other on-chain reputation system keys off an address, which makes it worthless as
///      collateral: a borrower who defaults funds a fresh wallet and starts over. This registry
///      keys off the A-Pass `kycHash` — the hash of the bank-verified identity behind the
///      credential — so history follows the person, not the key they happen to hold.
///
///      That closes the obvious hole and opens a subtler one. Cleanverse re-issues a credential
///      with a *new* `kycHash` when a holder re-verifies, and the old hash is preserved only as
///      `previousKycHash` on the new record. A registry that ignored that field would let a
///      defaulter launder their record by re-doing KYC — the one escape route that would make the
///      whole protocol unsound. So identities are unioned: linking a new hash to the one it
///      superseded folds it into the same record, permanently.
///
///      Interpretation lives in StandingMath. This contract only records what happened, and only
///      the credit manager may write. The deployment script renounces admin, so the recorder set is
///      frozen at deployment and history cannot be forged after the fact.
contract StandingRegistry is AccessControl {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    /// @notice A repayment on a loan held for less than this does not count towards standing.
    /// @dev Without it, opening and closing a loan in the same block is free — dust rounds interest
    ///      and collateral to zero — and ten of them would buy the entire repayment component of the
    ///      score. Credit history has to cost time to acquire or it is not evidence of anything.
    uint256 public constant MIN_QUALIFYING_HOLD = 1 days;

    /// @param loansOriginated Loans ever drawn by this identity.
    /// @param loansRepaid Loans repaid in full after being held at least {MIN_QUALIFYING_HOLD}.
    /// @param loansDefaulted Loans that were written off.
    /// @param totalBorrowed Cumulative principal drawn, in asset units.
    /// @param totalRepaid Cumulative qualifying principal plus interest returned, in asset units.
    /// @param totalDefaulted Cumulative principal written off, in asset units.
    /// @param firstSeenAt Unix seconds of this identity's first origination.
    /// @param lastActivityAt Unix seconds of the most recent record.
    struct History {
        uint32 loansOriginated;
        uint32 loansRepaid;
        uint32 loansDefaulted;
        uint128 totalBorrowed;
        uint128 totalRepaid;
        uint128 totalDefaulted;
        uint64 firstSeenAt;
        uint64 lastActivityAt;
    }

    mapping(bytes32 identity => History) private _history;

    /// @notice Write-offs recorded against a wallet, independent of which identity it was acting for.
    /// @dev Identity is the right key for credit history and the wrong key for punishment, because
    ///      a credential can be re-issued and only one prior hash survives on the new record. A
    ///      borrower holding two lineages could commit the clean one first and strand the write-off
    ///      on a hash nothing resolves to again. The wallet cannot be re-issued, so a default also
    ///      sticks here — clearing it requires abandoning the wallet *and* re-verifying, which is a
    ///      far higher bar than rotating a credential.
    mapping(address wallet => uint32 defaults) public walletDefaults;

    /// @dev Union-find over KYC hashes: a re-issued credential points at the one it replaced.
    mapping(bytes32 identity => bytes32 supersedes) private _supersedes;

    /// @notice Wallets observed acting under a given identity, in first-seen order.
    /// @dev Kept for auditability — a default report has to name the wallets, not just the hash.
    mapping(bytes32 identity => address[]) private _wallets;
    mapping(bytes32 identity => mapping(address wallet => bool)) private _knownWallet;

    event LoanOriginated(bytes32 indexed identity, address indexed wallet, uint256 amount);
    event LoanRepaid(
        bytes32 indexed identity, address indexed wallet, uint256 principal, uint256 interest, bool qualifying
    );
    event LoanDefaulted(bytes32 indexed identity, address indexed wallet, uint256 principalLost);
    event WalletLinked(bytes32 indexed identity, address indexed wallet);
    event IdentityLinked(bytes32 indexed reissued, bytes32 indexed canonical);

    error InvalidIdentity();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------- identity

    /// @notice Resolves a KYC hash to the identity record it belongs to.
    /// @dev Follows the supersession chain. Bounded so a pathological chain cannot make reads
    ///      un-gas-able. Links written in the natural order are path-compressed to depth one, so
    ///      depth only grows when they arrive newest-first; the bound is set far above anything
    ///      that ordering can produce in practice, and a chain that did exceed it would resolve to
    ///      an intermediate identity rather than to nothing.
    uint256 public constant MAX_IDENTITY_DEPTH = 32;

    function canonicalIdentity(bytes32 kycHash) public view returns (bytes32) {
        bytes32 cur = kycHash;
        for (uint256 i = 0; i < MAX_IDENTITY_DEPTH; ++i) {
            bytes32 parent = _supersedes[cur];
            if (parent == bytes32(0) || parent == cur) break;
            cur = parent;
        }
        return cur;
    }

    /// @notice Folds a re-issued credential into the record of the credential it replaced.
    /// @dev Idempotent and one-way: once a hash is linked it cannot be re-pointed, so a link can
    ///      never be used to move an identity off its own history.
    function linkIdentity(bytes32 previousKycHash, bytes32 currentKycHash)
        external
        onlyRole(RECORDER_ROLE)
    {
        if (previousKycHash == bytes32(0) || currentKycHash == bytes32(0)) return;
        if (previousKycHash == currentKycHash) return;
        if (_supersedes[currentKycHash] != bytes32(0)) return;

        bytes32 canonical = canonicalIdentity(previousKycHash);
        if (canonical == currentKycHash) return; // would close a cycle

        _supersedes[currentKycHash] = canonical;
        _merge(currentKycHash, canonical);
        emit IdentityLinked(currentKycHash, canonical);
    }

    // ---------------------------------------------------------------- recording

    function recordOrigination(bytes32 kycHash, address wallet, uint256 amount)
        external
        onlyRole(RECORDER_ROLE)
    {
        bytes32 id = _require(kycHash);
        History storage h = _history[id];
        if (h.firstSeenAt == 0) h.firstSeenAt = uint64(block.timestamp);
        h.loansOriginated += 1;
        h.totalBorrowed += uint128(amount);
        h.lastActivityAt = uint64(block.timestamp);
        _link(id, wallet);
        emit LoanOriginated(id, wallet, amount);
    }

    /// @param heldSeconds How long the loan was outstanding. Repayments on loans held for less than
    ///        {MIN_QUALIFYING_HOLD} are recorded but do not count towards standing.
    function recordRepayment(
        bytes32 kycHash,
        address wallet,
        uint256 principal,
        uint256 interest,
        uint256 heldSeconds
    ) external onlyRole(RECORDER_ROLE) {
        bytes32 id = _require(kycHash);
        History storage h = _history[id];
        bool qualifying = heldSeconds >= MIN_QUALIFYING_HOLD;
        if (qualifying) {
            h.loansRepaid += 1;
            h.totalRepaid += uint128(principal + interest);
        }
        h.lastActivityAt = uint64(block.timestamp);
        emit LoanRepaid(id, wallet, principal, interest, qualifying);
    }

    function recordDefault(bytes32 kycHash, address wallet, uint256 principalLost)
        external
        onlyRole(RECORDER_ROLE)
    {
        bytes32 id = _require(kycHash);
        History storage h = _history[id];
        h.loansDefaulted += 1;
        h.totalDefaulted += uint128(principalLost);
        h.lastActivityAt = uint64(block.timestamp);
        if (wallet != address(0)) walletDefaults[wallet] += 1;
        _link(id, wallet);
        emit LoanDefaulted(id, wallet, principalLost);
    }

    // ---------------------------------------------------------------- views

    function historyOf(bytes32 kycHash) external view returns (History memory) {
        return _history[canonicalIdentity(kycHash)];
    }

    function walletsOf(bytes32 kycHash) external view returns (address[] memory) {
        return _wallets[canonicalIdentity(kycHash)];
    }

    function supersedes(bytes32 kycHash) external view returns (bytes32) {
        return _supersedes[kycHash];
    }

    // ---------------------------------------------------------------- internals

    function _require(bytes32 kycHash) private view returns (bytes32) {
        if (kycHash == bytes32(0)) revert InvalidIdentity();
        return canonicalIdentity(kycHash);
    }

    /// @dev Carries any record accrued under a hash before it was known to be a re-issue.
    function _merge(bytes32 from, bytes32 into) private {
        History storage a = _history[from];
        if (a.loansOriginated == 0 && a.loansDefaulted == 0 && a.loansRepaid == 0) return;
        History storage b = _history[into];
        b.loansOriginated += a.loansOriginated;
        b.loansRepaid += a.loansRepaid;
        b.loansDefaulted += a.loansDefaulted;
        b.totalBorrowed += a.totalBorrowed;
        b.totalRepaid += a.totalRepaid;
        b.totalDefaulted += a.totalDefaulted;
        if (b.firstSeenAt == 0 || (a.firstSeenAt != 0 && a.firstSeenAt < b.firstSeenAt)) {
            b.firstSeenAt = a.firstSeenAt;
        }
        if (a.lastActivityAt > b.lastActivityAt) b.lastActivityAt = a.lastActivityAt;

        address[] storage ws = _wallets[from];
        for (uint256 i = 0; i < ws.length; ++i) _link(into, ws[i]);

        delete _history[from];
    }

    function _link(bytes32 identity, address wallet) private {
        if (wallet == address(0) || _knownWallet[identity][wallet]) return;
        _knownWallet[identity][wallet] = true;
        _wallets[identity].push(wallet);
        emit WalletLinked(identity, wallet);
    }
}
