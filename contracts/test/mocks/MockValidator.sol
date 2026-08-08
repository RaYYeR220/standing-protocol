// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICleanverseValidator} from "../../src/interfaces/ICleanverse.sol";

/// @title MockValidator
/// @notice A controllable stand-in for the Cleanverse compliance validator.
///
/// @dev The per-party verdict is answered by RAW SELECTOR through `fallback`, exactly as the live
///      validator is bound in `ComplianceGate` — selector `0xaf375463`, taking `(address subject,
///      address party)` and returning a single word. Answering it through a typed function would
///      stop the test exercising the encoding the contract actually uses.
contract MockValidator is ICleanverseValidator {
    bytes4 public constant VERIFY_SELECTOR = 0xaf375463;

    error ValidatorUnavailable();

    address public apassRegistry;
    address public tokenPolicyAddress;

    /// @notice Every call reverts — an unreachable validator.
    bool public down;

    /// @notice Only the per-party verdict reverts; `isRegistered` still answers.
    bool public verdictDown;

    /// @notice Return fewer than 32 bytes, i.e. a malformed verdict.
    bool public truncate;

    /// @notice Return a full word that is not a valid bool (e.g. 2).
    bool public dirtyBool;

    /// @notice Return more than one word, with a valid verdict in the first.
    bool public longPayload;

    mapping(address subject => bool) public registered;
    mapping(address party => bool) public partyDenied;

    constructor(address apassRegistry_, address tokenPolicy_) {
        apassRegistry = apassRegistry_;
        tokenPolicyAddress = tokenPolicy_;
    }

    // ------------------------------------------------------------------ ICleanverseValidator

    function isRegistered(address subject) external view returns (bool) {
        if (down) revert ValidatorUnavailable();
        return registered[subject];
    }

    function apass() external view returns (address) {
        if (down) revert ValidatorUnavailable();
        return apassRegistry;
    }

    function tokenPolicy() external view returns (address) {
        if (down) revert ValidatorUnavailable();
        return tokenPolicyAddress;
    }

    // ------------------------------------------------------------------ controls

    function setDown(bool v) external {
        down = v;
    }

    function setVerdictDown(bool v) external {
        verdictDown = v;
    }

    function setTruncate(bool v) external {
        truncate = v;
    }

    function setDirtyBool(bool v) external {
        dirtyBool = v;
    }

    function setLongPayload(bool v) external {
        longPayload = v;
    }

    function setRegistered(address subject, bool v) external {
        registered[subject] = v;
    }

    function setPartyDenied(address party, bool v) external {
        partyDenied[party] = v;
    }

    // ------------------------------------------------------------------ raw-selector verdict

    /// @dev Not `view`, because Solidity has no view fallback — but it writes nothing, so the
    ///      `staticcall` in `ComplianceGate._validatorAllows` succeeds against it.
    fallback(bytes calldata input) external returns (bytes memory) {
        if (down || verdictDown) revert ValidatorUnavailable();
        require(input.length >= 68, "validator: short calldata");

        bytes4 sel;
        uint256 party;
        assembly {
            sel := calldataload(0)
            party := calldataload(36)
        }
        require(sel == VERIFY_SELECTOR, "validator: unknown selector");

        if (truncate) return abi.encodePacked(bytes16(0));
        if (dirtyBool) return abi.encode(uint256(2));

        bool verdict = !partyDenied[address(uint160(party))];
        if (longPayload) return abi.encode(verdict, uint256(0xdeadbeef));
        return abi.encode(verdict);
    }
}
