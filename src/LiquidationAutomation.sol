// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { LendingPool } from "./LendingPool.sol";

/// @notice Chainlink Automation upkeep for LendingPool. `checkUpkeep` is simulated off-chain by
/// Automation nodes at no on-chain gas cost, so it can afford to scan every borrower; it returns the
/// first unsafe position it finds. `performUpkeep` then liquidates just that one position on-chain.
/// @dev Holds its own reserve of `debtToken`, funded by the owner, used to repay debt on a liquidated
/// borrower's behalf — a keeper-bot capital model, not a flash-liquidation. Seized collateral accrues
/// here for the owner to withdraw (e.g. to swap back into debtToken and refill the reserve). Scanning
/// the full borrower set every check is fine at demo scale; a production upkeep would page through
/// borrowers (via checkData) to bound simulation time as the set grows.
contract LiquidationAutomation is AutomationCompatibleInterface, Ownable {
    using SafeERC20 for IERC20;

    LendingPool public immutable pool;
    IERC20 public immutable debtToken;

    event ReserveFunded(address indexed funder, uint256 amount);
    event ReserveWithdrawn(uint256 amount);
    event SeizedCollateralWithdrawn(uint256 amount);
    event LiquidationPerformed(address indexed borrower, uint256 repaid, uint256 seized);

    error NothingToLiquidate();
    error StaleTarget(address borrower);

    constructor(address initialOwner, LendingPool pool_) Ownable(initialOwner) {
        pool = pool_;
        debtToken = pool_.debtToken();
    }

    /// @notice Anyone can top up the reserve the upkeep uses to repay debt during liquidations.
    function fundReserve(uint256 amount) external {
        debtToken.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveFunded(msg.sender, amount);
    }

    function withdrawReserve(uint256 amount) external onlyOwner {
        debtToken.safeTransfer(msg.sender, amount);
        emit ReserveWithdrawn(amount);
    }

    function withdrawSeizedCollateral(uint256 amount) external onlyOwner {
        pool.collateralToken().safeTransfer(msg.sender, amount);
        emit SeizedCollateralWithdrawn(amount);
    }

    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 reserve = debtToken.balanceOf(address(this));
        if (reserve == 0) return (false, bytes(""));

        uint256 count = pool.borrowersCount();
        for (uint256 i = 0; i < count; i++) {
            address borrower = pool.borrowerAt(i);
            if (!pool.isLiquidatable(borrower)) continue;

            uint256 debt = pool.debtBalance(borrower);
            uint256 repayAmount = debt < reserve ? debt : reserve;
            return (true, abi.encode(borrower, repayAmount));
        }
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override {
        (address borrower, uint256 repayAmount) = abi.decode(performData, (address, uint256));
        if (!pool.isLiquidatable(borrower)) revert StaleTarget(borrower);

        uint256 debt = pool.debtBalance(borrower);
        if (repayAmount > debt) repayAmount = debt;
        uint256 reserve = debtToken.balanceOf(address(this));
        if (repayAmount > reserve) repayAmount = reserve;
        if (repayAmount == 0) revert NothingToLiquidate();

        debtToken.forceApprove(address(pool), repayAmount);
        uint256 seized = pool.liquidate(borrower, repayAmount);
        emit LiquidationPerformed(borrower, repayAmount, seized);
    }
}
