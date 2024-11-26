// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IRouter} from "../interfaces/lending/IRouter.sol";
import {IPool} from "../interfaces/lending/IPool.sol";
import {IInterestRateModel} from "../interfaces/lending/IInterestRateModel.sol";
import {Pool} from "./Pool.sol";
import {Constant} from "../libraries/Constant.sol";
import {Percent} from "../libraries/Percent.sol";

contract Router is IRouter, Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    address public poolBeacon;
    address public tradingCore;
    address public lendingPoolImplementation;
    uint32 public FEE_CAP;
    FeeConfig public feeConfig;
    bool enableWhitelist;

    mapping(ERC20Upgradeable => mapping(InterestRateModelType => Pool)) public pool;
    mapping(InterestRateModelType => address) public interestRateModel;
    mapping(ERC20Upgradeable => bool) public isAssetEnabled;
    mapping(address => bool) public whitelistedOperator;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function initialize(
        address _owner,
        address _beacon,
        uint32 _feeCap
    ) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(_owner);
        __Pausable_init();
        __ReentrancyGuard_init();

        FEE_CAP = _feeCap;
        poolBeacon = _beacon;
    }

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function isAllPoolPaused() external view override returns (bool) {
        return paused();
    }

    function setTradingCore(address _tradingCore) external override onlyOwner {
        tradingCore = _tradingCore;

        emit TradingCoreSet(msg.sender, _tradingCore);
    }

    function setFeeConfig(address _treasury, uint32 _borrowFee) external override onlyOwner {
        if (_borrowFee > FEE_CAP) revert ExceedsFeeCap();

        feeConfig = FeeConfig({ treasury: _treasury, borrowFee: _borrowFee });

        emit FeeConfigSet(msg.sender, _treasury, _borrowFee);
    }

    function getFeeConfig() external view override returns (FeeConfig memory) {
        return feeConfig;
    }

    function setInterestRateModel(InterestRateModelType _modelType, address _model) external override onlyOwner {
        interestRateModel[_modelType] = _model;

        emit InterestRateModelSet(msg.sender, _modelType, _model);
    }

    function getInterestRateModel(InterestRateModelType _modelType) external view override returns (address) {
        return interestRateModel[_modelType];
    }

    function createLendingPool(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        uint256 _supplyCap,
        uint256 _borrowCap,
        uint24 _reserveRatio
    ) external override nonReentrant onlyOwner returns (
        address proxyAddress
    ) {
        if (_modelType == InterestRateModelType.Null || _modelType >= InterestRateModelType.End) revert InvalidInterestRateModelType();
        if (interestRateModel[_modelType] == address(0)) revert ModelNotSet();
        if (pool[_underlyingAsset][_modelType] != Pool(address(0))) revert PoolAlreadyExists();

        proxyAddress = address(new BeaconProxy(
            poolBeacon,
            abi.encodeWithSelector(
                Pool.initialize.selector,
                owner(),
                _underlyingAsset,
                _modelType,
                _supplyCap,
                _borrowCap,
                _reserveRatio
            )
        ));
        pool[_underlyingAsset][_modelType] = Pool(proxyAddress);
        isAssetEnabled[_underlyingAsset] = true;
        
        emit LendingPoolCreated(address(proxyAddress), address(_underlyingAsset), _modelType);
    }

    function getLendingPool(ERC20Upgradeable _underlyingAsset, InterestRateModelType _modelType) external view override returns (IPool) {
        return _getLendingPool(_underlyingAsset, _modelType);
    }

    function _getLendingPool(ERC20Upgradeable _underlyingAsset, InterestRateModelType _modelType) internal view returns (IPool lendingPool) {
        lendingPool = pool[_underlyingAsset][_modelType];
        if (lendingPool == Pool(address(0))) revert PoolNotExists();
    }

    function supply(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        address _supplyFor,
        uint256 _amount
    ) external override nonReentrant onlyWhitelistedOperator(msg.sender) returns (
        uint256,
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _modelType).supply(msg.sender, _supplyFor, _amount);
    }

    function withdraw(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        address _withdrawTo,
        uint256 _amount
    ) external override nonReentrant onlyWhitelistedOperator(msg.sender) returns (
        uint256,
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _modelType).withdraw(msg.sender, _withdrawTo, _amount);
    }

    function borrow(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        uint256 _amountToBorrow
    ) external override nonReentrant returns (
        address
    ) {
        if (msg.sender != tradingCore) revert CallerIsNotTradingCore();

        IPool lendingPool = _getLendingPool(_underlyingAsset, _modelType);
        lendingPool.borrow(tradingCore, _amountToBorrow);

        return address(lendingPool);
    }

    function commitBorrow(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        uint256 _amountToBorrow
    ) external override nonReentrant returns (
        uint256
    ) {
        if (msg.sender != tradingCore) revert CallerIsNotTradingCore();

        return _getLendingPool(_underlyingAsset, _modelType).commitBorrow(tradingCore, _amountToBorrow);
    }

    function repay(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        address _account,
        uint256 _id,
        uint256 _amount,
        bool _forceClose
    ) external override nonReentrant returns (
        uint256,
        uint256
    ) {
        if (msg.sender != tradingCore) revert CallerIsNotTradingCore();

        return _getLendingPool(_underlyingAsset, _modelType).repay(_account, _id, _amount, _forceClose);
    }

    function balanceOf(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        address _account
    ) external view override returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _modelType).balanceOf(_account);
    }

    function balanceOfUnderlying(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        address _account
    ) external view override returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _modelType).balanceOfUnderlying(_account);
    }

    function debtOf(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        uint256 _id
    ) external view override returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _modelType).debtOf(_id);
    }

    function debtOfUnderlying(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType,
        uint256 _id
    ) external view override returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _modelType).debtOfUnderlying(_id);
    }

    function getConversionRates(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType
    ) external view override returns (
        uint256 suppiedConversionRate,
        uint256 borrowedConversionRate
    ) {
        return _getLendingPool(_underlyingAsset, _modelType).getConversionRates();
    }

    function collectInterestFeeAndCommit(
        ERC20Upgradeable _underlyingAsset,
        InterestRateModelType _modelType
    ) external returns (
        uint256 interest,
        uint256 fee
    ) {
        return _getLendingPool(_underlyingAsset, _modelType).collectInterestFeeAndCommit();
    }

    function setEnableWhitelist(bool _enableWhitelist) external onlyOwner {
        enableWhitelist = _enableWhitelist;
    }

    function setWhitelistedOperator(address[] calldata _accounts, bool[] calldata _isWhitelisted) external onlyOwner {
        uint256 length = _accounts.length;
        for (uint256 i; i < length; i = i + 1) {
            whitelistedOperator[_accounts[i]] = _isWhitelisted[i];
        }
    }

    function _onlyWhitelistedOperator(address _account) internal view {
        if (enableWhitelist && !whitelistedOperator[_account]) revert NotInWhitelist();
    }

    modifier onlyWhitelistedOperator(address _account) {
        _onlyWhitelistedOperator(_account);
        _;
    }
}
