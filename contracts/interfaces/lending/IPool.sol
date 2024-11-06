// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {IRouter} from "./IRouter.sol";
import {IInterestRateModel} from "./IInterestRateModel.sol";

interface IPool {

    error InvalidCap();
    error InvalidPercentage();
    error ZeroAmountNotAllowed();
    error ExceedsCap();
    error NoUnborrowedUnderlying();
    error CallerIsNotRouter();

    event Supplied(address indexed account, address indexed supplyFor, uint256 depositedUnderlying, uint256 mintedTeaToken);
    event Withdrew(address indexed account, address indexed WithdrawTo, uint256 withdrawnUnderlying, uint256 burntTeaToken);
    event FeeClaimed(address indexed account, uint256 claimedFee);
    event Borrowed(address indexed account, uint256 indexed id, uint256 underlyingAmount, uint256 borrowedTeaTokenAmount);
    event Repaid(address indexed account, uint256 indexed id, uint256 teaTokenAmount, uint256 repaidUnderlyingAmount);
    event InterestAccumulated(uint256 timestamp, uint256 interest);
    event BorrowFeeAccumulated(uint256 timestamp, uint256 fee);


    struct DebtInfo {
        bool isClosed;
        uint256 borrowedTeaToken;
        uint256 lastBorrowedConversionRate;
    }

    /// @notice Pause operations for this lending pool
    function pause() external;

    /// @notice Unpause operations for this lending pool
    function unpause() external;

    
    function setSupplyCap(uint256 cap) external;
    
    
    function setBorrowCap(uint256 cap) external;
    
    
    function setReserveRatio(uint24 ratio) external;
    
    
    function getInterestRateModel() external view returns (IInterestRateModel);
    
    
    function supply(address account, address supplyFor, uint256 amount) external returns (uint256 depositedUnderlying, uint256 mintedTeaToken);
    
    
    function withdraw(address account, address withdrawTo, uint256 amount) external returns (uint256 withdrawnUnderlying, uint256 burntTeaToken);
    

    function claimFee() external returns (uint256 claimedFee, uint256 unclaimedFee);

    
    function getSupplyQuota() external view returns (uint256 quota);
    

    function getWithdrawQuota() external view returns (uint256 quota);
    

    function getUnclaimedFee() external view returns (uint256 unclaimedFee, uint256 claimableFee);

    
    function borrow(address account, uint256 amountToBorrow) external;
    
    
    function commitBorrow(address account, uint256 amountToBorrow) external returns (uint256 id);
    
    
    function repay(address account, uint256 id, uint256 amount, bool forceClose) external returns (uint256 repaidUnderlyingAmount, uint256 unrepaidUnderlyingAmount);
    
    
    function balanceOf(address account) external view returns (uint256 teaTokenAmount);
    
    
    function balanceOfUnderlying(address account) external view returns (uint256 underlyingAmount);
    
    
    function debtOf(uint256 id) external view returns (uint256 teaTokenAmount);
    
    
    function debtOfUnderlying(uint256 id) external view returns (uint256 underlyingAmount);
    

    function getConversionRates() external view returns (uint256 suppiedConversionRate, uint256 borrowedConversionRate);

    
    function getLendingStatus() external view returns (uint256 suppliedUnderlying, uint256 borrowedUnderlying, uint256 unclaimedFee, uint24 reserveRatio);
    
    
    function collectInterestFeeAndCommit() external returns (uint256 interest, uint256 fee);

}