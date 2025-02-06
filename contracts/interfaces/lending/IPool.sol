// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {IRouter} from "./IRouter.sol";
import {IInterestRateModel} from "./IInterestRateModel.sol";

interface IPool {

    error InvalidCap();
    error InvalidPercentage();
    error DebtPositionIsClosed();
    error ZeroAmountNotAllowed();
    error ExceedsCap();
    error NoUnborrowedUnderlying();
    error CallerIsNotRouter();

    event Supplied(address indexed account, address indexed supplyFor, uint256 depositedUnderlying, uint256 mintedTeaToken);
    event Withdrew(address indexed account, address indexed WithdrawTo, uint256 withdrawalFee, uint256 withdrawnUnderlying, uint256 burntTeaToken);
    event FeeClaimed(address indexed account, uint256 claimedFee);
    event Borrowed(address indexed account, uint256 indexed id, uint256 underlyingAmount, uint256 borrowedTeaTokenAmount);
    event Repaid(address indexed account, uint256 indexed id, uint256 teaTokenAmount, uint256 repaidUnderlyingAmount);
    event InterestAccumulated(uint256 timestamp, uint256 interest);
    event BorrowFeeAccumulated(uint256 timestamp, uint256 fee);

    /// @notice Info of borrow position
    /// @param isClosed Position is closed or not
    /// @param borrowedTeaToken Amount of borrowed interest-bearing tokens
    struct DebtInfo {
        bool isClosed;
        uint256 borrowedTeaToken;
    }

    /// @notice Pause operations for this lending pool
    /// @notice Only owner can call this function
    function pause() external;

    /// @notice Unpause operations for this lending pool
    /// @notice Only owner can call this function
    function unpause() external;

    /// @notice Limit supply amount of the lending pool
    /// @notice Only owner can call this function
    /// @param cap Supply cap of the lending pool
    function setSupplyCap(uint256 cap) external;
    
    /// @notice Limit borrow amount of the lending pool
    /// @notice Only owner can call this function
    /// @param cap Borrow cap of the lending pool
    function setBorrowCap(uint256 cap) external;
    
    /// @notice Reserve tokens for instant withdrawing
    /// @notice A ratio of supplied tokens will keep in lending pool and cannot be borrowed
    /// @notice Only owner can call this function
    /// @param ratio Reserve ratio of the lending pool
    function setReserveRatio(uint24 ratio) external;
    
    /// @notice Get the address of the used interest rate model
    /// @return interestRateModel The address of the used interest rate model
    function getInterestRateModel() external view returns (IInterestRateModel);
    
    /// @notice Supply tokens to the lending pool and mint interest-bearing tokens
    /// @notice Only lending router can call this function
    /// @param account Supplied tokens come from this account, must approve to the lending pool before supplying
    /// @param supplyFor Minted interest-bearing tokens go to this account
    /// @param amount Amount of underlying tokens to supply
    /// @return depositedUnderlying Actual supplied amount of underlying tokens
    /// @return mintedTeaToken Amount of minted interest-bearing tokens
    function supply(address account, address supplyFor, uint256 amount) external returns (uint256 depositedUnderlying, uint256 mintedTeaToken);
    
    /// @notice Withdraw tokens supplied before and burn interest-bearing tokens
    /// @notice Only lending router can call this function
    /// @param account Burnt interest-bearing tokens from to this account
    /// @param withdrawTo Withdrawn tokens go to this account
    /// @param amount Expected burnt amount of interest-bearing tokens, actual burnt amount may be affected by current lending status
    /// @return withdrawnUnderlying Actual withdrawn amount of underlying tokens
    /// @return burntTeaToken Amount of burnt interest-bearing tokens
    function withdraw(address account, address withdrawTo, uint256 amount) external returns (uint256 withdrawnUnderlying, uint256 burntTeaToken);
    
    /// @notice Claim borrow fee to the treasury, actual claimed amount may be affected by lending status
    /// @return claimedFee Claimed borrow fee
    /// @return unclaimedFee Unclaimed borrow fee
    function claimFee() external returns (uint256 claimedFee, uint256 unclaimedFee);

    /// @notice Get status of unclaimed borrow fee
    /// @return unclaimedFee All pending borrow fee
    /// @return claimableFee Actual claimable fee, take current lending status into account
    function getUnclaimedFee() external view returns (uint256 unclaimedFee, uint256 claimableFee);

    /// @notice Get supply quota based on current lending status
    /// @return quota Current supply quota
    function getSupplyQuota() external view returns (uint256 quota);
    
    /// @notice Get withdraw quota based on current lending status
    /// @return quota Current withdraw quota
    function getWithdrawQuota() external view returns (uint256 quota);

    /// @notice Borrow and transfer token directly without accounting, need to call commitBorrow to finish final accouting
    /// @notice Only lending router can call this function
    /// @param account Borrowed tokens go to this account
    /// @param amountToBorrow Amount of underlying tokens to borrow
    function borrow(address account, uint256 amountToBorrow) external;
    
    /// @notice Finish borrow accounting and check whether all conditions are met for this borrow
    /// @notice Only lending router can call this function
    /// @param account Account that borrows tokens
    /// @param amountToBorrow Amount of underlying tokens to borrow
    /// @return id Borrow id of the lending position
    function commitBorrow(address account, uint256 amountToBorrow) external returns (uint256 id);
    
    /// @notice Repay debt for a lending position
    /// @param account Repaid token from this account
    /// @param id Borrow id of the lending position
    /// @param amount Amount of interest-bearing tokens to repay
    /// @param forceClose Force close the lending position even it's not fully repaid
    /// @return repaidUnderlyingAmount Repaid amount of underlying tokens
    /// @return unrepaidUnderlyingAmount Unrepaid amount of underlying tokens
    function repay(address account, uint256 id, uint256 amount, bool forceClose) external returns (uint256 repaidUnderlyingAmount, uint256 unrepaidUnderlyingAmount);
    
    /// @notice Get interest-bearing tokens supplied by the account
    /// @param account Query account
    /// @return teaTokenAmount Amount of supplied interest-bearing tokens
    function balanceOf(address account) external view returns (uint256 teaTokenAmount);
    
    /// @notice Get underlying tokens supplied by the account
    /// @param account Query account
    /// @return underlyingAmount Amount of supplied underlying tokens
    function balanceOfUnderlying(address account) external view returns (uint256 underlyingAmount);
    
    /// @notice Get interest-bearing tokens owed by the position
    /// @param id Borrow id of the lending position
    /// @return teaTokenAmount Amount of borrowed interest-bearing tokens
    function debtOf(uint256 id) external view returns (uint256 teaTokenAmount);
    
    /// @notice Get underlying tokens owed by the account
    /// @param id Borrow id of the lending position
    /// @return underlyingAmount Amount of borrowed underlying tokens
    function debtOfUnderlying(uint256 id) external view returns (uint256 underlyingAmount);
    
    /// @notice Get supplied and borrowed interest-bearing token to underlying token conversion rate
    /// @return suppiedConversionRate Supplied interest-bearing token to underlying token conversion rate
    /// @return borrowedConversionRate Borrowed interest-bearing token to underlying token conversion rate
    function getConversionRates() external view returns (uint256 suppiedConversionRate, uint256 borrowedConversionRate);

    /// @notice Get current lending status
    /// @return suppliedUnderlying Total supplied amount of underlying tokens
    /// @return borrowedUnderlying Total borrowed amount of underlying tokens
    /// @return unclaimedFee All pending borrow fee
    /// @return reserveRatio Reserve ratio
    function getLendingStatus() external view returns (uint256 suppliedUnderlying, uint256 borrowedUnderlying, uint256 unclaimedFee, uint24 reserveRatio);
    
    /// @notice Collect interest and borrow fee, and do accouting.
    /// @return interest Amount of interest
    /// @return fee Amount of borrow fee
    function collectInterestFeeAndCommit() external returns (uint256 interest, uint256 fee);

}