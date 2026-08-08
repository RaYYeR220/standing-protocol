// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockApass
/// @notice A faithful stand-in for the Cleanverse A-Pass registry.
///
/// @dev Deliberately answers the attribute getter by RAW SELECTOR through `fallback`, exactly as the
///      live registry at 0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9 does, so `ApassReader` is
///      exercised for real — selector, calldata shape, ten-word return layout and all — rather than
///      stubbed behind a typed interface.
///
///      Behaviours copied from live Monad testnet state (probed at block ~51.87M):
///        - `0x6a069f61(uint256 tokenId)` where `tokenId == uint160(holder)`;
///        - ten 32-byte words: status, tier, subTier, group, subGroup, expiresAt, issuedAt,
///          previousKycHash, currentKycHash, countries;
///        - `group`, `subGroup` and `countries` are LEFT-aligned (`bytes`-like); the numeric fields
///          and the KYC hashes are plain words. Verified against tokenId 57005 on Monad testnet,
///          whose subGroup word reads 5244000…000 -- i.e. `bytes2(word) == "RD"`;
///        - an unknown holder makes the registry REVERT with a custom error rather than return
///          zeroes. `ApassReader` has to treat that as "no credential", so that is the default here.
contract MockApass {
    /// @dev The undocumented attribute getter. Same constant `ApassReader` binds against.
    bytes4 public constant ATTRIBUTES_SELECTOR = 0x6a069f61;

    struct Record {
        uint256 status;
        uint256 tier;
        uint256 subTier;
        bytes32 group;
        bytes32 subGroup;
        uint256 expiresAt;
        uint256 issuedAt;
        bytes32 previousKycHash;
        bytes32 currentKycHash;
        bytes32 countries;
        bool present;
    }

    mapping(address holder => Record) private _records;

    /// @notice When true an unknown holder gets an all-zero record instead of a revert.
    /// @dev The live registry reverts; both branches of `ApassReader.read` must yield exists == false.
    bool public zeroForUnknown;

    /// @notice Registry-wide outage: every read reverts.
    bool public down;

    /// @notice Return fewer than ten words, i.e. a malformed record.
    bool public truncate;

    error ApassNonexistentToken(uint256 tokenId);
    error ApassRegistryDown();

    // ------------------------------------------------------------------ issuance (test-only)

    function issue(
        address holder,
        uint256 status,
        uint256 tier,
        uint256 subTier,
        uint256 expiresAt,
        uint256 issuedAt,
        bytes32 kycHash
    ) external {
        Record storage r = _records[holder];
        r.status = status;
        r.tier = tier;
        r.subTier = subTier;
        r.expiresAt = expiresAt;
        r.issuedAt = issuedAt;
        r.currentKycHash = kycHash;
        r.present = true;
    }

    function issueFull(address holder, Record calldata r) external {
        _records[holder] = r;
        _records[holder].present = true;
    }

    function setStatus(address holder, uint256 status) external {
        _records[holder].status = status;
    }

    function setExpiry(address holder, uint256 expiresAt) external {
        _records[holder].expiresAt = expiresAt;
    }

    function setTier(address holder, uint256 tier, uint256 subTier) external {
        _records[holder].tier = tier;
        _records[holder].subTier = subTier;
    }

    /// @notice Sets the institution tags using the registry's real left-aligned encoding.
    /// @dev `bytes32(bytes2)` pads on the right, which is exactly how the live registry lays these
    ///      out. Encoding them any other way would make the mock disagree with the chain.
    function setGroups(address holder, bytes2 group, bytes2 subGroup) external {
        _records[holder].group = bytes32(group);
        _records[holder].subGroup = bytes32(subGroup);
    }

    /// @notice Sets `previousKycHash` without touching the current one.
    /// @dev Lets a test craft a credential that claims to supersede an arbitrary identity, which is
    ///      the shape of a compromised or mis-issued A-Pass.
    function setPreviousKycHash(address holder, bytes32 previous) external {
        _records[holder].previousKycHash = previous;
    }

    /// @notice Re-issues the credential under a new KYC hash, keeping the old one as `previous`.
    /// @dev The live registry really does carry a `previousKycHash`; address 0x…dEaD on Monad
    ///      testnet has a non-zero one today. Rotation is a thing that happens.
    function rotateKycHash(address holder, bytes32 newHash) external {
        Record storage r = _records[holder];
        r.previousKycHash = r.currentKycHash;
        r.currentKycHash = newHash;
    }

    function revoke(address holder) external {
        delete _records[holder];
    }

    function setZeroForUnknown(bool v) external {
        zeroForUnknown = v;
    }

    function setDown(bool v) external {
        down = v;
    }

    function setTruncate(bool v) external {
        truncate = v;
    }

    function recordOf(address holder) external view returns (Record memory) {
        return _records[holder];
    }

    // ------------------------------------------------------------------ documented surface

    function getTokenId(address account) external pure returns (uint256) {
        return uint256(uint160(account));
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _records[owner].present ? 1 : 0;
    }

    function STATUS_UNINITIALIZED() external pure returns (uint8) {
        return 0;
    }

    function STATUS_ACTIVE() external pure returns (uint8) {
        return 1;
    }

    function STATUS_FREEZED() external pure returns (uint8) {
        return 2;
    }

    // ------------------------------------------------------------------ raw-selector getter

    /// @dev Not `view`, because Solidity has no view fallback — but it writes nothing, so the
    ///      `staticcall` inside `ApassReader.read` succeeds against it just like the real registry.
    fallback(bytes calldata input) external returns (bytes memory) {
        if (down) revert ApassRegistryDown();
        require(input.length >= 36, "apass: short calldata");

        bytes4 sel;
        uint256 tokenId;
        assembly {
            sel := calldataload(0)
            tokenId := calldataload(4)
        }
        require(sel == ATTRIBUTES_SELECTOR, "apass: unknown selector");

        Record memory r = _records[address(uint160(tokenId))];
        if (!r.present && !zeroForUnknown) revert ApassNonexistentToken(tokenId);
        if (truncate) return abi.encode(r.status, r.tier, r.subTier);

        return abi.encode(
            r.status,
            r.tier,
            r.subTier,
            r.group,
            r.subGroup,
            r.expiresAt,
            r.issuedAt,
            r.previousKycHash,
            r.currentKycHash,
            r.countries
        );
    }
}
