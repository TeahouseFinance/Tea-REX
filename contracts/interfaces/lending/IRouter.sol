// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IPool} from "./IPool.sol";

interface IRouter {

    error ExceedsFeeCap();
    error InvalidInterestRateModelType();
    error ModelNotSet();
    error PoolAlreadyExists();
    error PoolNotExists();
    error CallerIsNotTradingCore();
    error NotInWhitelist();
    
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
    function setTradingCore(address tradingCore) external;
    function setFeeConfig(address treasury, uint32 borrowFee) external;
    function getFeeConfig() external view returns (FeeConfig memory feeConfig);
    function setInterestRateModel(InterestRateModelType modelType, address model) external;
    function getInterestRateModel(InterestRateModelType modelType) external view returns (address model);
    function createLendingPool(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 supplyCap,
        uint256 borrowCap,
        uint24 reserveRatio
    ) external returns (
        address proxyAddress
    );
    function isAssetEnabled(ERC20Upgradeable asset) external view returns (bool);
    function getLendingPool(ERC20Upgradeable underlyingAsset, InterestRateModelType modelType) external view returns (IPool);
    function getSupplyRate(ERC20Upgradeable underlyingAsset, InterestRateModelType modelType) external view returns (uint256 rate);
    function getBorrowRate(ERC20Upgradeable underlyingAsset, InterestRateModelType modelType) external view returns (uint256 rate);
    function supply(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        address supplyFor,
        uint256 amount
    ) external returns (
        uint256 depositedUnderlying,
        uint256 mintedTeaToken
    );
    function withdraw(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        address withdrawTo,
        uint256 amount
    ) external returns (
        uint256 withdrawnUnderlying,
        uint256 burntTeaToken
    );
    function borrow(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 underlyingAmount
    ) external returns (
        address pool
    );
    function commitBorrow(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 underlyingAmount
    ) external returns (
        uint256 id
    );
    function repay(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        address account,
        uint256 id,
        uint256 underlyingAmount
    ) external returns (
        uint256 repaidUnderlyingAmount,
        uint256 unrepaidUnderlyingAmount
    );
    function balanceOf(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        address account
    ) external view returns (
        uint256 teaTokenAmount
    );
    function balanceOfUnderlying(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        address account
    ) external view returns (
        uint256 underlyingAmount
    );
    function debtOf(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 id
    ) external view returns (
        uint256 teaTokenAmount
    );
    function debtOfUnderlying(
        ERC20Upgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 id
    ) external view returns (
        uint256 underlyingAmount
    );
    function collectInterestFeeAndCommit(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType
    ) external returns (
        uint256 interest,
        uint256 fee
    );

}