// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {StandingPool} from "../../src/StandingPool.sol";
import {ITransferObserver} from "./MockVerifiedAsset.sol";

/// @notice A borrower that re-enters the credit manager from inside its own token movements.
contract ReentrantBorrower is ITransferObserver {
    enum Mode {
        Idle,
        ReopenDuringDisbursement,
        RerepayDuringRepayment
    }

    CreditManager public immutable manager;
    IERC20 public immutable asset;
    StandingPool public immutable pool;

    Mode public mode;
    bool public reenterSucceeded;
    bool public reenterBlocked;
    bytes public reenterError;
    uint256 public attempts;
    uint256 public reentryAmount;
    uint256 public reentryTerm;
    uint256 public targetLoan;

    /// @dev What the pool reported while it was mid-disbursement.
    uint256 public poolAssetsDuringDisbursement;
    uint256 public poolOutstandingDuringDisbursement;

    constructor(CreditManager manager_, IERC20 asset_, StandingPool pool_) {
        manager = manager_;
        asset = asset_;
        pool = pool_;
        asset_.approve(address(manager_), type(uint256).max);
    }

    function borrow(uint256 amount, uint256 term, uint256 reAmount, uint256 reTerm)
        external
        returns (uint256)
    {
        reentryAmount = reAmount;
        reentryTerm = reTerm;
        mode = Mode.ReopenDuringDisbursement;
        uint256 id = manager.open(amount, term);
        mode = Mode.Idle;
        return id;
    }

    /// @dev Draw without arming the observer, so a later attack starts from clean counters.
    function borrowQuietly(uint256 amount, uint256 term) external returns (uint256) {
        return manager.open(amount, term);
    }

    function repayTwice(uint256 loanId) external {
        targetLoan = loanId;
        mode = Mode.RerepayDuringRepayment;
        manager.repay(loanId);
        mode = Mode.Idle;
    }

    function onTransfer(address from, address to, uint256) external {
        Mode m = mode;
        if (m == Mode.ReopenDuringDisbursement) {
            // The pool is paying out the first loan right now. If a second `open` can observe stale
            // state anywhere, it is here.
            if (to != address(this) || from != address(pool)) return;
            mode = Mode.Idle; // one shot
            attempts += 1;
            poolAssetsDuringDisbursement = pool.totalAssets();
            poolOutstandingDuringDisbursement = pool.outstandingPrincipal();
            try manager.open(reentryAmount, reentryTerm) returns (uint256) {
                reenterSucceeded = true;
            } catch (bytes memory err) {
                reenterBlocked = true;
                reenterError = err;
            }
        } else if (m == Mode.RerepayDuringRepayment) {
            if (to != address(pool) || from != address(this)) return;
            mode = Mode.Idle;
            attempts += 1;
            try manager.repay(targetLoan) {
                reenterSucceeded = true;
            } catch (bytes memory err) {
                reenterBlocked = true;
                reenterError = err;
            }
        }
    }
}

/// @notice An LP that redeems from inside somebody else's repayment.
/// @dev `CreditManager.repay` moves principal + interest into the pool and only *afterwards* tells
///      the pool to reduce `outstandingPrincipal`. Between those two steps `totalAssets()` counts the
///      returned principal twice. This contract measures that window, and takes it.
contract RepaymentFrontRunner is ITransferObserver {
    StandingPool public immutable pool;
    IERC20 public immutable asset;

    bool public armed;
    bool public fired;
    uint256 public totalAssetsDuringRepay;
    uint256 public sharePriceDuringRepay;
    uint256 public assetsRedeemed;
    uint256 public sharesRedeemed;

    constructor(StandingPool pool_, IERC20 asset_) {
        pool = pool_;
        asset = asset_;
        asset_.approve(address(pool_), type(uint256).max);
    }

    function lend(uint256 amount) external {
        pool.deposit(amount, address(this));
    }

    function arm() external {
        armed = true;
    }

    function onTransfer(address, address to, uint256) external {
        if (!armed || fired) return;
        if (to != address(pool)) return;
        fired = true;

        totalAssetsDuringRepay = pool.totalAssets();
        sharePriceDuringRepay = pool.convertToAssets(1e6);

        uint256 shares = pool.balanceOf(address(this));
        sharesRedeemed = shares;
        assetsRedeemed = pool.redeem(shares, address(this), address(this));
    }
}

/// @notice Deposits a dust amount, donates a large one, and eats the next depositor's money.
contract InflationAttacker {
    StandingPool public immutable pool;
    IERC20 public immutable asset;

    constructor(StandingPool pool_, IERC20 asset_) {
        pool = pool_;
        asset = asset_;
        asset_.approve(address(pool_), type(uint256).max);
    }

    function seed(uint256 dust, uint256 donation) external {
        pool.deposit(dust, address(this));
        asset.transfer(address(pool), donation); // straight transfer: never touches the gate
    }

    function cashOut() external returns (uint256) {
        return pool.redeem(pool.balanceOf(address(this)), address(this), address(this));
    }
}
