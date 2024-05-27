// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {Pool} from "../../lending/Pool.sol";

interface IRouter {

    error InvalidInterestRateModelType();
    error ModelNotSet();
    error PoolAlreadyExists();
    error PoolNotExists();
    error CallerIsNotTradingCore();
    
    event TradingCoreSet(address indexed sender, address indexed tradingCore);
    event FeeConfigSet(address indexed sender, address indexed treasury, uint32 indexed borrowFee);
    event InterestRateModelSet(address indexed sender, InterestRateModelType indexed modelType, address indexed model);
    event LendingPoolCreated(address indexed poolAddress, address indexed underlyingAsset, InterestRateModelType indexed modelType);

    enum InterestRateModelType {
        Null,
        Static,
        Variable,
        End
    }

    struct FeeConfig {
        address treasury;
        uint32 borrowFee;
    }

    function pause() external;
    function unpause() external;
    function isAllPoolPaused() external view returns (bool isPaused);
    function setTradingCore(address _tradingCore) external;
    function setFeeConfig(address _treasury, uint32 _borrowFee) external;
    function getFeeConfig() external view returns (FeeConfig memory feeConfig);
    function setInterestRateModel(InterestRateModelType _type, address _model) external;
    function getInterestRateModel(InterestRateModelType _type) external view returns (address model);
    function createLendingPool(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        uint256 _supplyCap,
        uint256 _borrowCap,
        uint32 _reserveRatio
    ) external returns (
        address proxyAddress
    );
    function getLendingPool(ERC20Upgradeable _underlyingAsset, InterestRateModelType _type) external view returns (Pool);
    function supply(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        address _for,
        uint256 _amount
    ) external returns (
        uint256 depositedUnderlying,
        uint256 mintedTeaToken
    );
    function withdraw(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        address _to,
        uint256 _amount
    ) external returns (
        uint256 withdrawnUnderlying,
        uint256 burntTeaToken
    );
    function borrow(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        uint256 _underlyingAmount
    ) external returns (
        uint256 id,
        uint256 borrowedTeaTokenAmount
    );
    function repay(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        address _account,
        uint256 _id,
        uint256 _teaTokenAmount
    ) external returns (
        uint256 repaidUnderlyingAmount
    );
    function balanceOf(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        address _account
    ) external view returns (
        uint256 teaTokenAmount
    );
    function balanceOfUnderlying(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        address _account
    ) external view returns (
        uint256 underlyingAmount
    );
    function debtOf(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        uint256 _id
    ) external view returns (
        uint256 teaTokenAmount
    );
    function debtOfUnderlying(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _type,
        uint256 _id
    ) external view returns (
        uint256 underlyingAmount
    );

}