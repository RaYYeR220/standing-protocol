// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StandingRegistry} from "../../src/StandingRegistry.sol";

/// @notice The union-find over KYC hashes, attacked directly.
/// @dev Deployed standalone with this contract as the recorder, so every reachable argument shape
///      can be driven — including ones the credit manager would never produce. What the manager
///      *does* produce is exercised end-to-end in ReissuedCredentials.t.sol.
contract IdentityLinkingTest is Test {
    StandingRegistry internal registry;

    bytes32 internal constant A = keccak256("A");
    bytes32 internal constant B = keccak256("B");
    bytes32 internal constant C = keccak256("C");
    bytes32 internal constant D = keccak256("D");

    address internal walletA = makeAddr("walletA");
    address internal walletB = makeAddr("walletB");

    function setUp() public {
        registry = new StandingRegistry(address(this));
        registry.grantRole(registry.RECORDER_ROLE(), address(this));
    }

    function _default(bytes32 id, address wallet, uint256 amount) internal {
        registry.recordOrigination(id, wallet, amount);
        registry.recordDefault(id, wallet, amount);
    }

    function _repay(bytes32 id, address wallet, uint256 amount) internal {
        registry.recordOrigination(id, wallet, amount);
        registry.recordRepayment(id, wallet, amount, 0, 365 days);
    }

    // ------------------------------------------------------------------ the basic contract

    function test_CanonicalIdentity_IsTheIdentityItselfWhenUnlinked() public view {
        assertEq(registry.canonicalIdentity(A), A);
        assertEq(registry.supersedes(A), bytes32(0));
    }

    function test_LinkIdentity_FoldsAReissuedHashIntoTheOriginal() public {
        _default(A, walletA, 1_000e6);

        registry.linkIdentity(A, B);

        assertEq(registry.canonicalIdentity(B), A, "B resolves to A");
        assertEq(registry.supersedes(B), A);
        assertEq(registry.historyOf(B).loansDefaulted, 1, "the default follows the re-issue");
    }

    function test_LinkIdentity_MergesHistoryAccruedUnderTheNewHashBeforeItWasKnown() public {
        _default(A, walletA, 1_000e6);
        _repay(B, walletB, 500e6);

        registry.linkIdentity(A, B);

        StandingRegistry.History memory h = registry.historyOf(B);
        assertEq(h.loansDefaulted, 1, "A's default");
        assertEq(h.loansRepaid, 1, "B's repayment");
        assertEq(h.loansOriginated, 2, "both originations");
        assertEq(h.totalBorrowed, 1_500e6, "volumes summed");

        address[] memory wallets = registry.walletsOf(B);
        assertEq(wallets.length, 2, "both wallets carried over");
        assertEq(wallets[0], walletA);
        assertEq(wallets[1], walletB);
    }

    function test_LinkIdentity_IsIdempotent() public {
        _default(A, walletA, 1_000e6);
        registry.linkIdentity(A, B);
        registry.linkIdentity(A, B);
        registry.linkIdentity(A, B);

        assertEq(registry.historyOf(B).loansDefaulted, 1, "the record is not double counted");
    }

    function test_LinkIdentity_IgnoresZeroAndSelfLinks() public {
        registry.linkIdentity(bytes32(0), B);
        registry.linkIdentity(A, bytes32(0));
        registry.linkIdentity(A, A);

        assertEq(registry.supersedes(B), bytes32(0));
        assertEq(registry.supersedes(A), bytes32(0));
    }

    // ------------------------------------------------------------------ adversarial shapes

    /// @dev Once a hash is folded it cannot be re-pointed, so a link can never move an identity off
    ///      the record it already carries.
    function test_LinkIdentity_CannotRepointAnAlreadyLinkedHash() public {
        _default(A, walletA, 1_000e6);
        registry.linkIdentity(A, B);

        // C is clean. Try to make B point at C instead.
        registry.linkIdentity(C, B);

        assertEq(registry.canonicalIdentity(B), A, "still anchored to the defaulted identity");
        assertEq(registry.historyOf(B).loansDefaulted, 1, "default still attached");
    }

    function test_LinkIdentity_RefusesATwoNodeCycle() public {
        registry.linkIdentity(A, B); // B -> A
        registry.linkIdentity(B, A); // would make A -> B

        assertEq(registry.supersedes(A), bytes32(0), "A was not re-parented");
        assertEq(registry.canonicalIdentity(A), A);
        assertEq(registry.canonicalIdentity(B), A);
    }

    function test_LinkIdentity_RefusesALongerCycle() public {
        registry.linkIdentity(A, B); // B -> A
        registry.linkIdentity(B, C); // C -> canonical(B) = A
        assertEq(registry.canonicalIdentity(C), A);

        registry.linkIdentity(C, A); // would close A -> ... -> A
        assertEq(registry.supersedes(A), bytes32(0), "cycle refused");
        assertEq(registry.canonicalIdentity(A), A, "resolution still terminates");
    }

    /// @dev Linking through the normal path compresses: every new hash points straight at the root,
    ///      so a chain built forwards never deepens and the 8-hop bound is never approached.
    function test_LinkIdentity_ForwardChainsArePathCompressed() public {
        _default(A, walletA, 1_000e6);

        bytes32 prev = A;
        for (uint256 i = 0; i < 20; i++) {
            bytes32 next = keccak256(abi.encode("gen", i));
            registry.linkIdentity(prev, next);
            assertEq(registry.supersedes(next), A, "always points straight at the root");
            assertEq(registry.canonicalIdentity(next), A, "one hop");
            assertEq(registry.historyOf(next).loansDefaulted, 1, "default still attached");
            prev = next;
        }
    }

    /// @dev BUG: a chain assembled in reverse order is not compressed, and `canonicalIdentity` gives
    ///      up after eight hops. Beyond that depth resolution stops at an intermediate node and the
    ///      record at the true root becomes unreachable.
    function test_BUG_LinkIdentity_ChainDeeperThanEightHopsLosesTheRootHistory() public {
        bytes32[11] memory h;
        for (uint256 i = 0; i < 11; i++) {
            h[i] = keccak256(abi.encode("hop", i));
        }
        // The default lives at the root.
        _default(h[0], walletA, 5_000e6);

        // Build h[10]->h[9]->...->h[1]->h[0] by linking the deepest pair first, which defeats the
        // path compression that a forward-built chain gets.
        for (uint256 i = 10; i >= 1; i--) {
            registry.linkIdentity(h[i - 1], h[i]);
        }

        // Each link really is one level deep.
        assertEq(registry.supersedes(h[10]), h[9], "no compression");
        assertEq(registry.supersedes(h[1]), h[0]);

        // Eight hops from h[10] lands on h[2], not on the root.
        assertEq(registry.canonicalIdentity(h[10]), h[2], "resolution truncates at the 8-hop bound");
        assertEq(registry.historyOf(h[10]).loansDefaulted, 0, "the write-off is no longer visible");
        assertEq(registry.historyOf(h[0]).loansDefaulted, 1, "but it is still sitting at the root");
    }

    function test_LinkIdentity_ExactlyEightHopsStillResolves() public {
        bytes32[9] memory h;
        for (uint256 i = 0; i < 9; i++) {
            h[i] = keccak256(abi.encode("hop8", i));
        }
        _default(h[0], walletA, 5_000e6);
        for (uint256 i = 8; i >= 1; i--) {
            registry.linkIdentity(h[i - 1], h[i]);
        }

        assertEq(registry.canonicalIdentity(h[8]), h[0], "eight hops is fine");
        assertEq(registry.historyOf(h[8]).loansDefaulted, 1, "record intact");
    }

    // ------------------------------------------------------------------ recording resolves

    function test_RecordsAlwaysLandOnTheCanonicalIdentity() public {
        registry.linkIdentity(A, B);

        registry.recordOrigination(B, walletB, 1_000e6);
        registry.recordDefault(B, walletB, 400e6);

        assertEq(registry.historyOf(A).loansOriginated, 1, "written through to the root");
        assertEq(registry.historyOf(A).loansDefaulted, 1);
        assertEq(registry.historyOf(B).loansDefaulted, 1, "and readable from either hash");
    }

    function test_RecordRepayment_OnlyCountsAfterTheMinimumHold() public {
        uint256 minHold = registry.MIN_QUALIFYING_HOLD();

        registry.recordOrigination(A, walletA, 1_000e6);
        registry.recordRepayment(A, walletA, 1_000e6, 10e6, minHold - 1);
        assertEq(registry.historyOf(A).loansRepaid, 0, "too quick to count");
        assertEq(registry.historyOf(A).totalRepaid, 0, "and no volume either");

        registry.recordRepayment(A, walletA, 1_000e6, 10e6, minHold);
        assertEq(registry.historyOf(A).loansRepaid, 1, "counts at the boundary");
        assertEq(registry.historyOf(A).totalRepaid, 1_010e6);
    }

    function test_RecordsRejectTheZeroIdentity() public {
        vm.expectRevert(StandingRegistry.InvalidIdentity.selector);
        registry.recordOrigination(bytes32(0), walletA, 1e6);

        vm.expectRevert(StandingRegistry.InvalidIdentity.selector);
        registry.recordRepayment(bytes32(0), walletA, 1e6, 0, 365 days);

        vm.expectRevert(StandingRegistry.InvalidIdentity.selector);
        registry.recordDefault(bytes32(0), walletA, 1e6);
    }

    function test_RecordDefault_LinksTheWalletForTheReport() public {
        registry.recordDefault(A, walletA, 1_000e6);
        address[] memory wallets = registry.walletsOf(A);
        assertEq(wallets.length, 1, "a default report can name the wallet");
        assertEq(wallets[0], walletA);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev However a set of links is assembled, resolution terminates and never reverts.
    function testFuzz_CanonicalIdentity_AlwaysTerminates(bytes32[8] memory prevs, bytes32[8] memory curs)
        public
    {
        for (uint256 i = 0; i < 8; i++) {
            registry.linkIdentity(prevs[i], curs[i]);
        }
        for (uint256 i = 0; i < 8; i++) {
            bytes32 root = registry.canonicalIdentity(curs[i]);
            // Resolving the answer again must be stable, or reads would not be deterministic.
            assertEq(registry.canonicalIdentity(root), root, "canonical form is a fixed point");
        }
    }
}
