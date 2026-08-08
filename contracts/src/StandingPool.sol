// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ComplianceGate} from "./ComplianceGate.sol";

/// @title StandingPool
/// @notice The supply side: verified capital, lent to verified borrowers.
///
/// @dev An ERC-4626 vault denominated in a Cleanverse Verified Asset. Two things distinguish it
///      from an ordinary lending vault.
///
///      First, both ends are gated. A depositor must hold a live A-Pass and clear the policy engine
///      to mint shares, and must clear it again to redeem — a lender whose credential is frozen
///      between those two moments does not quietly slip out. Compliance is a property of each
///      movement, not of the account.
///
///      Second, the vault carries genuine credit risk. Loans are unsecured beyond a partial
///      collateral posting, so a default is a real loss, absorbed by the share price rather than
///      hidden in a reserve. `totalAssets` counts idle balance plus principal out on loan, which is
///      what depositors are actually exposed to.
contract StandingPool is ERC4626, AccessControl, ComplianceGate {
    using SafeERC20 for IERC20;

    bytes32 public constant CREDIT_MANAGER_ROLE = keccak256("CREDIT_MANAGER_ROLE");
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");

    /// @notice Principal currently out on loan.
    uint256 public outstandingPrincipal;

    /// @notice Interest returned to depositors since inception.
    uint256 public lifetimeInterest;

    /// @notice Principal written off since inception.
    uint256 public lifetimeLosses;

    /// @notice The share of pool assets that may be out on loan at once, in basis points.
    /// @dev Bounds how much of the book a run of defaults can touch, and keeps redemption liquid.
    uint256 public maxUtilizationBps = 8000;

    event LoanFunded(address indexed borrower, uint256 amount);
    event RepaymentSettled(uint256 principal, uint256 interest);
    event LossAbsorbed(uint256 principal);
    event MaxUtilizationSet(uint256 bps);

    error UtilizationExceeded(uint256 requested, uint256 available);
    error InvalidParameter();

    constructor(address asset_, address apassRegistry_, address policy_, address admin)
        ERC20("Standing Pool aUSDC", "stdaUSDC")
        ERC4626(IERC20(asset_))
        ComplianceGate(apassRegistry_, policy_, asset_, admin)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------- accounting

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + outstandingPrincipal;
    }

    /// @notice Assets available to be lent or redeemed right now.
    function availableLiquidity() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Current utilization in basis points.
    function utilizationBps() public view returns (uint256) {
        uint256 assets = totalAssets();
        if (assets == 0) return 0;
        return (outstandingPrincipal * 10_000) / assets;
    }

    // ---------------------------------------------------------------- compliance-gated ERC-4626

    /// @dev The compliance gate deliberately does NOT live in `maxDeposit`. ERC-4626 makes callers
    ///      revert with `ERC4626ExceededMaxDeposit` when they exceed the reported maximum, which
    ///      would swallow the actual reason a lender was refused. The gate is enforced in
    ///      `_deposit`, where it can revert with `NotCompliant` and name the failing condition;
    ///      front ends preflight with {checkTransferDetailed} instead of inferring from a cap.

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 assets = super.maxWithdraw(owner);
        uint256 liquid = availableLiquidity();
        return assets < liquid ? assets : liquid;
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 shares = super.maxRedeem(owner);
        uint256 liquidShares = _convertToShares(availableLiquidity(), Math.Rounding.Floor);
        return shares < liquidShares ? shares : liquidShares;
    }

    /// @dev The supply side of the gate: capital may only enter from a verified lender.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        _requireCompliant(caller, receiver, assets);
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev And may only leave to one — checked again at redemption against live credential state.
    ///      All three roles are checked, not just the recipient: a lender whose credential is frozen
    ///      cannot exit by nominating a second wallet of their own as receiver, and cannot have a
    ///      third party redeem on their behalf. The owner of the shares is a party to the exit even
    ///      though no asset moves to them.
    function _withdraw(
        address caller,
        address receiver,
        address shareOwner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _requireParty(shareOwner);
        if (caller != shareOwner) _requireParty(caller);
        _requireCompliant(address(this), receiver, assets);
        super._withdraw(caller, receiver, shareOwner, assets, shares);
    }

    /// @dev Pool shares are a claim on verified assets, so they are gated like the assets are.
    ///      Without this the vault leaks: a frozen lender transfers their shares to an
    ///      uncredentialed address, which redeems through any compliant receiver, and the
    ///      credential check at the door has bought nothing.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            _requireParty(from);
            _requireParty(to);
        }
        super._update(from, to, value);
    }

    /// @dev Virtual shares, per OpenZeppelin's inflation-attack mitigation. The vault's asset
    ///      balance is readable by anyone and a plain transfer into it moves the share price, so the
    ///      first depositor is otherwise grief-able down to zero shares.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ---------------------------------------------------------------- credit manager hooks

    /// @notice Sends principal to a borrower the credit manager has already underwritten.
    /// @dev The pool does not re-underwrite; it enforces its own liquidity and utilization limits
    ///      and nothing else. Identity and policy were checked by the manager on the same call.
    function fundLoan(address borrower, uint256 amount) external onlyRole(CREDIT_MANAGER_ROLE) {
        uint256 assets = totalAssets();
        uint256 ceiling = (assets * maxUtilizationBps) / 10_000;
        if (outstandingPrincipal + amount > ceiling) {
            revert UtilizationExceeded(outstandingPrincipal + amount, ceiling);
        }
        outstandingPrincipal += amount;
        IERC20(asset()).safeTransfer(borrower, amount);
        emit LoanFunded(borrower, amount);
    }

    /// @notice Books a repayment. The assets themselves are transferred in by the credit manager.
    function settleRepayment(uint256 principal, uint256 interest)
        external
        onlyRole(CREDIT_MANAGER_ROLE)
    {
        outstandingPrincipal -= principal;
        lifetimeInterest += interest;
        emit RepaymentSettled(principal, interest);
    }

    /// @notice Writes off principal that will not be returned.
    /// @dev Reduces `totalAssets`, so the loss lands on the share price and is shared across
    ///      depositors in proportion to their stake. There is no reserve to hide it in.
    function absorbLoss(uint256 principal) external onlyRole(CREDIT_MANAGER_ROLE) {
        outstandingPrincipal -= principal;
        lifetimeLosses += principal;
        emit LossAbsorbed(principal);
    }

    // ---------------------------------------------------------------- risk admin

    function setMaxUtilizationBps(uint256 bps) external onlyRole(RISK_ADMIN_ROLE) {
        if (bps == 0 || bps > 10_000) revert InvalidParameter();
        maxUtilizationBps = bps;
        emit MaxUtilizationSet(bps);
    }

}
