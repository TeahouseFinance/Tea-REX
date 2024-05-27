// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

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
    function setSupplyCap(uint256 _cap) external;
    function setBorrowCap(uint256 _cap) external;
    function setReserveRatio(uint256 _ratio) external;
    function getInterestRateModel() external view returns (IInterestRateModel);
    function supply(address _account, address _for, uint256 _amount) external returns (uint256 depositedUnderlying, uint256 mintedTeaToken);
    function withdraw(address _account, address _to, uint256 _amount) external returns (uint256 withdrawnUnderlying, uint256 burntTeaToken);
    function getSupplyQuota() external view returns (uint256 quota);
    function getWithdrawQuota() external view returns (uint256 quota);
    function borrow(address _account, uint256 _underlyingAmount) external returns (uint256 id, uint256 borrowedTeaTokenAmount);
    function repay(address _account, uint256 _id, uint256 _teaTokenAmount) external returns (uint256 repaidUnderlyingAmount);
    function suppliedTeaTokenToUnderlying() external view returns (uint256 rate);
    function balanceOfUnderlying(address _account) external view returns (uint256 underlyingAmount);
    function debtOf(uint256 _id) external view returns (uint256 teaTokenAmount);
    function borrowedTeaTokenToUnderlying() external view returns (uint256 rate);
    function debtOfUnderlying(uint256 _id) external view returns (uint256 underlyingAmount);

}