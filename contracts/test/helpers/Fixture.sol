// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockApass} from "../mocks/MockApass.sol";
import {MockPolicy} from "../mocks/MockPolicy.sol";
import {MockVerifiedAsset} from "../mocks/MockVerifiedAsset.sol";

import {ComplianceGate} from "../../src/ComplianceGate.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";
import {ApassReader} from "../../src/libraries/ApassReader.sol";
import {StandingMath} from "../../src/libraries/StandingMath.sol";

/// @notice Deterministic deployment of the whole protocol against controllable Cleanverse mocks.
/// @dev Ceilings match script/Deploy.s.sol so the numbers asserted here are the numbers that ship.
abstract contract Fixture is Test {
    MockApass internal apass;
    MockPolicy internal policy;
    MockVerifiedAsset internal asset;
    StandingRegistry internal registry;
    StandingPool internal pool;
    CreditManager internal manager;

    address internal admin = makeAddr("admin");
    address internal lp = makeAddr("lp");
    address internal lp2 = makeAddr("lp2");
    /// @dev Two wallets, one bank-verified human.
    address internal alice = makeAddr("alice");
    address internal aliceB = makeAddr("aliceB");
    /// @dev A wallet with no credential at all.
    address internal stranger = makeAddr("stranger");
    /// @dev A premium identity, tier 99 / subTier 99.
    address internal vip = makeAddr("vip");
    address internal vipB = makeAddr("vipB");

    bytes32 internal constant KYC_ALICE = keccak256("kyc:alice");
    bytes32 internal constant KYC_LP = keccak256("kyc:lp");
    bytes32 internal constant KYC_LP2 = keccak256("kyc:lp2");
    bytes32 internal constant KYC_VIP = keccak256("kyc:vip");
    bytes32 internal constant KYC_POOL = keccak256("kyc:pool");

    uint256 internal constant MAX_LOAN_PRINCIPAL = 25_000e6;
    uint256 internal constant MAX_CREDIT_LINE = 50_000e6;
    uint256 internal constant MAX_TERM = 365 days;

    uint256 internal constant START_TS = 1_800_000_000;
    uint256 internal constant ONE_YEAR = 365 days;

    /// @dev Expected underwriting for a tier-50 identity with >= 10 aUSDC and a clean record.
    /// tier 50*300/99 = 151, subTier 0, tenure 50  -> identity 201
    /// assets capped at 10 units * 25              -> 250
    /// history                                     -> 0
    uint256 internal constant SCORE_TIER50 = 451;
    uint256 internal constant LINE_TIER50 = 8_825e6; // 5_000e6 + 45_000e6 * 51 / 600
    uint256 internal constant COLLAT_BPS_TIER50 = 7320; // 8000 - 8000 * 51 / 600
    uint256 internal constant APR_BPS_TIER50 = 2330; // 2500 - 2000 * 51 / 600

    /// @dev tier 99 + subTier 99 + full tenure caps identity at 400; + 250 assets -> 650.
    uint256 internal constant SCORE_VIP = 650;
    uint256 internal constant LINE_VIP = 23_750e6; // 5_000e6 + 45_000e6 * 250 / 600

    function setUp() public virtual {
        vm.warp(START_TS);

        apass = new MockApass();
        policy = new MockPolicy(address(apass));
        asset = new MockVerifiedAsset(address(policy));
        registry = new StandingRegistry(admin);
        pool = new StandingPool(address(asset), address(apass), address(policy), admin);
        manager = new CreditManager(
            address(pool),
            address(registry),
            address(apass),
            address(policy),
            address(asset),
            admin,
            MAX_LOAN_PRINCIPAL,
            MAX_CREDIT_LINE,
            MAX_TERM
        );

        vm.startPrank(admin);
        pool.grantRole(pool.CREDIT_MANAGER_ROLE(), address(manager));
        registry.grantRole(registry.RECORDER_ROLE(), address(manager));
        vm.stopPrank();

        issueCredential(lp, 50, 0, KYC_LP);
        issueCredential(lp2, 50, 0, KYC_LP2);
        issueCredential(alice, 50, 0, KYC_ALICE);
        issueCredential(aliceB, 50, 0, KYC_ALICE);
        issueCredential(vip, 99, 99, KYC_VIP);
        issueCredential(vipB, 99, 99, KYC_VIP);

        // The pool is given a credential of its own. That is NOT cosmetic: `CreditManager.repay`
        // runs the compliance gate with `to = address(pool)`, so without this every repayment in
        // the suite would revert. See KnownBugs.t.sol#test_BUG_Repay_BrickedWhenPoolHasNoApass.
        issueCredential(address(pool), 50, 0, KYC_POOL);

        address[7] memory funded = [lp, lp2, alice, aliceB, stranger, vip, vipB];
        for (uint256 i = 0; i < funded.length; i++) {
            asset.mint(funded[i], 1_000_000e6);
            vm.startPrank(funded[i]);
            asset.approve(address(pool), type(uint256).max);
            asset.approve(address(manager), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ helpers

    function issueCredential(address holder, uint256 tier, uint256 subTier, bytes32 kycHash)
        internal
    {
        apass.issue(holder, 1, tier, subTier, block.timestamp + ONE_YEAR, block.timestamp - ONE_YEAR, kycHash);
    }

    function seedPool(uint256 amount) internal {
        vm.prank(lp);
        pool.deposit(amount, lp);
    }

    function expectRefusal(address party, ComplianceGate.Refusal reason) internal {
        vm.expectRevert(abi.encodeWithSelector(ComplianceGate.NotCompliant.selector, party, reason));
    }

    function interestFor(uint256 principal, uint256 aprBps, uint256 termSeconds)
        internal
        pure
        returns (uint256)
    {
        return (principal * aprBps * termSeconds) / (10_000 * 365 days);
    }

    function historyOf(bytes32 kycHash) internal view returns (StandingRegistry.History memory) {
        return registry.historyOf(kycHash);
    }
}
