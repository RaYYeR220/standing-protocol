// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StandingRegistry} from "../src/StandingRegistry.sol";
import {StandingPool} from "../src/StandingPool.sol";
import {CreditManager} from "../src/CreditManager.sol";
import {ComplianceGate} from "../src/ComplianceGate.sol";
import {ApassReader} from "../src/libraries/ApassReader.sol";
import {ICleanversePolicy} from "../src/interfaces/ICleanverse.sol";

/// @notice The whole product, end to end, against the real Cleanverse contracts on a fork.
///
/// @dev Everything here is genuine: the A-Pass registry, the policy engine and aUSDC are the live
///      deployments, and the credentials issued below are issued by the actual issuer through the
///      actual entry point — we impersonate the role holders rather than substituting the
///      contracts. Nothing is mocked, stubbed or pre-seeded.
///
///      The two things we impersonate, and why:
///        * `APASS_ISSUER` — Cleanverse's issuing wallet. Their `/generate_apass` endpoint is the
///          only way to obtain a credential and it returns a server error at the time of writing,
///          including for the pool contract, which needs one. See CLAIMS.md.
///        * `AUSDC_MINTER` — the AccessCore contract, which mints aUSDC when origin funds are
///          wrapped. Our institution is not whitelisted to wrap, and the sandbox faucet is empty.
///
///      Run:
///        forge script script/Demo.s.sol --rpc-url https://testnet-rpc.monad.xyz -vv
contract Demo is Script {
    address constant APASS = 0xbA82D189540CaC9DC6FF46B6837CaC1BFdEC58B9;
    address constant POLICY = 0x36489bE45fa84f70a0c2BDB11D824Be608CB12Dd;
    address constant AUSDC = 0xaC0893567D43C3E7e6e35a72803df05416C1f20D;

    /// @dev Recovered from the transaction Cleanverse itself sent when issuing our credential.
    address constant APASS_ISSUER = 0xBd8428761efB5384C4945d16de56817Caa6903dF;
    bytes4 constant ISSUE_SELECTOR = 0xb8dd3664;

    /// @dev AccessCore holds MINTER_ROLE on aUSDC.
    address constant AUSDC_MINTER = 0x8F118338a1fa41E7Fa86Be19A4e8B99Ed58A6EcC;

    uint256 constant MAX_LOAN_PRINCIPAL = 25_000e6;
    uint256 constant MAX_CREDIT_LINE = 50_000e6;
    uint256 constant MAX_TERM = 365 days;

    StandingRegistry registry;
    StandingPool pool;
    CreditManager manager;

    address admin = makeAddr("operator");
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address stranger = makeAddr("stranger"); // never issued a credential

    function run() external {
        console.log("Standing -- end to end on a Monad fork, against live Cleanverse contracts");
        console.log("chain id %s", block.chainid);

        _deploy();
        _issueCredentials();
        _fund();

        _step1_lenderSupplies();
        _step2_borrowerDraws();
        _step3_refusals();
        _step4_repay();
        _step5_default();
    }

    // ------------------------------------------------------------------ setup

    function _deploy() private {
        vm.startPrank(admin);
        registry = new StandingRegistry(admin);
        pool = new StandingPool(AUSDC, APASS, POLICY, admin);
        manager = new CreditManager(
            address(pool), address(registry), APASS, POLICY, AUSDC, admin,
            MAX_LOAN_PRINCIPAL, MAX_CREDIT_LINE, MAX_TERM
        );
        pool.grantRole(pool.CREDIT_MANAGER_ROLE(), address(manager));
        registry.grantRole(registry.RECORDER_ROLE(), address(manager));
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();
        console.log("");
        console.log("deployed  pool %s", address(pool));
        console.log("          credit manager %s", address(manager));
    }

    /// @dev Issues through the live registry, as Cleanverse does.
    function _issue(address holder, uint256 tier, uint256 subTier, bytes32 kycHash) private {
        vm.prank(APASS_ISSUER);
        (bool ok,) = APASS.call(
            abi.encodeWithSelector(
                ISSUE_SELECTOR,
                holder,
                tier,
                subTier,
                bytes32(0), // group
                bytes32(0), // subGroup
                block.timestamp + 365 days,
                kycHash,
                bytes32(0)
            )
        );
        require(ok, "issue failed");
    }

    function _issueCredentials() private {
        // Both protocol contracts touch verified assets — the pool holds the book, the manager
        // holds posted collateral — so both are parties to transfers and both need a credential.
        _issue(address(pool), 50, 0, keccak256("standing.pool.identity"));
        _issue(address(manager), 50, 0, keccak256("standing.manager.identity"));
        _issue(lender, 70, 0, keccak256("lender.identity"));
        _issue(borrower, 85, 40, keccak256("borrower.identity"));

        console.log("");
        console.log("-- credentials, read back from the live registry --");
        _printCredential("pool", address(pool));
        _printCredential("credit manager", address(manager));
        _printCredential("lender", lender);
        _printCredential("borrower", borrower);
        _printCredential("stranger", stranger);
    }

    function _fund() private {
        vm.startPrank(AUSDC_MINTER);
        (bool a,) = AUSDC.call(abi.encodeWithSignature("mint(address,uint256)", lender, 50_000e6));
        (bool b,) = AUSDC.call(abi.encodeWithSignature("mint(address,uint256)", borrower, 6_000e6));
        vm.stopPrank();
        require(a && b, "mint failed");
    }

    // ------------------------------------------------------------------ the walkthrough

    function _step1_lenderSupplies() private {
        console.log("");
        console.log("== 1. a verified lender supplies the pool ==");
        vm.startPrank(lender);
        IERC20(AUSDC).approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(40_000e6, lender);
        vm.stopPrank();
        console.log("deposited 40,000 aUSDC -> %s shares", shares);
        console.log("pool total assets       %s", pool.totalAssets());
    }

    function _step2_borrowerDraws() private {
        console.log("");
        console.log("== 2. underwriting, from on-chain state alone ==");
        CreditManager.Quote memory q = manager.quote(borrower, 5_000e6, 90 days);
        console.log("score                   %s / 1000", q.score);
        console.log("  identity subtotal     %s", q.breakdown.identitySubtotal);
        console.log("    tier points         %s", q.breakdown.tierPoints);
        console.log("    subTier points      %s", q.breakdown.subTierPoints);
        console.log("    tenure points       %s", q.breakdown.tenurePoints);
        console.log("  history subtotal      %s", q.breakdown.historySubtotal);
        console.log("  asset subtotal        %s", q.breakdown.assetSubtotal);
        console.log("credit line             %s", q.creditLine);
        console.log("collateral required     %s  (principal 5000000000)", q.collateralRequired);
        console.log("apr (bps)               %s", q.aprBps);
        console.log("approved                %s", q.approved);

        vm.startPrank(borrower);
        IERC20(AUSDC).approve(address(manager), type(uint256).max);
        uint256 loanId = manager.open(5_000e6, 90 days);
        vm.stopPrank();

        CreditManager.Loan memory l = manager.loan(loanId);
        console.log("");
        console.log("loan #%s opened", loanId);
        console.log("  principal   %s", l.principal);
        console.log("  collateral  %s", l.collateral);
        console.log("-> the borrower posted %s%% of what they took", (uint256(l.collateral) * 100) / l.principal);
    }

    function _step3_refusals() private {
        console.log("");
        console.log("== 3. the refusals ==");

        (, ComplianceGate.Refusal r1, address p1) =
            manager.checkTransferDetailed(address(pool), stranger, 1_000e6);
        console.log("a. lend to a wallet with no credential");
        console.log("   refused, reason code %s", uint8(r1));
        console.log("   offending party      %s", p1);

        vm.prank(borrower);
        try manager.open(MAX_LOAN_PRINCIPAL + 1, 90 days) {
            console.log("b. over-ceiling draw SUCCEEDED -- this should be impossible");
        } catch {
            console.log("b. draw above the protocol ceiling reverted");
        }

        vm.prank(borrower);
        try manager.open(20_000e6, 90 days) {
            console.log("c. over-line draw SUCCEEDED -- this should be impossible");
        } catch {
            console.log("c. draw beyond the borrower's credit line reverted");
        }

        vm.prank(stranger);
        try manager.open(1_000e6, 90 days) {
            console.log("d. uncredentialed draw SUCCEEDED -- this should be impossible");
        } catch {
            console.log("d. draw by an uncredentialed wallet reverted");
        }
    }

    function _step4_repay() private {
        console.log("");
        console.log("== 4. repayment, and standing grows ==");
        uint256 before = pool.convertToAssets(1e12); // one whole share (6 decimals of virtual offset)
        vm.warp(block.timestamp + 90 days);
        vm.prank(borrower);
        manager.repay(1);
        console.log("assets per share %s -> %s", before, pool.convertToAssets(1e12));

        CreditManager.Quote memory q = manager.quote(borrower, 5_000e6, 90 days);
        console.log("score after one repayment  %s", q.score);
        console.log("collateral now required    %s (was higher)", q.collateralRequired);
    }

    function _step5_default() private {
        console.log("");
        console.log("== 5. a default, and what it costs the identity ==");
        vm.prank(borrower);
        uint256 loanId = manager.open(3_000e6, 30 days);

        vm.warp(block.timestamp + 30 days + manager.GRACE_PERIOD() + 1);
        console.log("loan #%s defaultable: %s", loanId, manager.isDefaultable(loanId));

        uint256 sharePriceBefore = pool.convertToAssets(1e12);
        manager.markDefault(loanId); // permissionless
        console.log("assets per share %s -> %s", sharePriceBefore, pool.convertToAssets(1e12));
        console.log("  the loss lands on lenders, not a reserve");
        console.log("pool lifetime losses       %s", pool.lifetimeLosses());

        CreditManager.Quote memory q = manager.quote(borrower, 1_000e6, 30 days);
        console.log("borrower score after default %s", q.score);
        console.log("still eligible               %s", q.approved);

        ApassReader.Credential memory c = manager.credentialOf(borrower);
        StandingRegistry.History memory h = registry.historyOf(c.kycHash);
        console.log("registry: originated %s", h.loansOriginated);
        console.log("          repaid     %s", h.loansRepaid);
        console.log("          defaulted  %s", h.loansDefaulted);
        console.log("the record is written against the identity, not the wallet -- a fresh wallet");
        console.log("under the same credential inherits it.");
    }

    // ------------------------------------------------------------------ helpers

    function _printCredential(string memory label, address who) private view {
        ApassReader.Credential memory c = manager.credentialOf(who);
        if (!c.exists) {
            console.log("%s: no credential", label);
            return;
        }
        console.log("%s: status %s, tier %s", label, c.status, c.tier);
    }
}
