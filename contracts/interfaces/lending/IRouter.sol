// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

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

    /// @notice Type of the interest rate model
    /// @param Null Empty type
    /// @param Static Static rate interest rate model
    /// @param Variable Variable rate interest rate model
    /// @param End End of ERC20 type, not a real type
    enum InterestRateModelType {
        Null,
        Static,
        Variable,
        End
    }

    /// @notice Fee config structure
    /// @param treasury Borrowed fee goes to this address
    /// @param borrowFee Additional borrow fee (APY) for lending positions
    struct FeeConfig {
        address treasury;
        uint32 borrowFee;
    }

    /// @notice Pause operations for this router and all lending pools
    /// @notice Only owner can call this function
    function pause() external;

    /// @notice Unpause operations for this router and all lending pools
    /// @notice Only owner can call this function
    function unpause() external;

    /// @notice Get if all pools are paused or not
    /// @return isPaused All pools are paused or not
    function isAllPoolPaused() external view returns (bool isPaused);

    /// @notice Set new trading core
    /// @notice Only owner can call this function
    /// @param tradingCore Address of new trading core
    function setTradingCore(address tradingCore) external;

    /// @notice Set new fee structure
    /// @param treasury Fee treasury
    /// @param borrowFee Borrow fee rate in APY
    function setFeeConfig(address treasury, uint32 borrowFee) external;

    /// @notice Get fee structure
    /// @return feeConfig Fee structure
    function getFeeConfig() external view returns (FeeConfig memory feeConfig);

    /// @notice Set interest rate model for the specified model type
    /// @param modelType Type of the interest rate model
    /// @param model Address of interest rate model
    function setInterestRateModel(InterestRateModelType modelType, address model) external;

    /// @notice Get interest rate model of the specified model type
    /// @param modelType Type of the interest rate model
    /// @return model Address of interest rate model
    function getInterestRateModel(InterestRateModelType modelType) external view returns (address model);

    /// @notice Create a new lending pool
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param supplyCap Supply cap of the lending pool
    /// @param borrowCap Borrow cap of the lending pool
    /// @param reserveRatio Reserve ratio of the lending pool
    /// @return proxyAddress Address of the created lending pool
    function createLendingPool(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 supplyCap,
        uint256 borrowCap,
        uint24 reserveRatio
    ) external returns (
        address proxyAddress
    );

    /// @notice Get if any lending pool of the underlying token exists
    /// @param asset Address of the underlying token
    /// @return isEnabled Lending pool of the underlying token exists or not
    function isAssetEnabled(ERC20PermitUpgradeable asset) external view returns (bool isEnabled);

    /// @notice Get address of the lending pool address
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @return lendingPool Address of the lending pool
    function getLendingPool(ERC20PermitUpgradeable underlyingAsset, InterestRateModelType modelType) external view returns (IPool lendingPool);
    
    /// @notice Supply tokens to the lending pool and mint interest-bearing tokens
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param supplyFor Minted interest-bearing tokens go to this account
    /// @param amount Amount of underlying tokens to supply
    /// @return depositedUnderlying Actual supplied amount of underlying tokens
    /// @return mintedTeaToken Amount of minted interest-bearing tokens
    function supply(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        address supplyFor,
        uint256 amount
    ) external returns (
        uint256 depositedUnderlying,
        uint256 mintedTeaToken
    );
    
    /// @notice Withdraw tokens supplied before and burn interest-bearing tokens
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param withdrawTo Withdrawn tokens go to this account
    /// @param amount Expected burnt amount of interest-bearing tokens, actual burnt amount may be affected by current lending status
    /// @return withdrawnUnderlying Actual withdrawn amount of underlying tokens
    /// @return burntTeaToken Amount of burnt interest-bearing tokens
    function withdraw(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        address withdrawTo,
        uint256 amount
    ) external returns (
        uint256 withdrawnUnderlying,
        uint256 burntTeaToken
    );
    
    /// @notice Borrow and transfer token directly without accounting, need to call commitBorrow to finish final accouting
    /// @notice Only trading core can call this
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param amountToBorrow Amount of underlying tokens to borrow
    /// @return pool Address of the tokens borrowed from
    function borrow(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 amountToBorrow
    ) external returns (
        address pool
    );
    
    /// @notice Finish borrow accounting and check whether all conditions are met for this borrow
    /// @notice Only trading core can call this
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param amountToBorrow Amount of underlying tokens to borrow
    /// @return id Borrow id of the lending position
    function commitBorrow(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 amountToBorrow
    ) external returns (
        uint256 id
    );
    
    /// @notice Repay debt for a lending position
    /// @notice Only trading core can call this
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param account Repaid token from this account
    /// @param id Borrow id of the lending position
    /// @param amount Amount of interest-bearing tokens to repay
    /// @param forceClose Force close the lending position even it's not fully repaid
    /// @return repaidUnderlyingAmount Repaid amount of underlying tokens
    /// @return unrepaidUnderlyingAmount Unrepaid amount of underlying tokens
    function repay(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        address account,
        uint256 id,
        uint256 amount,
        bool forceClose
    ) external returns (
        uint256 repaidUnderlyingAmount,
        uint256 unrepaidUnderlyingAmount
    );
    
    /// @notice Get interest-bearing tokens supplied by the account
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param account Query account
    /// @return teaTokenAmount Amount of supplied interest-bearing tokens
    function balanceOf(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        address account
    ) external view returns (
        uint256 teaTokenAmount
    );
    
    /// @notice Get underlying tokens supplied by the account
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param account Query account
    /// @return underlyingAmount Amount of supplied underlying tokens
    function balanceOfUnderlying(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        address account
    ) external view returns (
        uint256 underlyingAmount
    );
    
    /// @notice Get interest-bearing tokens owed by the position
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param id Borrow id of the lending position
    /// @return teaTokenAmount Amount of borrowed interest-bearing tokens
    function debtOf(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 id
    ) external view returns (
        uint256 teaTokenAmount
    );
    
    /// @notice Get underlying tokens owed by the account
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @param id Borrow id of the lending position
    /// @return underlyingAmount Amount of borrowed underlying tokens
    function debtOfUnderlying(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType,
        uint256 id
    ) external view returns (
        uint256 underlyingAmount
    );

    /// @notice Get supplied and borrowed interest-bearing token to underlying token conversion rate
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @return suppiedConversionRate Supplied interest-bearing token to underlying token conversion rate
    /// @return borrowedConversionRate Borrowed interest-bearing token to underlying token conversion rate
    function getConversionRates(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType
    ) external view returns (
        uint256 suppiedConversionRate,
        uint256 borrowedConversionRate
    );
    
    /// @notice Collect interest and borrow fee, and do accouting.
    /// @param underlyingAsset Address of the underlying token
    /// @param modelType Type of the interest rate model
    /// @return interest Amount of interest
    /// @return fee Amount of borrow fee
    function collectInterestFeeAndCommit(
        ERC20PermitUpgradeable underlyingAsset,
        InterestRateModelType modelType
    ) external returns (
        uint256 interest,
        uint256 fee
    );

}