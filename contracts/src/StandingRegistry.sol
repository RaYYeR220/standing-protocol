// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title StandingRegistry
/// @notice The credit history of a verified identity.
///
/// @dev Every other on-chain reputation system keys off an address, which makes it worthless as
///      collateral: a borrower who defaults funds a fresh wallet and starts over. This registry
///      keys off the A-Pass `kycHash` — the hash of the bank-verified identity behind the
///      credential — so history follows the person, not the key they happen to hold. Moving to a
///      new wallet carries the record over; walking away from a default does not shed it.
///
///      That is the whole basis on which this protocol lends without collateral, so the registry is
///      deliberately dumb: it records what happened and nothing else. Interpretation lives in
///      StandingMath, and only the credit manager may write.
contract StandingRegistry is AccessControl {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    /// @param loansOriginated Loans ever drawn by this identity.
    /// @param loansRepaid Loans repaid in full.
    /// @param loansDefaulted Loans that were written off.
    /// @param totalBorrowed Cumulative principal drawn, in asset units.
    /// @param totalRepaid Cumulative principal plus interest returned, in asset units.
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

    mapping(bytes32 kycHash => History) private _history;

    /// @notice Wallets observed acting under a given identity, in first-seen order.
    /// @dev Kept for auditability — a default report has to name the wallets, not just the hash.
    mapping(bytes32 kycHash => address[]) private _wallets;
    mapping(bytes32 kycHash => mapping(address wallet => bool)) private _knownWallet;

    event LoanOriginated(bytes32 indexed kycHash, address indexed wallet, uint256 amount);
    event LoanRepaid(bytes32 indexed kycHash, address indexed wallet, uint256 principal, uint256 interest);
    event LoanDefaulted(bytes32 indexed kycHash, address indexed wallet, uint256 principalLost);
    event WalletLinked(bytes32 indexed kycHash, address indexed wallet);

    error InvalidIdentity();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function recordOrigination(bytes32 kycHash, address wallet, uint256 amount)
        external
        onlyRole(RECORDER_ROLE)
    {
        if (kycHash == bytes32(0)) revert InvalidIdentity();
        History storage h = _history[kycHash];
        if (h.firstSeenAt == 0) h.firstSeenAt = uint64(block.timestamp);
        h.loansOriginated += 1;
        h.totalBorrowed += uint128(amount);
        h.lastActivityAt = uint64(block.timestamp);
        _link(kycHash, wallet);
        emit LoanOriginated(kycHash, wallet, amount);
    }

    function recordRepayment(bytes32 kycHash, address wallet, uint256 principal, uint256 interest)
        external
        onlyRole(RECORDER_ROLE)
    {
        if (kycHash == bytes32(0)) revert InvalidIdentity();
        History storage h = _history[kycHash];
        h.loansRepaid += 1;
        h.totalRepaid += uint128(principal + interest);
        h.lastActivityAt = uint64(block.timestamp);
        emit LoanRepaid(kycHash, wallet, principal, interest);
    }

    function recordDefault(bytes32 kycHash, address wallet, uint256 principalLost)
        external
        onlyRole(RECORDER_ROLE)
    {
        if (kycHash == bytes32(0)) revert InvalidIdentity();
        History storage h = _history[kycHash];
        h.loansDefaulted += 1;
        h.totalDefaulted += uint128(principalLost);
        h.lastActivityAt = uint64(block.timestamp);
        emit LoanDefaulted(kycHash, wallet, principalLost);
    }

    function historyOf(bytes32 kycHash) external view returns (History memory) {
        return _history[kycHash];
    }

    function walletsOf(bytes32 kycHash) external view returns (address[] memory) {
        return _wallets[kycHash];
    }

    function _link(bytes32 kycHash, address wallet) private {
        if (wallet == address(0) || _knownWallet[kycHash][wallet]) return;
        _knownWallet[kycHash][wallet] = true;
        _wallets[kycHash].push(wallet);
        emit WalletLinked(kycHash, wallet);
    }
}
