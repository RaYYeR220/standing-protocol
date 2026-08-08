// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITransferObserver {
    function onTransfer(address from, address to, uint256 amount) external;
}

interface IPreTransferObserver {
    function onBeforeTransfer(address from, address to, uint256 amount) external;
}

/// @title MockVerifiedAsset
/// @notice A Cleanverse Verified Asset stand-in: plain ERC-20, 6 decimals, `policy()` getter.
///
/// @dev The optional `observer` hook is off unless a test switches it on. It exists so the suite can
///      ask a question that a plain ERC-20 cannot: what does the rest of the protocol see *during* a
///      token movement? Cleanverse assets already make an external call to their policy contract on
///      transfer, so "this token never calls out" is not an assumption the protocol gets for free.
contract MockVerifiedAsset is ERC20 {
    address public policyAddress;
    address public observer;
    address public preObserver;
    bool private _inHook;

    constructor(address policy_) ERC20("Cleanverse Verified USDC", "aUSDC") {
        policyAddress = policy_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function policy() external view returns (address) {
        return policyAddress;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setObserver(address observer_) external {
        observer = observer_;
    }

    /// @notice A hook that runs BEFORE balances move.
    /// @dev This is the position a Cleanverse Verified Asset actually hands control away in: the
    ///      token consults its policy contract to decide whether the transfer may happen at all,
    ///      which is necessarily before it happens. Any protocol state that is inconsistent at that
    ///      instant is observable, and reachable, from inside the transfer.
    function setPreObserver(address observer_) external {
        preObserver = observer_;
    }

    function _update(address from, address to, uint256 value) internal override {
        address pre = preObserver;
        if (pre != address(0) && !_inHook) {
            _inHook = true;
            IPreTransferObserver(pre).onBeforeTransfer(from, to, value);
            _inHook = false;
        }
        super._update(from, to, value);
        address o = observer;
        if (o != address(0) && !_inHook) {
            _inHook = true;
            ITransferObserver(o).onTransfer(from, to, value);
            _inHook = false;
        }
    }
}
