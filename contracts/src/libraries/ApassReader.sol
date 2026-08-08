// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ApassReader
/// @notice Reads a Cleanverse A-Pass credential directly from the on-chain registry.
///
/// @dev Cleanverse documents A-Pass only as a REST resource: you POST a wallet address to
///      `/query_apass` and their server answers with the credential's attributes. That makes the
///      credential unusable inside a transaction — a contract cannot call a REST API, so any
///      protocol built that way has to trust an off-chain relayer to report identity honestly.
///
///      The registry is a real contract, and it exposes the attributes as a view. Cleanverse
///      publishes no ABI for it, so the getter below is bound by raw selector: `0x6a069f61`, taking
///      the A-Pass token id (which is `uint160(holder)`) and returning ten words. The layout was
///      recovered by decoding live registry state and checking it word-for-word against the REST
///      response for the same wallet — status, tier, expiry and KYC hash all match exactly.
///      See docs/CLEANVERSE.md for the derivation and its limits.
///
///      Reading identity here rather than from an API is what lets the protocol enforce, rather
///      than merely record, the identity requirements of an under-collateralized loan.
library ApassReader {
    /// @dev Raw selector of the attribute getter on the A-Pass registry. The function's source-level
    ///      name is not published; only its selector and return layout are observable on-chain.
    bytes4 internal constant ATTRIBUTES_SELECTOR = 0x6a069f61;

    uint8 internal constant STATUS_UNINITIALIZED = 0;
    uint8 internal constant STATUS_ACTIVE = 1;
    uint8 internal constant STATUS_FROZEN = 2;

    /// @notice A decoded A-Pass credential.
    /// @param exists Whether the registry returned a well-formed record at all.
    /// @param status 0 uninitialized, 1 active, 2 frozen.
    /// @param tier Verification tier, 0-99. Set by the issuing institution.
    /// @param subTier Institution-defined sub-tier, 0-99.
    /// @param group Institution-defined group tag.
    /// @param subGroup Institution-defined sub-group tag.
    /// @param expiresAt Unix seconds after which the credential is no longer valid.
    /// @param issuedAt Unix seconds the credential was issued or last updated.
    /// @param kycHash Hash of the underlying bank-verified identity — the anchor this protocol
    ///        keys reputation to.
    /// @param previousKycHash The hash this credential superseded, or zero if it never rotated.
    ///        Cleanverse re-issues a credential with a fresh `kycHash` when the holder re-verifies,
    ///        and this field is the only link back. Without it a borrower could shed a default
    ///        simply by re-doing KYC, so the protocol reads it and stitches the identities together.
    struct Credential {
        bool exists;
        uint8 status;
        uint8 tier;
        uint8 subTier;
        bytes2 group;
        bytes2 subGroup;
        uint64 expiresAt;
        uint64 issuedAt;
        bytes32 kycHash;
        bytes32 previousKycHash;
    }

    /// @notice Reads and decodes the A-Pass credential bound to `account`.
    /// @param registry The A-Pass registry address.
    /// @param account The wallet whose credential to read.
    /// @dev Never reverts: a missing or malformed record comes back as `exists == false` so callers
    ///      can treat "no credential" as an ordinary deny rather than an exception.
    function read(address registry, address account) internal view returns (Credential memory c) {
        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeWithSelector(ATTRIBUTES_SELECTOR, uint256(uint160(account))));

        // Ten 32-byte words. Anything shorter is not a credential record.
        if (!ok || ret.length < 320) return c;

        (
            uint256 status,
            uint256 tier,
            uint256 subTier,
            bytes32 group,
            bytes32 subGroup,
            uint256 expiresAt,
            uint256 issuedAt,
            bytes32 previousKycHash,
            bytes32 kycHash,
        ) = abi.decode(
            ret,
            (uint256, uint256, uint256, bytes32, bytes32, uint256, uint256, bytes32, bytes32, bytes32)
        );

        // A record that has never been written reads as all-zero.
        if (status == STATUS_UNINITIALIZED && expiresAt == 0 && kycHash == bytes32(0)) return c;

        c.exists = true;
        c.status = status > type(uint8).max ? type(uint8).max : uint8(status);
        c.tier = tier > 99 ? 99 : uint8(tier);
        c.subTier = subTier > 99 ? 99 : uint8(subTier);
        c.group = bytes2(group);
        c.subGroup = bytes2(subGroup);
        c.expiresAt = expiresAt > type(uint64).max ? type(uint64).max : uint64(expiresAt);
        c.issuedAt = issuedAt > type(uint64).max ? type(uint64).max : uint64(issuedAt);
        c.kycHash = kycHash;
        c.previousKycHash = previousKycHash;
    }

    /// @notice Whether a credential is currently usable: present, active, and not expired.
    function isLive(Credential memory c, uint256 nowTs) internal pure returns (bool) {
        return c.exists && c.status == STATUS_ACTIVE && c.expiresAt > nowTs;
    }
}
