// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {IRouter} from "./IRouter.sol";
import {IInterestRateModel} from "./IInterestRateModel.sol";

interface IPool {

    error InvalidPercentage();
    error ZeroAmountNotAllowed();
    error ExceedsCap();
    error NoUnborrowedUnderlying();
    error CallerIsNotRouter();

    event Supplied(address indexed account, address indexed supplyFor, uint256 depositedUnderlying, uint256 mintedTeaToken);
    event Withdrew(address indexed account, address indexed WithdrawTo, uint256 withdrawnUnderlying, uint256 burntTeaToken);
    event Borrowed(address indexed account, uint256 indexed id, uint256 underlyingAmount, uint256 borrowedTeaTokenAmount);
    event Repaid(address indexed account, uint256 indexed id, uint256 teaTokenAmount, uint256 repaidUnderlyingAmount);
    event InterestAccumulated(uint256 timestamp, uint256 interest);
    event BorrowFeeAccumulated(uint256 timestamp, uint256 fee);

    struct DebtInfo {
        uint256 borrowedTeaToken;
        uint256 lastBorrowRate;
        uint256 lastBorrowRateWithoutFee;
    }

    function pause() external;
    function unpause() external;
    function setSupplyCap(uint256 cap) external;
    function setBorrowCap(uint256 cap) external;
    function setReserveRatio(uint256 ratio) external;
    function getInterestRateModel() external view returns (IInterestRateModel);
    function supply(address account, address supplyFor, uint256 amount) external returns (uint256 depositedUnderlying, uint256 mintedTeaToken);
    function withdraw(address account, address withdrawTo, uint256 amount) external returns (uint256 withdrawnUnderlying, uint256 burntTeaToken);
    function getSupplyQuota() external view returns (uint256 quota);
    function getWithdrawQuota() external view returns (uint256 quota);
    function borrow(address account, uint256 underlyingAmount) external;
    function commitBorrow(address account, uint256 underlyingAmount) external returns (uint256 id);
    function repay(address account, uint256 id, uint256 underlyingAmount) external returns (uint256 repaidUnderlyingAmount, uint256 unrepaidUnderlyingAmount);
    function suppliedTeaTokenToUnderlying() external view returns (uint256 rate);
    function balanceOf(address account) external view returns (uint256 teaTokenAmount);
    function balanceOfUnderlying(address account) external view returns (uint256 underlyingAmount);
    function debtOf(uint256 id) external view returns (uint256 teaTokenAmount);
    function borrowedTeaTokenToUnderlying() external view returns (uint256 rate);
    function debtOfUnderlying(uint256 id) external view returns (uint256 underlyingAmount);
    function collectInterestFeeAndCommit(IRouter.FeeConfig memory feeConfig) external returns (uint256 interest, uint256 fee);

}