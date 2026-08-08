// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICleanversePolicy} from "../../src/interfaces/ICleanverse.sol";

/// @title MockPolicy
/// @notice A controllable stand-in for the Cleanverse policy engine (CCP).
///
/// @dev Models every shape the live engine was observed to take on Monad testnet:
///        - `canTransfer` returning true for two credentialed parties;
///        - `canTransfer` REVERTING (custom error, not `false`) when a counterparty is unacceptable —
///          the live engine at 0x36489bE4… does exactly this for an address with no A-Pass;
///        - `isTokenRegistered` true for aUSDC, false for an unregistered contract.
///
///      `down` makes every call revert, which is the case the gate has to fail closed on.
contract MockPolicy is ICleanversePolicy {
    error PolicyUnavailable();
    error PolicyRefusal(address party);

    address public apassRegistry;

    /// @notice Every call reverts — an unreachable or broken policy engine.
    bool public down;

    /// @notice Only `isTokenRegistered` reverts.
    bool public registrationLookupDown;

    /// @notice Refuse by reverting rather than by returning false, as the live engine does.
    bool public revertInsteadOfDeny;

    mapping(address subject => bool) public subjectDenied;
    mapping(address party => bool) public partyDenied;
    mapping(address subject => bool) public registered;
    mapping(address subject => mapping(address party => bool)) private _frozen;
    mapping(address subject => bool) private _paused;

    /// @notice When non-zero, transfers of at least this size are denied.
    /// @dev Lets a test separate the `amount == 0` probe `maxDeposit` makes from the real
    ///      `amount == assets` check `_deposit` makes.
    uint256 public denyAtOrAbove;

    constructor(address apassRegistry_) {
        apassRegistry = apassRegistry_;
    }

    // ------------------------------------------------------------------ ICleanversePolicy

    function canTransfer(address token, address from, address to, uint256 amount)
        external
        view
        returns (bool)
    {
        if (down) revert PolicyUnavailable();

        bool ok = true;
        if (subjectDenied[token]) ok = false;
        if (partyDenied[from] || partyDenied[to]) ok = false;
        if (_paused[token]) ok = false;
        if (_frozen[token][from] || _frozen[token][to]) ok = false;
        if (denyAtOrAbove != 0 && amount >= denyAtOrAbove) ok = false;

        if (!ok && revertInsteadOfDeny) revert PolicyRefusal(to);
        return ok;
    }

    function isFrozen(address token, address account) external view returns (bool) {
        if (down) revert PolicyUnavailable();
        return _frozen[token][account];
    }

    function isPaused(address token) external view returns (bool) {
        if (down) revert PolicyUnavailable();
        return _paused[token];
    }

    function isTokenRegistered(address token) external view returns (bool) {
        if (down || registrationLookupDown) revert PolicyUnavailable();
        return registered[token];
    }

    function apass() external view returns (address) {
        if (down) revert PolicyUnavailable();
        return apassRegistry;
    }

    // ------------------------------------------------------------------ controls

    function setDown(bool v) external {
        down = v;
    }

    function setRegistrationLookupDown(bool v) external {
        registrationLookupDown = v;
    }

    function setRevertInsteadOfDeny(bool v) external {
        revertInsteadOfDeny = v;
    }

    function setSubjectDenied(address subject, bool v) external {
        subjectDenied[subject] = v;
    }

    function setPartyDenied(address party, bool v) external {
        partyDenied[party] = v;
    }

    function setRegistered(address subject, bool v) external {
        registered[subject] = v;
    }

    function setFrozen(address subject, address party, bool v) external {
        _frozen[subject][party] = v;
    }

    function setPaused(address subject, bool v) external {
        _paused[subject] = v;
    }

    function setDenyAtOrAbove(uint256 v) external {
        denyAtOrAbove = v;
    }
}
