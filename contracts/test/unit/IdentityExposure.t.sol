// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../helpers/Fixture.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";

/// @notice The headline property: a credit line belongs to a bank-verified person, not to a key.
/// @dev If this is wrong the whole protocol is wrong -- an under-collateralized line that can be
///      cloned by funding a second wallet is an unlimited line.
contract IdentityExposureTest is Fixture {
    uint256 internal constant DEPOSIT = 200_000e6;

    function setUp() public override {
        super.setUp();
        seedPool(DEPOSIT);
    }

    function test_TwoWalletsOfOneIdentityShareOneCreditLine() public {
        assertEq(manager.credentialOf(alice).kycHash, manager.credentialOf(aliceB).kycHash, "same person");
        assertTrue(alice != aliceB, "different keys");

        assertEq(manager.quote(alice, 1e6, 30 days).creditLine, LINE_TIER50);
        assertEq(manager.quote(aliceB, 1e6, 30 days).creditLine, LINE_TIER50);

        uint256 firstDraw = 6_000e6;
        vm.prank(alice);
        manager.open(firstDraw, 30 days);

        // The second wallet's headroom is the first wallet's leftovers, not a fresh line.
        uint256 expectedHeadroom = LINE_TIER50 - firstDraw;
        CreditManager.Quote memory q = manager.quote(aliceB, expectedHeadroom, 30 days);
        assertEq(q.alreadyDrawn, firstDraw, "second wallet sees the first wallet's draw");
        assertEq(q.maxDrawNow, expectedHeadroom, "headroom shared");

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditManager.ExceedsCreditLine.selector, expectedHeadroom + 1, expectedHeadroom
            )
        );
        vm.prank(aliceB);
        manager.open(expectedHeadroom + 1, 30 days);
    }

    function test_SecondWalletMayDrawExactlyTheRemainingHeadroomAndNoMore() public {
        uint256 firstDraw = 6_000e6;
        uint256 headroom = LINE_TIER50 - firstDraw;

        vm.prank(alice);
        manager.open(firstDraw, 30 days);
        vm.prank(aliceB);
        manager.open(headroom, 30 days);

        assertEq(manager.drawnByIdentity(KYC_ALICE), LINE_TIER50, "identity is fully drawn");
        assertEq(pool.outstandingPrincipal(), LINE_TIER50, "and that is all the pool lent");

        // A third attempt from either wallet, however small, is refused.
        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsCreditLine.selector, 1, 0));
        vm.prank(alice);
        manager.open(1, 30 days);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsCreditLine.selector, 1, 0));
        vm.prank(aliceB);
        manager.open(1, 30 days);
    }

    function test_NewWalletOfTheSameIdentityInheritsTheLineImmediately() public {
        address aliceC = makeAddr("aliceC");
        issueCredential(aliceC, 50, 0, KYC_ALICE);
        asset.mint(aliceC, 100_000e6);
        vm.prank(aliceC);
        asset.approve(address(manager), type(uint256).max);

        vm.prank(alice);
        manager.open(LINE_TIER50, 30 days);

        // A wallet the protocol has never seen before is already at its limit.
        assertEq(manager.quote(aliceC, 1e6, 30 days).alreadyDrawn, LINE_TIER50);
        assertEq(manager.quote(aliceC, 1e6, 30 days).maxDrawNow, 0);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsCreditLine.selector, 1e6, 0));
        vm.prank(aliceC);
        manager.open(1e6, 30 days);
    }

    function test_RepaymentByOneWalletFreesTheLineForTheOther() public {
        vm.prank(alice);
        uint256 loanId = manager.open(LINE_TIER50, 30 days);

        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsCreditLine.selector, 1_000e6, 0));
        vm.prank(aliceB);
        manager.open(1_000e6, 30 days);

        vm.prank(alice);
        manager.repay(loanId);

        vm.prank(aliceB);
        uint256 second = manager.open(1_000e6, 30 days);
        assertEq(manager.loan(second).principal, 1_000e6);
        assertEq(manager.drawnByIdentity(KYC_ALICE), 1_000e6);
    }

    function test_RegistryLinksEveryWalletThatActedUnderTheIdentity() public {
        vm.prank(alice);
        manager.open(1_000e6, 30 days);
        vm.prank(aliceB);
        manager.open(1_000e6, 30 days);
        vm.prank(alice);
        manager.open(1_000e6, 30 days); // already linked, must not duplicate

        address[] memory wallets = registry.walletsOf(KYC_ALICE);
        assertEq(wallets.length, 2, "two wallets, deduplicated");
        assertEq(wallets[0], alice);
        assertEq(wallets[1], aliceB);

        StandingRegistry.History memory h = historyOf(KYC_ALICE);
        assertEq(h.loansOriginated, 3, "three loans against one identity");
        assertEq(h.totalBorrowed, 3_000e6);
    }

    function test_DifferentIdentitiesDoNotShareALine() public {
        vm.prank(alice);
        manager.open(LINE_TIER50, 30 days);

        // A different person, same tier, is completely unaffected.
        assertEq(manager.quote(lp2, 1e6, 30 days).alreadyDrawn, 0);
        vm.prank(lp2);
        uint256 id = manager.open(LINE_TIER50, 30 days);
        assertEq(manager.loan(id).principal, LINE_TIER50);
        assertEq(manager.drawnByIdentity(KYC_LP2), LINE_TIER50);
        assertEq(manager.drawnByIdentity(KYC_ALICE), LINE_TIER50);
    }

    /// @dev A wallet holding a huge verified balance scores higher, but the extra headroom is still
    ///      netted against the identity's existing draw rather than granted afresh.
    function test_RicherWalletOfTheSameIdentityGetsHeadroomNotAFreshLine() public {
        // vip and vipB share KYC_VIP. Strip vipB's balance so the two wallets score differently.
        uint256 drain = asset.balanceOf(vipB) - 1e6;
        vm.prank(vipB);
        asset.transfer(stranger, drain);

        uint256 richLine = manager.quote(vip, 1e6, 30 days).creditLine;
        uint256 poorLine = manager.quote(vipB, 1e6, 30 days).creditLine;
        assertGt(richLine, poorLine, "the funded wallet scores higher");

        vm.prank(vip);
        manager.open(richLine, 30 days);

        // The poorer wallet's line is already more than exhausted by the identity's draw.
        assertEq(manager.quote(vipB, 1e6, 30 days).maxDrawNow, 0);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.ExceedsCreditLine.selector, 1, 0));
        vm.prank(vipB);
        manager.open(1, 30 days);
    }
}
