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
/// @dev Mirrors script/Deploy.s.sol exactly, including the renunciation of registry admin, so the
///      numbers and the authority surface asserted here are the ones that ship.
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

    /// @dev Every funded actor starts with 1_000_000 aUSDC, which is the top rung of the asset
    ///      ladder (>= 100_000 units -> 250 points).
    uint256 internal constant START_BALANCE = 1_000_000e6;

    /// @dev Expected underwriting for a tier-50 identity on the top asset rung and a clean record.
    /// tier band [45,60) = 190, subTier 0, tenure 50  -> identity 240
    /// assets (>= 100_000 aUSDC)                      -> 250
    /// history                                        -> 0
    /// The curve spans MIN_SCORE 350 to MAX_SCORE 1000, so `above` is 140 of a 650-point span.
    uint256 internal constant IDENTITY_TIER50 = 240;
    uint256 internal constant SCORE_TIER50 = 490;
    uint256 internal constant LINE_TIER50 = 14_692_307_692; // 5_000e6 + 45_000e6 * 140 / 650
    uint256 internal constant COLLAT_BPS_TIER50 = 6277; // 8000 - 8000 * 140 / 650
    uint256 internal constant APR_BPS_TIER50 = 2070; // 2500 - 2000 * 140 / 650

    /// @dev tier band [90,100) = 300, + subTier 50 + tenure 50, capped at IDENTITY_MAX 400.
    uint256 internal constant IDENTITY_VIP = 400;
    uint256 internal constant SCORE_VIP = 650;
    uint256 internal constant LINE_VIP = 25_769_230_769; // 5_000e6 + 45_000e6 * 300 / 650

    /// @dev Shares carry `_decimalsOffset() == 6` more decimals than the asset.
    uint256 internal constant SHARE_UNIT = 1e6;

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
        pool.setCreditManager(address(manager));
        registry.grantRole(registry.RECORDER_ROLE(), address(manager));
        // As in script/Deploy.s.sol: after this the recorder set can never change again.
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        issueCredential(lp, 50, 0, KYC_LP);
        issueCredential(lp2, 50, 0, KYC_LP2);
        issueCredential(alice, 50, 0, KYC_ALICE);
        issueCredential(aliceB, 50, 0, KYC_ALICE);
        issueCredential(vip, 99, 99, KYC_VIP);
        issueCredential(vipB, 99, 99, KYC_VIP);

        // The pool is a party to every disbursement and every repayment, so it holds an A-Pass of
        // its own. This is a deployment prerequisite, not a test convenience -- see
        // ForkTest#test_Fork_Deployment_GateRefusesEverythingUntilThePoolIsCredentialed.
        issueCredential(address(pool), 50, 0, KYC_POOL);

        address[7] memory funded = [lp, lp2, alice, aliceB, stranger, vip, vipB];
        for (uint256 i = 0; i < funded.length; i++) {
            asset.mint(funded[i], START_BALANCE);
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

    function onboard(address who, uint256 tier, uint256 subTier, bytes32 kycHash, uint256 balance)
        internal
    {
        issueCredential(who, tier, subTier, kycHash);
        asset.mint(who, balance);
        vm.startPrank(who);
        asset.approve(address(pool), type(uint256).max);
        asset.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function seedPool(uint256 amount) internal {
        vm.prank(lp);
        pool.deposit(amount, lp);
    }

    function expectRefusal(address party, ComplianceGate.Refusal reason) internal {
        vm.expectRevert(abi.encodeWithSelector(ComplianceGate.NotCompliant.selector, party, reason));
    }

    /// @notice Assets per 1e6 asset-units' worth of shares. Equals 1e6 when the pool is at par.
    /// @dev Shares carry six more decimals than the asset, so a price probe has to be denominated
    ///      in share units rather than asset units.
    function sharePrice() internal view returns (uint256) {
        return pool.convertToAssets(1e12);
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
