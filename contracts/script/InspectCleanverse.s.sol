// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ApassReader} from "../src/libraries/ApassReader.sol";
import {ICleanversePolicy, ICleanverseAsset} from "../src/interfaces/ICleanverse.sol";

/// @notice Reproduces, against a live RPC, every claim docs/CLEANVERSE.md makes about the
///         Cleanverse stack's on-chain surface.
/// @dev Requires no credentials — it is all public state. Run it and read the output rather than
///      taking the documentation's word for any of it:
///
///      forge script script/InspectCleanverse.s.sol --rpc-url https://testnet-rpc.monad.xyz
contract InspectCleanverse is Script {
    address constant APASS = 0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9;
    address constant POLICY = 0x36489bE45fa84f70a0c2BDB11D824Be608CB12Dd;
    address constant AUSDC = 0xaC0893567D43C3E7e6e35a72803df05416C1f20D;

    /// @dev A wallet holding a live A-Pass, and one that holds none.
    address constant CREDENTIALED = 0x9E2816003da34Ea0E232Fb59A5e475Fce1121d98;
    address constant UNCREDENTIALED = 0xABc0000000000000000000000000000000000123;

    function run() external view {
        console.log("chain id                    %s", block.chainid);

        console.log("");
        console.log("-- wiring ------------------------------------------------");
        address policyOfAsset = ICleanverseAsset(AUSDC).policy();
        address apassOfPolicy = ICleanversePolicy(POLICY).apass();
        console.log("aUSDC.policy()              %s", policyOfAsset);
        console.log("  expected                  %s", POLICY);
        console.log("policy.apass()              %s", apassOfPolicy);
        console.log("  expected                  %s", APASS);
        console.log("aUSDC decimals              %s", ICleanverseAsset(AUSDC).decimals());
        console.log("aUSDC totalSupply           %s", ICleanverseAsset(AUSDC).totalSupply());
        console.log("policy.isTokenRegistered    %s", ICleanversePolicy(POLICY).isTokenRegistered(AUSDC));
        console.log("policy.isPaused             %s", ICleanversePolicy(POLICY).isPaused(AUSDC));

        console.log("");
        console.log("-- credential, read on-chain ------------------------------");
        ApassReader.Credential memory c = ApassReader.read(APASS, CREDENTIALED);
        console.log("holder                      %s", CREDENTIALED);
        console.log("  exists                    %s", c.exists);
        console.log("  status                    %s  (1 = active)", c.status);
        console.log("  tier / subTier            %s / %s", c.tier, c.subTier);
        console.log("  issuedAt                  %s", c.issuedAt);
        console.log("  expiresAt                 %s", c.expiresAt);
        console.log("  kycHash");
        console.logBytes32(c.kycHash);
        console.log("  previousKycHash");
        console.logBytes32(c.previousKycHash);

        ApassReader.Credential memory n = ApassReader.read(APASS, UNCREDENTIALED);
        console.log("holder                      %s", UNCREDENTIALED);
        console.log("  exists                    %s  (expected false)", n.exists);

        console.log("");
        console.log("-- the compliance verdict, as a view ----------------------");
        console.log("canTransfer(aUSDC, credentialed -> credentialed):");
        _report(AUSDC, CREDENTIALED, CREDENTIALED, 1e6);
        console.log("canTransfer(aUSDC, credentialed -> uncredentialed):");
        _report(AUSDC, CREDENTIALED, UNCREDENTIALED, 1e6);
        console.log("canTransfer(aUSDC, uncredentialed -> credentialed):");
        _report(AUSDC, UNCREDENTIALED, CREDENTIALED, 1e6);
        console.log("");
        console.log("A reverting verdict is the engine refusing an uncredentialed party, not an");
        console.log("outage. ComplianceGate treats it as a deny.");
    }

    function _report(address token, address from, address to, uint256 amount) private view {
        try ICleanversePolicy(POLICY).canTransfer(token, from, to, amount) returns (bool ok) {
            console.log("  -> returned %s", ok);
        } catch (bytes memory err) {
            console.log("  -> reverted, %s bytes of custom error:", err.length);
            console.logBytes(err);
        }
    }
}
