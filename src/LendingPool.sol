// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { PriceFeedOracle } from "./PriceFeedOracle.sol";

/// @notice Minimal single-collateral, single-debt-asset money market. Chainlink Data Feeds (via
/// PriceFeedOracle) price both assets; Chainlink Automation liquidates unsafe positions (see
/// LiquidationAutomation); Chainlink CCIP lets collateral originating on another chain be deposited here
/// on a user's behalf (see CrossChainCollateralRouter).
/// @dev Both `collateralToken` and `debtToken` are assumed to use 18 decimals (WETH/DAI-style), which
/// keeps the USD-value math simple — an explicit scope decision, not an oversight; a production market
/// would read each token's decimals and normalize. Interest accrual is intentionally out of scope: the
/// point of this contract is the three Chainlink integration points above, not a full money-market
/// implementation.
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    PriceFeedOracle public immutable oracle;

    /// @notice Max USD-value a borrower can draw per USD-value of collateral, in basis points.
    uint256 public constant MAX_LTV_BPS = 7_500;
    /// @notice Health-factor threshold (basis points of collateral value) below which a position is
    /// liquidatable. Set above MAX_LTV_BPS so a position always has room to sit safely above the max
    /// borrow LTV before it crosses into the liquidatable zone.
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    /// @notice Extra collateral, as bps of the repaid debt's USD value, awarded to whoever liquidates.
    uint256 public constant LIQUIDATION_BONUS_BPS = 1_000;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant HEALTH_FACTOR_PRECISION = 1e18;

    mapping(address user => uint256) public collateralBalance;
    mapping(address user => uint256) public debtBalance;
    uint256 public totalSupplied;
    uint256 public totalBorrowed;

    /// @dev Borrowers with nonzero debt, so LiquidationAutomation's checkUpkeep has a bounded set to scan
    /// instead of needing an off-chain indexer.
    EnumerableSet.AddressSet private _borrowers;

    /// @notice Contracts allowed to call `depositCollateralFor` — i.e. CrossChainCollateralRouter
    /// instances that have already received tokens via CCIP on a user's behalf.
    mapping(address depositor => bool) public trustedDepositors;

    event Supplied(address indexed supplier, uint256 amount);
    event SupplyWithdrawn(address indexed supplier, uint256 amount);
    event CollateralDeposited(address indexed user, uint256 amount, bool viaTrustedDepositor);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed payer, address indexed borrower, uint256 amount);
    event Liquidated(
        address indexed liquidator, address indexed borrower, uint256 repaidDebt, uint256 seizedCollateral
    );
    event TrustedDepositorSet(address indexed depositor, bool trusted);

    error ZeroAmount();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error ExceedsMaxLtv();
    error PositionHealthy();
    error RepayExceedsDebt();
    error NotTrustedDepositor();

    constructor(address initialOwner, IERC20 collateralToken_, IERC20 debtToken_, PriceFeedOracle oracle_)
        Ownable(initialOwner)
    {
        collateralToken = collateralToken_;
        debtToken = debtToken_;
        oracle = oracle_;
    }

    // ---------------------------------------------------------------------
    // Lender-side liquidity
    // ---------------------------------------------------------------------

    function supply(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        totalSupplied += amount;
        debtToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(msg.sender, amount);
    }

    function withdrawSupply(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > availableLiquidity()) revert InsufficientLiquidity();
        totalSupplied -= amount;
        debtToken.safeTransfer(msg.sender, amount);
        emit SupplyWithdrawn(msg.sender, amount);
    }

    function availableLiquidity() public view returns (uint256) {
        return debtToken.balanceOf(address(this));
    }

    // ---------------------------------------------------------------------
    // Borrower-side collateral & debt
    // ---------------------------------------------------------------------

    function depositCollateral(uint256 amount) external nonReentrant {
        _creditCollateral(msg.sender, amount);
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, amount, false);
    }

    /// @notice Credits collateral to `user` by pulling tokens from the caller, which must already hold
    /// them and be an allowlisted trusted depositor (see CrossChainCollateralRouter, which receives
    /// tokens via CCIP before calling this on the depositor's behalf).
    function depositCollateralFor(address user, uint256 amount) external nonReentrant {
        if (!trustedDepositors[msg.sender]) revert NotTrustedDepositor();
        _creditCollateral(user, amount);
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(user, amount, true);
    }

    function _creditCollateral(address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        collateralBalance[user] += amount;
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = collateralBalance[msg.sender];
        if (amount > balance) revert InsufficientCollateral();
        uint256 newBalance = balance - amount;

        if (_healthFactor(debtBalance[msg.sender], newBalance) < HEALTH_FACTOR_PRECISION) {
            revert ExceedsMaxLtv();
        }

        collateralBalance[msg.sender] = newBalance;
        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > availableLiquidity()) revert InsufficientLiquidity();

        uint256 newDebt = debtBalance[msg.sender] + amount;
        uint256 collateralValue = oracle.usdValue(address(collateralToken), collateralBalance[msg.sender]);
        uint256 newDebtValue = oracle.usdValue(address(debtToken), newDebt);
        if (newDebtValue * BPS_DENOMINATOR > collateralValue * MAX_LTV_BPS) revert ExceedsMaxLtv();

        debtBalance[msg.sender] = newDebt;
        totalBorrowed += amount;
        _borrowers.add(msg.sender);

        debtToken.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        _repay(msg.sender, msg.sender, amount);
    }

    /// @notice Repay on behalf of another borrower, e.g. a keeper bot topping up a position instead of
    /// liquidating it.
    function repayFor(address borrower, uint256 amount) external nonReentrant {
        _repay(msg.sender, borrower, amount);
    }

    function _repay(address payer, address borrower, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 debt = debtBalance[borrower];
        if (amount > debt) revert RepayExceedsDebt();

        uint256 remaining = debt - amount;
        debtBalance[borrower] = remaining;
        totalBorrowed -= amount;
        if (remaining == 0) _borrowers.remove(borrower);

        debtToken.safeTransferFrom(payer, address(this), amount);
        emit Repaid(payer, borrower, amount);
    }

    // ---------------------------------------------------------------------
    // Liquidation — called directly, or by LiquidationAutomation via Chainlink Automation
    // ---------------------------------------------------------------------

    /// @notice Repays up to `repayAmount` of `borrower`'s debt and seizes the equivalent collateral plus
    /// the liquidation bonus from `borrower`, crediting it to the caller.
    /// @dev If a borrower's collateral is worth less than the bonus-adjusted seize value — a bad-debt
    /// position, e.g. after a sharp price move outpaces liquidation — the liquidator receives whatever
    /// collateral remains rather than the full entitlement. A production system would additionally
    /// socialize the resulting shortfall across suppliers; that's out of scope here.
    function liquidate(address borrower, uint256 repayAmount) external nonReentrant returns (uint256 seizedCollateral) {
        if (repayAmount == 0) revert ZeroAmount();
        uint256 debt = debtBalance[borrower];
        if (repayAmount > debt) revert RepayExceedsDebt();
        uint256 collateral = collateralBalance[borrower];
        if (_healthFactor(debt, collateral) >= HEALTH_FACTOR_PRECISION) revert PositionHealthy();

        uint256 repaidValue = oracle.usdValue(address(debtToken), repayAmount);
        uint256 collateralPrice = oracle.getPrice(address(collateralToken));
        uint256 seizeValue = (repaidValue * (BPS_DENOMINATOR + LIQUIDATION_BONUS_BPS)) / BPS_DENOMINATOR;
        // Each division here rounds down, so seizedCollateral can only undershoot the liquidator's exact
        // entitlement by a negligible dust amount, never seize more of a borrower's collateral than it
        // should — the safe direction for this math to drift.
        seizedCollateral = (seizeValue * 1e18) / collateralPrice;
        if (seizedCollateral > collateral) seizedCollateral = collateral;

        uint256 remaining = debt - repayAmount;
        debtBalance[borrower] = remaining;
        totalBorrowed -= repayAmount;
        collateralBalance[borrower] = collateral - seizedCollateral;
        if (remaining == 0) _borrowers.remove(borrower);

        debtToken.safeTransferFrom(msg.sender, address(this), repayAmount);
        collateralToken.safeTransfer(msg.sender, seizedCollateral);

        emit Liquidated(msg.sender, borrower, repayAmount, seizedCollateral);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @return Health factor scaled to 1e18; below 1e18 means liquidatable. Returns type(uint256).max for
    /// a position with no debt.
    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(debtBalance[user], collateralBalance[user]);
    }

    function isLiquidatable(address user) public view returns (bool) {
        if (debtBalance[user] == 0) return false;
        return _healthFactor(debtBalance[user], collateralBalance[user]) < HEALTH_FACTOR_PRECISION;
    }

    function borrowersCount() external view returns (uint256) {
        return _borrowers.length();
    }

    function borrowerAt(uint256 index) external view returns (address) {
        return _borrowers.at(index);
    }

    function _healthFactor(uint256 debt, uint256 collateral) internal view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = oracle.usdValue(address(collateralToken), collateral);
        uint256 debtValue = oracle.usdValue(address(debtToken), debt);
        return (collateralValue * LIQUIDATION_THRESHOLD_BPS * HEALTH_FACTOR_PRECISION) / (debtValue * BPS_DENOMINATOR);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setTrustedDepositor(address depositor, bool trusted) external onlyOwner {
        trustedDepositors[depositor] = trusted;
        emit TrustedDepositorSet(depositor, trusted);
    }
}
