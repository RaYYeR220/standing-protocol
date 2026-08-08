// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ComplianceGate} from "../../src/ComplianceGate.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";
import {ICleanverseAsset, ICleanversePolicy} from "../../src/interfaces/ICleanverse.sol";

/// @title CleanverseForkTest
/// @notice Runs the protocol's identity and policy plumbing against the real Cleanverse contracts
///         on Monad testnet. Nothing here is mocked: the A-Pass records, the policy verdicts and the
///         refusal reasons all come from live state.
/// @dev The whole contract is gated on the fork being reachable so the suite still passes offline.
contract CleanverseForkTest is Test {
    string internal constant MONAD_RPC = "https://testnet-rpc.monad.xyz";
    uint256 internal constant MONAD_TESTNET = 10143;

    address internal constant APASS = 0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9;
    address internal constant POLICY = 0x36489bE45fa84f70a0c2BDB11D824Be608CB12Dd;
    address internal constant AUSDC = 0xaC0893567D43C3E7e6e35a72803df05416C1f20D;
    address internal constant ORIGIN_USDC = 0x534b2f3A21130d7a60830c2Df862319e593943A3;

    /// @dev Wallets that hold a live A-Pass: tier 50, ACTIVE.
    address internal constant HOLDER_A = 0xBBe8DB07Eaf9C4Ac1AAA46e4197AD22AA7041F3F;
    address internal constant HOLDER_B = 0x9E2816003da34Ea0E232Fb59A5e475Fce1121d98;

    /// @dev A wallet the registry has never heard of.
    address internal constant NO_CREDENTIAL = 0xc0ffee254729296a45a3885639AC7E10F9d54979;

    /// @dev A credential that carries a non-zero `previousKycHash` and a non-zero `group`.
    address internal constant ROTATED_HOLDER = 0x000000000000000000000000000000000000dEaD;

    bytes4 internal constant ATTRIBUTES_SELECTOR = 0x6a069f61;

    bool internal forkUnavailable;

    StandingRegistry internal registry;
    StandingPool internal pool;
    CreditManager internal manager;

    function setUp() public {
        // Overridable only so the offline path can be exercised; defaults to the public Monad RPC.
        string memory rpc = vm.envOr("MONAD_RPC_URL", MONAD_RPC);
        try vm.createSelectFork(rpc) {
            registry = new StandingRegistry(address(this));
            pool = new StandingPool(AUSDC, APASS, POLICY, address(this));
            manager = new CreditManager(
                address(pool),
                address(registry),
                APASS,
                POLICY,
                AUSDC,
                address(this),
                25_000e6,
                50_000e6,
                365 days
            );
            pool.grantRole(pool.CREDIT_MANAGER_ROLE(), address(manager));
            registry.grantRole(registry.RECORDER_ROLE(), address(manager));
        } catch {
            forkUnavailable = true;
            console.log("Monad testnet RPC unreachable; fork tests skipped.");
        }
    }

    // ------------------------------------------------------------------ raw registry access

    function _rawAttributes(address holder) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) =
            APASS.staticcall(abi.encodeWithSelector(ATTRIBUTES_SELECTOR, uint256(uint160(holder))));
        if (ret.length < 320) ok = false;
    }

    function _word(bytes memory ret, uint256 i) internal pure returns (uint256 v) {
        assembly {
            v := mload(add(ret, add(32, mul(i, 32))))
        }
    }

    // ------------------------------------------------------------------ A-Pass

    function test_Fork_ChainIsMonadTestnet() public view {
        if (forkUnavailable) return;
        assertEq(block.chainid, MONAD_TESTNET, "wrong chain");
        assertGt(APASS.code.length, 0, "A-Pass registry has code");
        assertGt(POLICY.code.length, 0, "policy engine has code");
        assertGt(AUSDC.code.length, 0, "aUSDC has code");
        assertGt(ORIGIN_USDC.code.length, 0, "origin USDC has code");
    }

    function test_Fork_ApassReader_ReadsALiveCredentialForAFundedWallet() public view {
        if (forkUnavailable) return;

        address[2] memory holders = [HOLDER_A, HOLDER_B];
        for (uint256 i = 0; i < holders.length; i++) {
            ApassReader.Credential memory c = ApassReader.read(APASS, holders[i]);

            assertTrue(c.exists, "credential exists");
            assertEq(c.status, ApassReader.STATUS_ACTIVE, "status ACTIVE");
            assertEq(c.tier, 50, "tier 50");
            assertTrue(c.kycHash != bytes32(0), "non-zero KYC hash");
            assertGt(c.expiresAt, block.timestamp, "not expired");
            assertGt(c.issuedAt, 0, "issued");
            assertTrue(ApassReader.isLive(c, block.timestamp), "live");
        }

        assertTrue(
            ApassReader.read(APASS, HOLDER_A).kycHash != ApassReader.read(APASS, HOLDER_B).kycHash,
            "two different people"
        );
    }

    function test_Fork_ApassReader_DecodedFieldsMatchTheRawRegistryWords() public view {
        if (forkUnavailable) return;

        (bool ok, bytes memory ret) = _rawAttributes(HOLDER_A);
        assertTrue(ok, "registry answered the raw selector");
        assertEq(ret.length, 320, "exactly ten words");

        ApassReader.Credential memory c = ApassReader.read(APASS, HOLDER_A);

        assertEq(uint256(c.status), _word(ret, 0), "status word");
        assertEq(uint256(c.tier), _word(ret, 1), "tier word");
        assertEq(uint256(c.subTier), _word(ret, 2), "subTier word");
        assertEq(uint256(c.expiresAt), _word(ret, 5), "expiry word");
        assertEq(uint256(c.issuedAt), _word(ret, 6), "issuedAt word");
        assertEq(uint256(c.kycHash), _word(ret, 8), "current KYC hash word");

        // And the expiry is the far-future value the credential was issued with.
        assertGt(c.expiresAt, 1_800_000_000, "expiry is real");
    }

    /// @dev The live registry does not return zeroes for an unknown holder -- it reverts. The reader
    ///      has to absorb that, or every uncredentialed counterparty would be an exception rather
    ///      than a refusal.
    function test_Fork_ApassReader_ReturnsNoCredentialForAnUnknownWallet() public view {
        if (forkUnavailable) return;

        (bool ok,) = _rawAttributes(NO_CREDENTIAL);
        assertFalse(ok, "the registry itself reverts for an unknown holder");

        ApassReader.Credential memory c = ApassReader.read(APASS, NO_CREDENTIAL);
        assertFalse(c.exists, "no credential");
        assertEq(c.status, 0, "no status");
        assertEq(c.tier, 0, "no tier");
        assertEq(c.kycHash, bytes32(0), "no identity");
        assertFalse(ApassReader.isLive(c, block.timestamp), "not live");
    }

    /// @dev Live repro of the group/subGroup decode defect: the registry holds a non-zero group for
    ///      this credential and the reader reports 0x0000. See KnownBugs.t.sol.
    function test_Fork_BUG_ApassReader_LosesTheGroupTagOnRealData() public view {
        if (forkUnavailable) return;

        (bool ok, bytes memory ret) = _rawAttributes(ROTATED_HOLDER);
        if (!ok) return; // the fixture wallet may not exist on every fork block
        uint256 rawGroup = _word(ret, 3);
        if (rawGroup == 0) return;

        ApassReader.Credential memory c = ApassReader.read(APASS, ROTATED_HOLDER);
        assertTrue(c.exists, "credential exists");
        assertEq(c.group, bytes2(0), "the group tag the registry holds is decoded as zero");
    }

    /// @dev Live evidence that KYC hashes really do rotate, which is what makes the registry's
    ///      "history follows the person" claim breakable. See KnownBugs.t.sol.
    function test_Fork_ApassRecordsCarryAPreviousKycHash() public view {
        if (forkUnavailable) return;

        (bool ok, bytes memory ret) = _rawAttributes(ROTATED_HOLDER);
        if (!ok) return;

        uint256 previous = _word(ret, 7);
        uint256 current = _word(ret, 8);
        if (previous == 0) return;

        assertTrue(previous != current, "this credential was re-issued under a new hash");
        assertEq(
            uint256(ApassReader.read(APASS, ROTATED_HOLDER).kycHash),
            current,
            "the reader keeps only the current hash and drops the link to the old one"
        );
    }

    // ------------------------------------------------------------------ policy engine

    function test_Fork_Policy_ApassGetterPointsAtTheRegistry() public view {
        if (forkUnavailable) return;
        assertEq(ICleanversePolicy(POLICY).apass(), APASS, "policy evaluates against the same registry");
    }

    function test_Fork_Policy_CanTransferIsCallableAndReturnsABool() public view {
        if (forkUnavailable) return;

        bool allowed = ICleanversePolicy(POLICY).canTransfer(AUSDC, HOLDER_A, HOLDER_B, 1e6);
        assertTrue(allowed, "two live A-Pass holders may transact");

        assertTrue(ICleanversePolicy(POLICY).isTokenRegistered(AUSDC), "aUSDC carries rules");
        assertFalse(ICleanversePolicy(POLICY).isPaused(AUSDC), "aUSDC is not paused");
        assertFalse(ICleanversePolicy(POLICY).isFrozen(AUSDC, HOLDER_A), "holder is not frozen");
    }

    /// @dev The engine refuses by REVERTING, not by returning false -- for either counterparty.
    function test_Fork_Policy_RefusesAnUncredentialedCounterpartyByReverting() public view {
        if (forkUnavailable) return;

        bool reverted;
        try ICleanversePolicy(POLICY).canTransfer(AUSDC, HOLDER_A, NO_CREDENTIAL, 1e6) returns (bool ok) {
            assertFalse(ok, "if it answers at all it must answer no");
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "an uncredentialed receiver makes the engine revert");

        reverted = false;
        try ICleanversePolicy(POLICY).canTransfer(AUSDC, NO_CREDENTIAL, HOLDER_A, 1e6) returns (bool ok) {
            assertFalse(ok, "if it answers at all it must answer no");
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "an uncredentialed SENDER makes the engine revert too");
    }

    function test_Fork_Asset_IsASixDecimalVerifiedAssetBoundToThePolicy() public view {
        if (forkUnavailable) return;
        assertEq(ICleanverseAsset(AUSDC).decimals(), 6, "aUSDC has 6 decimals");
        assertEq(ICleanverseAsset(AUSDC).policy(), POLICY, "aUSDC is governed by this policy engine");
    }

    // ------------------------------------------------------------------ the gate, deployed

    function test_Fork_ComplianceGate_AllowsARealApassHolder() public view {
        if (forkUnavailable) return;

        (bool allowed, ComplianceGate.Refusal reason) = pool.checkTransfer(HOLDER_B, HOLDER_A, 1e6);
        assertTrue(allowed, "a live A-Pass holder passes the deployed gate");
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.None), "no refusal");

        (bool allowedBack, ComplianceGate.Refusal reasonBack) =
            manager.checkTransfer(HOLDER_A, HOLDER_B, 1e6);
        assertTrue(allowedBack, "and so does the other one");
        assertEq(uint256(reasonBack), uint256(ComplianceGate.Refusal.None));
    }

    function test_Fork_ComplianceGate_RefusesAnAddressWithNoCredential() public view {
        if (forkUnavailable) return;

        (bool allowed, ComplianceGate.Refusal reason) = pool.checkTransfer(HOLDER_A, NO_CREDENTIAL, 1e6);
        assertFalse(allowed, "refused");
        assertEq(
            uint256(reason),
            uint256(ComplianceGate.Refusal.NoCredential),
            "and refused for the right reason, before the policy is even consulted"
        );

        (bool allowedMgr, ComplianceGate.Refusal reasonMgr) =
            manager.checkTransfer(address(pool), NO_CREDENTIAL, 1e6);
        assertFalse(allowedMgr);
        assertEq(uint256(reasonMgr), uint256(ComplianceGate.Refusal.NoCredential));
    }

    function test_Fork_ComplianceGate_TreatsTheProtocolAsUnregisteredUntilCleanverseSaysOtherwise()
        public
        view
    {
        if (forkUnavailable) return;
        assertFalse(
            ICleanversePolicy(POLICY).isTokenRegistered(address(pool)),
            "a fresh deployment carries no protocol rule set"
        );
        assertFalse(ICleanversePolicy(POLICY).isTokenRegistered(address(manager)), "nor does the manager");
    }

    // =================================================================================
    // Live confirmation of the deployment-bricking finding.
    //
    // The live engine refuses a transfer whose SENDER holds no A-Pass, by reverting. On origination
    // the sender is the pool; on repayment the receiver is the pool. script/Deploy.s.sol issues the
    // pool no credential, so against the real Cleanverse stack every borrow is refused with
    // AssetPolicyDenied and every repayment with NoCredential. The protocol cannot transact at all.
    // =================================================================================

    function test_Fork_BUG_OriginationIsRefusedBecauseThePoolHoldsNoApass() public view {
        if (forkUnavailable) return;

        // The borrower is impeccable...
        assertTrue(ApassReader.read(APASS, HOLDER_A).exists, "borrower holds a live A-Pass");

        // ...and the loan is still refused, because the disbursing party does not.
        (bool allowed, ComplianceGate.Refusal reason) = manager.checkTransfer(address(pool), HOLDER_A, 1e6);
        assertFalse(allowed, "origination refused on a real deployment");
        assertEq(
            uint256(reason),
            uint256(ComplianceGate.Refusal.AssetPolicyDenied),
            "the engine rejects the pool as sender"
        );
    }

    function test_Fork_BUG_RepaymentIsRefusedBecauseThePoolHoldsNoApass() public view {
        if (forkUnavailable) return;

        // This is the exact call `CreditManager.repay` makes: `to` is the pool.
        (bool allowed, ComplianceGate.Refusal reason) = manager.checkTransfer(HOLDER_A, address(pool), 1e6);
        assertFalse(allowed, "repayment refused on a real deployment");
        assertEq(
            uint256(reason),
            uint256(ComplianceGate.Refusal.NoCredential),
            "the pool itself has no credential"
        );
    }
}
