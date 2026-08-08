// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ComplianceGate} from "./ComplianceGate.sol";
import {StandingPool} from "./StandingPool.sol";
import {StandingRegistry} from "./StandingRegistry.sol";
import {ApassReader} from "./libraries/ApassReader.sol";
import {StandingMath} from "./libraries/StandingMath.sol";

/// @title CreditManager
/// @notice Originates under-collateralized credit against a verified identity.
///
/// @dev The premise of the protocol is that a bank-verified, revocable credential is worth
///      something as security — that a borrower who defaults loses standing that follows them
///      across wallets and across the network, and that this is enough to lend against without
///      full collateral.
///
///      Which means this contract is the place where a wrong answer costs real money, so it is
///      written to be un-persuadable. Terms come out of {StandingMath} from on-chain state alone.
///      Above that sit hard ceilings fixed at deployment — a maximum principal, a maximum term, a
///      maximum rate, a maximum line per identity — that no role, no signature and no upgrade path
///      can raise. An operator may make this contract stricter. Nobody can make it more generous.
///
///      Exposure is tracked per identity rather than per wallet. A borrower who opens a second
///      wallet does not get a second credit line; the A-Pass KYC hash is the same, so the line is
///      the same one, already partly drawn.
contract CreditManager is ComplianceGate, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StandingMath for uint256;

    bytes32 public constant SERVICER_ROLE = keccak256("SERVICER_ROLE");

    enum Status {
        None,
        Active,
        Repaid,
        Defaulted
    }

    struct Loan {
        address borrower;
        bytes32 kycHash;
        uint128 principal;
        uint128 collateral;
        uint128 interestDue;
        uint64 openedAt;
        uint64 dueAt;
        uint16 aprBps;
        Status status;
    }

    /// @notice What the protocol would offer a borrower right now, and why.
    struct Quote {
        bool approved;
        Refusal refusal;
        uint256 score;
        uint256 creditLine;
        uint256 alreadyDrawn;
        uint256 maxDrawNow;
        uint256 collateralRequired;
        uint256 aprBps;
        uint256 interestForTerm;
        StandingMath.Breakdown breakdown;
    }

    StandingPool public immutable pool;
    StandingRegistry public immutable registry;

    /// @notice Ceilings fixed at deployment. Immutable by design: see the contract note.
    uint256 public immutable maxLoanPrincipal;
    uint256 public immutable maxCreditLine;
    uint256 public immutable maxTermSeconds;

    uint256 public constant MIN_TERM_SECONDS = 1 days;

    /// @notice How long after maturity a borrower has before the loan can be written off.
    uint256 public constant GRACE_PERIOD = 3 days;

    uint256 private _nextLoanId = 1;
    mapping(uint256 loanId => Loan) private _loans;

    /// @notice Principal outstanding per identity, not per wallet.
    mapping(bytes32 kycHash => uint256) public drawnByIdentity;
    mapping(bytes32 kycHash => uint256[]) private _loansByIdentity;

    event LoanOpened(
        uint256 indexed loanId,
        address indexed borrower,
        bytes32 indexed kycHash,
        uint256 principal,
        uint256 collateral,
        uint256 aprBps,
        uint256 dueAt,
        uint256 score
    );
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 principal, uint256 interest);
    event LoanDefaulted(
        uint256 indexed loanId,
        address indexed borrower,
        bytes32 indexed kycHash,
        uint256 principalLost,
        uint256 collateralSeized
    );
    /// @notice Emitted alongside a default so an operator can pursue the identity off-chain.
    /// @dev The point of lending against a bank-verified credential is that recourse does not end
    ///      at the chain boundary. This is the hook that carries a write-off into that process.
    event DefaultReportOpened(
        uint256 indexed loanId, bytes32 indexed kycHash, address indexed borrower, uint256 amountOwed
    );

    error BelowMinimumStanding(uint256 score, uint256 required);
    error ExceedsCreditLine(uint256 requested, uint256 available);
    error ExceedsLoanCeiling(uint256 requested, uint256 ceiling);
    error InvalidTerm(uint256 term);
    error LoanNotActive(uint256 loanId);
    error NotYetDefaulted(uint256 loanId, uint256 defaultableAt);
    error NotBorrower();
    error NoIdentity();

    constructor(
        address pool_,
        address registry_,
        address apassRegistry_,
        address policy_,
        address asset_,
        address admin,
        uint256 maxLoanPrincipal_,
        uint256 maxCreditLine_,
        uint256 maxTermSeconds_
    ) ComplianceGate(apassRegistry_, policy_, asset_) {
        pool = StandingPool(pool_);
        registry = StandingRegistry(registry_);
        maxLoanPrincipal = maxLoanPrincipal_;
        maxCreditLine = maxCreditLine_;
        maxTermSeconds = maxTermSeconds_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SERVICER_ROLE, admin);
    }

    // ---------------------------------------------------------------- underwriting (view)

    /// @notice The full underwriting decision for a borrower, without touching state.
    /// @dev Deliberately returns the whole breakdown rather than a yes/no. A borrower refused
    ///      credit is entitled to see which input refused them, and a lender is entitled to see
    ///      what the line was granted on.
    function quote(address borrower, uint256 amount, uint256 termSeconds)
        public
        view
        returns (Quote memory q)
    {
        (bool allowed, Refusal reason) = checkTransfer(address(pool), borrower, amount);
        q.refusal = reason;

        ApassReader.Credential memory c = credentialOf(borrower);
        StandingRegistry.History memory h = registry.historyOf(c.kycHash);
        uint256 balance = IERC20(verifiedAsset).balanceOf(borrower);

        q.breakdown = StandingMath.score(c, h, balance, block.timestamp);
        q.score = q.breakdown.score;

        StandingMath.Terms memory t = StandingMath.terms(q.score, maxCreditLine);
        q.creditLine = t.creditLine;
        q.aprBps = t.aprBps;
        q.alreadyDrawn = drawnByIdentity[c.kycHash];

        uint256 headroom = t.creditLine > q.alreadyDrawn ? t.creditLine - q.alreadyDrawn : 0;
        if (headroom > maxLoanPrincipal) headroom = maxLoanPrincipal;
        uint256 liquidity = pool.availableLiquidity();
        if (headroom > liquidity) headroom = liquidity;
        q.maxDrawNow = headroom;

        q.collateralRequired = (amount * t.collateralBps) / 10_000;
        q.interestForTerm = _interest(amount, t.aprBps, termSeconds);

        q.approved = allowed && t.eligible && c.kycHash != bytes32(0) && amount > 0
            && amount <= q.maxDrawNow && termSeconds >= MIN_TERM_SECONDS && termSeconds <= maxTermSeconds;
    }

    // ---------------------------------------------------------------- origination

    /// @notice Draws an under-collateralized loan against the caller's standing.
    /// @param amount Principal requested, in verified-asset units.
    /// @param termSeconds Loan term.
    /// @dev Order matters. Compliance is evaluated first and against live state, so a disbursement
    ///      that would breach policy is refused before any value moves rather than unwound after.
    function open(uint256 amount, uint256 termSeconds) external nonReentrant returns (uint256 loanId) {
        _requireCompliant(address(pool), msg.sender, amount);

        if (termSeconds < MIN_TERM_SECONDS || termSeconds > maxTermSeconds) revert InvalidTerm(termSeconds);
        if (amount == 0 || amount > maxLoanPrincipal) revert ExceedsLoanCeiling(amount, maxLoanPrincipal);

        ApassReader.Credential memory c = credentialOf(msg.sender);
        if (c.kycHash == bytes32(0)) revert NoIdentity();

        StandingRegistry.History memory h = registry.historyOf(c.kycHash);
        uint256 balance = IERC20(verifiedAsset).balanceOf(msg.sender);
        StandingMath.Breakdown memory b = StandingMath.score(c, h, balance, block.timestamp);
        if (b.score < StandingMath.MIN_SCORE) revert BelowMinimumStanding(b.score, StandingMath.MIN_SCORE);

        StandingMath.Terms memory t = StandingMath.terms(b.score, maxCreditLine);
        uint256 drawn = drawnByIdentity[c.kycHash];
        uint256 headroom = t.creditLine > drawn ? t.creditLine - drawn : 0;
        if (amount > headroom) revert ExceedsCreditLine(amount, headroom);

        uint256 collateral = (amount * t.collateralBps) / 10_000;
        uint256 interest = _interest(amount, t.aprBps, termSeconds);

        loanId = _nextLoanId++;
        _loans[loanId] = Loan({
            borrower: msg.sender,
            kycHash: c.kycHash,
            principal: uint128(amount),
            collateral: uint128(collateral),
            interestDue: uint128(interest),
            openedAt: uint64(block.timestamp),
            dueAt: uint64(block.timestamp + termSeconds),
            aprBps: uint16(t.aprBps),
            status: Status.Active
        });
        _loansByIdentity[c.kycHash].push(loanId);
        drawnByIdentity[c.kycHash] = drawn + amount;

        if (collateral > 0) {
            IERC20(verifiedAsset).safeTransferFrom(msg.sender, address(this), collateral);
        }
        registry.recordOrigination(c.kycHash, msg.sender, amount);
        pool.fundLoan(msg.sender, amount);

        emit LoanOpened(
            loanId, msg.sender, c.kycHash, amount, collateral, t.aprBps, block.timestamp + termSeconds, b.score
        );
    }

    // ---------------------------------------------------------------- servicing

    /// @notice Repays a loan in full and returns any collateral posted.
    function repay(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.status != Status.Active) revert LoanNotActive(loanId);
        if (msg.sender != l.borrower) revert NotBorrower();

        uint256 principal = l.principal;
        uint256 interest = l.interestDue;
        uint256 collateral = l.collateral;

        // The repayment leg is a value movement too, and is checked like any other.
        _requireCompliant(msg.sender, address(pool), principal + interest);

        l.status = Status.Repaid;
        drawnByIdentity[l.kycHash] -= principal;

        IERC20(verifiedAsset).safeTransferFrom(msg.sender, address(pool), principal + interest);
        pool.settleRepayment(principal, interest);

        if (collateral > 0) {
            IERC20(verifiedAsset).safeTransfer(l.borrower, collateral);
        }
        registry.recordRepayment(l.kycHash, msg.sender, principal, interest);

        emit LoanRepaid(loanId, msg.sender, principal, interest);
    }

    /// @notice Writes off a matured, unpaid loan.
    /// @dev Permissionless once the grace period has passed. Recognising a bad debt should not
    ///      depend on an operator choosing to recognise it, and depositors are entitled to have the
    ///      loss booked against the share price the moment it is real.
    function markDefault(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.status != Status.Active) revert LoanNotActive(loanId);

        uint256 defaultableAt = uint256(l.dueAt) + GRACE_PERIOD;
        if (block.timestamp < defaultableAt) revert NotYetDefaulted(loanId, defaultableAt);

        uint256 principal = l.principal;
        uint256 collateral = l.collateral;

        l.status = Status.Defaulted;
        drawnByIdentity[l.kycHash] -= principal;

        // Collateral covers what it covers; the shortfall is a real loss to depositors.
        uint256 recovered = collateral > principal ? principal : collateral;
        uint256 shortfall = principal - recovered;

        if (recovered > 0) {
            IERC20(verifiedAsset).safeTransfer(address(pool), recovered);
            pool.settleRepayment(recovered, 0);
        }
        if (shortfall > 0) {
            pool.absorbLoss(shortfall);
        }
        if (collateral > recovered) {
            IERC20(verifiedAsset).safeTransfer(l.borrower, collateral - recovered);
        }

        // The standing hit is the actual security behind the loan: it is written against the
        // identity, so it survives the borrower abandoning this wallet.
        registry.recordDefault(l.kycHash, l.borrower, shortfall);

        emit LoanDefaulted(loanId, l.borrower, l.kycHash, shortfall, recovered);
        emit DefaultReportOpened(loanId, l.kycHash, l.borrower, shortfall + l.interestDue);
    }

    // ---------------------------------------------------------------- views

    function loan(uint256 loanId) external view returns (Loan memory) {
        return _loans[loanId];
    }

    function loansOfIdentity(bytes32 kycHash) external view returns (uint256[] memory) {
        return _loansByIdentity[kycHash];
    }

    function loanCount() external view returns (uint256) {
        return _nextLoanId - 1;
    }

    /// @notice Whether a loan is past its grace period and can be written off.
    function isDefaultable(uint256 loanId) external view returns (bool) {
        Loan memory l = _loans[loanId];
        return l.status == Status.Active && block.timestamp >= uint256(l.dueAt) + GRACE_PERIOD;
    }

    function _interest(uint256 principal, uint256 aprBps, uint256 termSeconds)
        private
        pure
        returns (uint256)
    {
        return (principal * aprBps * termSeconds) / (10_000 * 365 days);
    }
}
