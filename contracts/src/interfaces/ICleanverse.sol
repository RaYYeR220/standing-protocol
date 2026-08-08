// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The Cleanverse compliance policy contract.
/// @dev Deployed at 0x36489bE45fa84f70a0c2BDB11D824Be608CB12Dd on Monad (and Base).
///      Reachable as `aUSDC.policy()`. This is the contract that decides, on-chain, whether a
///      transfer of a Cleanverse Verified Asset between two parties is allowed. Rules are attached
///      per registered contract, and are evaluated against the counterparties' A-Pass credentials.
///
///      Cleanverse publishes no ABI for this contract. The signatures below were recovered from the
///      deployed bytecode and confirmed against live calls on Monad testnet; see docs/CLEANVERSE.md.
interface ICleanversePolicy {
    /// @notice The compliance verdict, evaluated on-chain.
    /// @param token The registered token or contract whose rule set applies.
    /// @param from The sending party.
    /// @param to The receiving party.
    /// @param amount The transfer amount.
    function canTransfer(address token, address from, address to, uint256 amount)
        external
        view
        returns (bool);

    /// @notice Whether a specific account is frozen for a specific registered token.
    function isFrozen(address token, address account) external view returns (bool);

    /// @notice Whether all transfers of a registered token are paused.
    function isPaused(address token) external view returns (bool);

    /// @notice Whether a contract has been registered with the policy engine and carries rules.
    function isTokenRegistered(address token) external view returns (bool);

    /// @notice The A-Pass registry this policy evaluates credentials against.
    function apass() external view returns (address);
}

/// @notice The Cleanverse A-Pass registry — Cleanverse Verified Identity (CVI).
/// @dev Deployed at 0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9 on Monad (and Base).
///      A-Pass is a non-transferable ERC-721 credential whose `tokenId` is `uint160(holder)`.
interface ICleanverseApass {
    /// @notice The A-Pass token id bound to an account. Equal to `uint160(account)`.
    function getTokenId(address account) external view returns (uint256);

    /// @notice 1 if the account holds an A-Pass, 0 otherwise.
    function balanceOf(address owner) external view returns (uint256);

    function STATUS_UNINITIALIZED() external view returns (uint8);
    function STATUS_ACTIVE() external view returns (uint8);
    function STATUS_FREEZED() external view returns (uint8);
}

/// @notice Minimal ERC-20 surface used for Cleanverse Verified Assets (aUSDC).
interface ICleanverseAsset {
    function policy() external view returns (address);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
}
