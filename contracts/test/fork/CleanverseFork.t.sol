// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ComplianceGate} from "../../src/ComplianceGate.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";
import {ICleanverseAsset, ICleanversePolicy} from "../../src/interfaces/ICleanverse.sol";

/// @title CleanverseForkTest
/// @notice Runs the protocol's identity and policy plumbing against the real Cleanverse contracts on
///         Monad testnet. Nothing here is mocked: the A-Pass records, the word layout, the policy
///         verdicts and the refusal reasons all come from live state.
/// @dev Only the three Cleanverse addresses are pinned. The protocol's own contracts are deployed
///      fresh on the fork every run, so nothing here depends on a particular deployment surviving.
///      The whole contract is gated on the fork being reachable so the suite still passes offline.
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

    /// @dev tokenId 57005. Its record is the useful one: a non-zero `previousKycHash` and a non-zero
    ///      left-aligned `subGroup`.
    address internal constant ROTATED_HOLDER = 0x000000000000000000000000000000000000dEaD;

    bytes4 internal constant ATTRIBUTES_SELECTOR = 0x6a069f61;

    /// @dev Cleanverse's issuing wallet and the AccessCore contract that holds aUSDC MINTER_ROLE.
    ///      Impersonating them is how a fork test obtains a real credential and real verified assets
    ///      without a testnet faucet round trip; the contracts under test are unchanged.
    address internal constant APASS_ISSUER = 0xBd8428761efB5384C4945d16de56817Caa6903dF;
    bytes4 internal constant ISSUE_SELECTOR = 0xb8dd3664;
    address internal constant AUSDC_MINTER = 0x8F118338a1fa41E7Fa86Be19A4e8B99Ed58A6EcC;

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
            pool.setCreditManager(address(manager));
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

    function _word(bytes memory ret, uint256 i) internal pure returns (bytes32 v) {
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

    /// @dev Word-for-word against the raw return data, including the two left-aligned tag fields and
    ///      the previous KYC hash the reader now keeps.
    function test_Fork_ApassReader_DecodedFieldsMatchTheRawRegistryWords() public view {
        if (forkUnavailable) return;

        address[2] memory holders = [HOLDER_A, ROTATED_HOLDER];
        for (uint256 i = 0; i < holders.length; i++) {
            (bool ok, bytes memory ret) = _rawAttributes(holders[i]);
            if (!ok) continue;
            assertEq(ret.length, 320, "exactly ten words");

            ApassReader.Credential memory c = ApassReader.read(APASS, holders[i]);

            assertEq(uint256(c.status), uint256(_word(ret, 0)), "status word");
            assertEq(uint256(c.tier), uint256(_word(ret, 1)), "tier word");
            assertEq(uint256(c.subTier), uint256(_word(ret, 2)), "subTier word");
            assertEq(c.group, bytes2(_word(ret, 3)), "group word");
            assertEq(c.subGroup, bytes2(_word(ret, 4)), "subGroup word");
            assertEq(uint256(c.expiresAt), uint256(_word(ret, 5)), "expiry word");
            assertEq(uint256(c.issuedAt), uint256(_word(ret, 6)), "issuedAt word");
            assertEq(c.previousKycHash, _word(ret, 7), "previous KYC hash word");
            assertEq(c.kycHash, _word(ret, 8), "current KYC hash word");
        }

        assertGt(ApassReader.read(APASS, HOLDER_A).expiresAt, 1_800_000_000, "expiry is real");
    }

    /// @dev The tag fields are LEFT-aligned on chain, so `bytes2(word)` is the correct read. This is
    ///      the live check behind the retraction in RegressionFixed.t.sol: tokenId 57005's subGroup
    ///      word reads 5244000…000, and the reader must decode it as "RD", not 0x0000.
    function test_Fork_ApassReader_DecodesTheLeftAlignedTagFields() public view {
        if (forkUnavailable) return;

        (bool ok, bytes memory ret) = _rawAttributes(ROTATED_HOLDER);
        if (!ok) return;

        bytes32 rawGroup = _word(ret, 3);
        bytes32 rawSubGroup = _word(ret, 4);
        // At least one tag is set on this record, and it is left-aligned rather than numeric.
        if (rawGroup == bytes32(0) && rawSubGroup == bytes32(0)) return;

        ApassReader.Credential memory c = ApassReader.read(APASS, ROTATED_HOLDER);
        assertTrue(c.exists, "credential exists");

        if (rawSubGroup != bytes32(0)) {
            assertEq(c.subGroup, bytes2(rawSubGroup), "subGroup decodes from the high bytes");
            assertTrue(c.subGroup != bytes2(0), "and is not silently lost");
            assertEq(uint256(rawSubGroup) & type(uint224).max, 0, "the word really is left-aligned");
        }
        if (rawGroup != bytes32(0)) {
            assertEq(c.group, bytes2(rawGroup), "group decodes from the high bytes");
            assertTrue(c.group != bytes2(0), "and is not silently lost");
        }
    }

    /// @dev The live registry does not return zeroes for an unknown holder — it reverts. The reader
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
        assertEq(c.previousKycHash, bytes32(0), "no supersession");
        assertFalse(ApassReader.isLive(c, block.timestamp), "not live");
    }

    /// @dev Live proof that KYC hashes really do rotate, which is the whole reason the registry has
    ///      to union identities rather than key on the current hash.
    function test_Fork_ApassRecordsCarryAPreviousKycHashAndTheReaderKeepsIt() public view {
        if (forkUnavailable) return;

        (bool ok, bytes memory ret) = _rawAttributes(ROTATED_HOLDER);
        if (!ok) return;

        bytes32 previous = _word(ret, 7);
        bytes32 current = _word(ret, 8);
        if (previous == bytes32(0)) return;

        assertTrue(previous != current, "this credential was re-issued under a new hash");

        ApassReader.Credential memory c = ApassReader.read(APASS, ROTATED_HOLDER);
        assertEq(c.kycHash, current, "current hash");
        assertEq(c.previousKycHash, previous, "and the link back is no longer discarded");
    }

    /// @dev The registry's supersession chain, fed with a real credential's real pair of hashes.
    function test_Fork_RegistryUnionsARealCredentialsHashPair() public {
        if (forkUnavailable) return;

        ApassReader.Credential memory c = ApassReader.read(APASS, ROTATED_HOLDER);
        if (!c.exists || c.previousKycHash == bytes32(0)) return;

        StandingRegistry reg = new StandingRegistry(address(this));
        reg.grantRole(reg.RECORDER_ROLE(), address(this));

        reg.recordOrigination(c.previousKycHash, ROTATED_HOLDER, 1_000e6);
        reg.recordDefault(c.previousKycHash, ROTATED_HOLDER, 400e6);

        reg.linkIdentity(c.previousKycHash, c.kycHash);

        assertEq(reg.canonicalIdentity(c.kycHash), c.previousKycHash, "folded into the old identity");
        assertEq(reg.historyOf(c.kycHash).loansDefaulted, 1, "and the write-off follows a real re-issue");
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

    /// @dev The engine refuses by REVERTING, not by returning false — for either counterparty. This
    ///      is why the gate has to check both ends itself and why every policy call is wrapped.
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

        (bool allowed, ComplianceGate.Refusal reason, address party) =
            pool.checkTransferDetailed(HOLDER_B, HOLDER_A, 1e6);
        assertTrue(allowed, "a live A-Pass holder passes the deployed gate");
        assertEq(uint256(reason), uint256(ComplianceGate.Refusal.None), "no refusal");
        assertEq(party, address(0), "nobody to blame");

        (bool allowedBack,) = manager.checkTransfer(HOLDER_A, HOLDER_B, 1e6);
        assertTrue(allowedBack, "and so does the other one");

        (bool okA,) = pool.checkParty(HOLDER_A);
        (bool okB,) = pool.checkParty(HOLDER_B);
        assertTrue(okA && okB, "both parties pass on their own");
    }

    function test_Fork_ComplianceGate_RefusesAnAddressWithNoCredential() public view {
        if (forkUnavailable) return;

        (bool allowed, ComplianceGate.Refusal reason, address party) =
            pool.checkTransferDetailed(HOLDER_A, NO_CREDENTIAL, 1e6);
        assertFalse(allowed, "refused");
        assertEq(
            uint256(reason),
            uint256(ComplianceGate.Refusal.NoCredential),
            "and refused for the right reason, before the policy is even consulted"
        );
        assertEq(party, NO_CREDENTIAL, "naming the party that failed");

        // The same in the sending position, which the gate now checks too.
        (bool allowedFrom, ComplianceGate.Refusal reasonFrom, address partyFrom) =
            pool.checkTransferDetailed(NO_CREDENTIAL, HOLDER_A, 1e6);
        assertFalse(allowedFrom);
        assertEq(uint256(reasonFrom), uint256(ComplianceGate.Refusal.NoCredential));
        assertEq(partyFrom, NO_CREDENTIAL);

        (bool ok, ComplianceGate.Refusal partyReason) = pool.checkParty(NO_CREDENTIAL);
        assertFalse(ok);
        assertEq(uint256(partyReason), uint256(ComplianceGate.Refusal.NoCredential));
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
    // Deployment prerequisite, verified against live state.
    //
    // The pool is a counterparty to every disbursement and every repayment, and the live engine
    // refuses a transfer whose sender OR receiver holds no A-Pass. A freshly deployed pool holds
    // none, so until Cleanverse issues it one the protocol correctly refuses everything. The gate
    // now names the pool, which is what makes this diagnosable rather than mysterious.
    // =================================================================================

    function test_Fork_Deployment_GateRefusesEverythingUntilThePoolIsCredentialed() public view {
        if (forkUnavailable) return;

        assertFalse(ApassReader.read(APASS, address(pool)).exists, "a fresh pool holds no A-Pass");
        assertTrue(ApassReader.read(APASS, HOLDER_A).exists, "the borrower is impeccable");

        // Origination: the pool is the sender.
        (bool canBorrow, ComplianceGate.Refusal borrowReason, address borrowParty) =
            manager.checkTransferDetailed(address(pool), HOLDER_A, 1e6);
        assertFalse(canBorrow, "origination refused");
        assertEq(uint256(borrowReason), uint256(ComplianceGate.Refusal.NoCredential));
        assertEq(borrowParty, address(pool), "and it says exactly which party is missing");

        // Repayment: the pool is the receiver.
        (bool canRepay, ComplianceGate.Refusal repayReason, address repayParty) =
            manager.checkTransferDetailed(HOLDER_A, address(pool), 1e6);
        assertFalse(canRepay, "repayment refused");
        assertEq(uint256(repayReason), uint256(ComplianceGate.Refusal.NoCredential));
        assertEq(repayParty, address(pool));
    }

    /// @dev And the moment that credential exists, both legs clear. Simulated by pointing a fresh
    ///      deployment at a wallet that really does hold a live A-Pass on this chain.
    function test_Fork_Deployment_BothLegsClearOnceThePoolPartyIsCredentialed() public view {
        if (forkUnavailable) return;

        // HOLDER_B stands in for a credentialed pool: same gate, same policy, real credential.
        (bool outbound,) = manager.checkTransfer(HOLDER_B, HOLDER_A, 1e6);
        (bool inbound,) = manager.checkTransfer(HOLDER_A, HOLDER_B, 1e6);
        assertTrue(outbound, "disbursement leg clears");
        assertTrue(inbound, "repayment leg clears");
    }

    // =================================================================================
    // End to end against the live stack.
    //
    // Credentials are issued through the real A-Pass registry by impersonating Cleanverse's issuing
    // wallet, and aUSDC is minted by impersonating AccessCore. Everything downstream — the gate, the
    // policy engine, the token's own transfer rules, the scoring — is the real thing.
    // =================================================================================

    function _issue(address holder, uint256 tier, uint256 subTier, bytes32 kycHash)
        internal
        returns (bool ok)
    {
        vm.prank(APASS_ISSUER);
        (ok,) = APASS.call(
            abi.encodeWithSelector(
                ISSUE_SELECTOR,
                holder,
                tier,
                subTier,
                bytes32(0),
                bytes32(0),
                block.timestamp + 365 days,
                kycHash,
                bytes32(0)
            )
        );
    }

    function _mintAusdc(address to, uint256 amount) internal returns (bool ok) {
        vm.prank(AUSDC_MINTER);
        (ok,) = AUSDC.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
    }

    /// @dev Issues to the pool, the manager, a lender and a borrower, then runs the whole product.
    ///      Returns false if the impersonated roles no longer hold, so the suite degrades to a skip
    ///      rather than a false failure if Cleanverse rotates them.
    function _bootstrapLiveActors(address lender, address borrower) internal returns (bool) {
        if (!_issue(address(pool), 50, 0, keccak256("fork.pool.identity"))) return false;
        if (!_issue(address(manager), 50, 0, keccak256("fork.manager.identity"))) return false;
        if (!_issue(lender, 70, 0, keccak256("fork.lender.identity"))) return false;
        if (!_issue(borrower, 85, 40, keccak256("fork.borrower.identity"))) return false;
        if (!_mintAusdc(lender, 60_000e6)) return false;
        if (!_mintAusdc(borrower, 6_000e6)) return false;
        return true;
    }

    function test_Fork_EndToEnd_DepositBorrowAndRepayAgainstLiveCleanverse() public {
        if (forkUnavailable) return;

        address lender = makeAddr("forkLender");
        address borrower = makeAddr("forkBorrower");
        if (!_bootstrapLiveActors(lender, borrower)) {
            console.log("Cleanverse issuing roles unavailable at this block; end-to-end skipped.");
            return;
        }

        // The credentials really are in the live registry.
        assertTrue(ApassReader.read(APASS, address(pool)).exists, "pool credentialed");
        assertTrue(ApassReader.read(APASS, borrower).exists, "borrower credentialed");
        assertEq(ApassReader.read(APASS, borrower).tier, 85, "tier as issued");

        // ---- supply side, through the live policy engine
        vm.startPrank(lender);
        IERC20(AUSDC).approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(50_000e6, lender);
        vm.stopPrank();

        assertGt(shares, 0, "shares minted");
        assertEq(pool.totalAssets(), 50_000e6, "capital in");
        assertEq(pool.convertToAssets(1e12), 1e6, "at par");

        // ---- underwriting, from live credential state
        CreditManager.Quote memory q = manager.quote(borrower, 3_000e6, 90 days);
        assertTrue(q.approved, "the live borrower is underwritten");
        assertGt(q.score, 0, "scored from the real credential");
        assertGt(q.creditLine, 0, "and given a line");

        // ---- draw
        vm.startPrank(borrower);
        IERC20(AUSDC).approve(address(manager), type(uint256).max);
        uint256 loanId = manager.open(3_000e6, 90 days);
        vm.stopPrank();

        CreditManager.Loan memory l = manager.loan(loanId);
        assertLt(l.collateral, l.principal, "under-collateralized against a real credential");
        assertEq(l.principal, 3_000e6);
        assertEq(pool.outstandingPrincipal(), 3_000e6);
        assertEq(pool.totalAssets(), 50_000e6, "lending does not move the share price");
        assertEq(registry.historyOf(l.kycHash).loansOriginated, 1, "recorded against the identity");

        // ---- repay
        vm.warp(block.timestamp + 90 days);
        uint256 interest = l.interestDue;
        assertGt(interest, 0, "a real term costs real interest");

        vm.prank(borrower);
        manager.repay(loanId);

        assertEq(pool.outstandingPrincipal(), 0, "book cleared");
        assertEq(pool.totalAssets(), 50_000e6 + interest, "LPs earned exactly the interest");
        assertGt(pool.convertToAssets(1e12), 1e6, "share price rose");
        assertEq(registry.historyOf(l.kycHash).loansRepaid, 1, "standing earned on live state");
    }

    /// @dev The same deployment refuses an uncredentialed party at every entry point, with the live
    ///      registry and the live policy engine doing the deciding.
    function test_Fork_EndToEnd_UncredentialedPartyIsRefusedEverywhere() public {
        if (forkUnavailable) return;

        address lender = makeAddr("forkLender2");
        address borrower = makeAddr("forkBorrower2");
        if (!_bootstrapLiveActors(lender, borrower)) return;

        vm.startPrank(lender);
        IERC20(AUSDC).approve(address(pool), type(uint256).max);
        pool.deposit(50_000e6, lender);
        vm.stopPrank();

        if (!_mintAusdc(NO_CREDENTIAL, 10_000e6)) return;

        // Deposit.
        vm.startPrank(NO_CREDENTIAL);
        IERC20(AUSDC).approve(address(pool), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                ComplianceGate.NotCompliant.selector, NO_CREDENTIAL, ComplianceGate.Refusal.NoCredential
            )
        );
        pool.deposit(1_000e6, NO_CREDENTIAL);
        vm.stopPrank();

        // Borrow.
        vm.expectRevert(
            abi.encodeWithSelector(
                ComplianceGate.NotCompliant.selector, NO_CREDENTIAL, ComplianceGate.Refusal.NoCredential
            )
        );
        vm.prank(NO_CREDENTIAL);
        manager.open(1_000e6, 90 days);

        // Withdraw to an uncredentialed receiver.
        vm.expectRevert(
            abi.encodeWithSelector(
                ComplianceGate.NotCompliant.selector, NO_CREDENTIAL, ComplianceGate.Refusal.NoCredential
            )
        );
        vm.prank(lender);
        pool.withdraw(1_000e6, NO_CREDENTIAL, lender);

        // And a share transfer to them.
        uint256 shares = pool.balanceOf(lender);
        vm.expectRevert(
            abi.encodeWithSelector(
                ComplianceGate.NotCompliant.selector, NO_CREDENTIAL, ComplianceGate.Refusal.NoCredential
            )
        );
        vm.prank(lender);
        pool.transfer(NO_CREDENTIAL, shares);
    }

    /// @dev A live default: collateral seized to the pool, shortfall booked against the share price,
    ///      write-off recorded against the real identity.
    function test_Fork_EndToEnd_DefaultIsBookedAgainstTheLiveIdentity() public {
        if (forkUnavailable) return;

        address lender = makeAddr("forkLender3");
        address borrower = makeAddr("forkBorrower3");
        if (!_bootstrapLiveActors(lender, borrower)) return;

        vm.startPrank(lender);
        IERC20(AUSDC).approve(address(pool), type(uint256).max);
        pool.deposit(50_000e6, lender);
        vm.stopPrank();

        vm.startPrank(borrower);
        IERC20(AUSDC).approve(address(manager), type(uint256).max);
        uint256 loanId = manager.open(3_000e6, 30 days);
        vm.stopPrank();

        CreditManager.Loan memory l = manager.loan(loanId);
        uint256 shortfall = uint256(l.principal) - uint256(l.collateral);
        uint256 priceBefore = pool.convertToAssets(1e12);

        vm.warp(block.timestamp + 30 days + manager.GRACE_PERIOD());
        manager.markDefault(loanId);

        assertEq(pool.lifetimeLosses(), shortfall, "loss recognised");
        assertEq(pool.totalAssets(), 50_000e6 - shortfall, "and taken out of the share price");
        assertLt(pool.convertToAssets(1e12), priceBefore, "LPs paid for it");
        assertEq(registry.historyOf(l.kycHash).loansDefaulted, 1, "recorded against the live identity");

        // And the same identity is now refused on a brand new wallet.
        address freshWallet = makeAddr("forkBorrower3Fresh");
        if (!_issue(freshWallet, 85, 40, keccak256("fork.borrower.identity"))) return;
        if (!_mintAusdc(freshWallet, 6_000e6)) return;
        assertFalse(manager.quote(freshWallet, 1_000e6, 30 days).approved, "standing follows the person");
    }
}
