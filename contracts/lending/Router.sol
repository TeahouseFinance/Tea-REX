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
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
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
    FeeConfig public defaultFeeConfig;
    bool enableWhitelist;

    mapping(ERC20PermitUpgradeable => mapping(uint256 => Pool)) public pool;
    mapping(IPool => FeeConfig) public feeConfig;
    mapping(uint256 => address) public interestRateModel;
    mapping(ERC20PermitUpgradeable => bool) public isAssetEnabled;
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
        enableWhitelist = true;
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

    function setDefaultFeeConfig(address _treasury, uint32 _borrowFee, uint32 _withdrawalFee) external override onlyOwner {
        _checkFee(_borrowFee, _withdrawalFee);

        defaultFeeConfig = FeeConfig({ treasury: _treasury, borrowFee: _borrowFee, withdrawalFee: _withdrawalFee });

        emit DeFaultFeeConfigSet(msg.sender, _treasury, _borrowFee);
    }

    function setFeeConfig(IPool _pool, address _treasury, uint32 _borrowFee, uint32 _withdrawalFee) external override onlyOwner {
        _checkFee(_borrowFee, _withdrawalFee);

        feeConfig[_pool] = FeeConfig({ treasury: _treasury, borrowFee: _borrowFee, withdrawalFee: _withdrawalFee });

        emit FeeConfigSet(msg.sender, _pool, _treasury, _borrowFee);
    }

    function _checkFee(uint32 _borrowFee, uint32 _withdrawalFee) internal view {
        if (_borrowFee > FEE_CAP) revert ExceedsFeeCap();
        if (_withdrawalFee > FEE_CAP) revert ExceedsFeeCap();
    }

    function getFeeConfig() external view override returns (FeeConfig memory) {
        FeeConfig memory _feeConfig = feeConfig[Pool(msg.sender)];

        return _feeConfig.treasury == address(0) ? defaultFeeConfig : _feeConfig;
    }

    function setInterestRateModel(uint256 _lendingType, address _model) external override onlyOwner {
        interestRateModel[_lendingType] = _model;

        emit InterestRateModelSet(msg.sender, _lendingType, _model);
    }

    function getInterestRateModel(uint256 _lendingType) external view override returns (address) {
        return interestRateModel[_lendingType];
    }

    function createLendingPool(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        uint256 _supplyCap,
        uint256 _borrowCap,
        uint24 _reserveRatio
    ) external override nonReentrant onlyOwner returns (
        address proxyAddress
    ) {
        if (interestRateModel[_lendingType] == address(0)) revert ModelNotSet();
        if (pool[_underlyingAsset][_lendingType] != Pool(address(0))) revert PoolAlreadyExists();

        proxyAddress = address(new BeaconProxy(
            poolBeacon,
            abi.encodeWithSelector(
                Pool.initialize.selector,
                owner(),
                _underlyingAsset,
                _lendingType,
                _supplyCap,
                _borrowCap,
                _reserveRatio
            )
        ));
        pool[_underlyingAsset][_lendingType] = Pool(proxyAddress);
        isAssetEnabled[_underlyingAsset] = true;
        
        emit LendingPoolCreated(address(proxyAddress), address(_underlyingAsset), _lendingType);
    }

    function getLendingPool(ERC20PermitUpgradeable _underlyingAsset, uint256 _lendingType) external view override returns (IPool) {
        return _getLendingPool(_underlyingAsset, _lendingType);
    }

    function _getLendingPool(ERC20PermitUpgradeable _underlyingAsset, uint256 _lendingType) internal view returns (IPool lendingPool) {
        lendingPool = pool[_underlyingAsset][_lendingType];
        if (lendingPool == Pool(address(0))) revert PoolNotExists();
    }

    function getSupplyRate(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType
    ) external override view returns (
        uint256 rate
    ) {
        (
            uint256 supplied,
            uint256 borrowed,
            ,
            uint24 reserveRatio
        ) = pool[_underlyingAsset][_lendingType].getLendingStatus();
        
        rate = IInterestRateModel(interestRateModel[_lendingType]).getSupplyRate(supplied, borrowed, reserveRatio);
    }

    function getBorrowRate(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType
    ) external override view returns (
        uint256 rate
    ) {
        (
            uint256 supplied,
            uint256 borrowed,
            ,
            uint24 reserveRatio
        ) = pool[_underlyingAsset][_lendingType].getLendingStatus();
        
        rate = IInterestRateModel(interestRateModel[_lendingType]).getBorrowRate(supplied, borrowed, reserveRatio);
    }

    function supply(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        address _supplyFor,
        uint256 _amount
    ) external override nonReentrant onlyWhitelistedOperator(msg.sender) returns (
        uint256,
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).supply(msg.sender, _supplyFor, _amount);
    }

    function withdraw(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        address _withdrawTo,
        uint256 _amount
    ) external override nonReentrant onlyWhitelistedOperator(msg.sender) returns (
        uint256,
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).withdraw(msg.sender, _withdrawTo, _amount);
    }

    function borrow(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        uint256 _amountToBorrow
    ) external override nonReentrant onlyTradingCore returns (
        address
    ) {
        IPool lendingPool = _getLendingPool(_underlyingAsset, _lendingType);
        lendingPool.borrow(tradingCore, _amountToBorrow);

        return address(lendingPool);
    }

    function commitBorrow(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        uint256 _amountToBorrow
    ) external override nonReentrant onlyTradingCore returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).commitBorrow(tradingCore, _amountToBorrow);
    }

    function commitBorrow(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        uint256 _id,
        uint256 _amountToBorrow
    ) external override nonReentrant onlyTradingCore {
        return _getLendingPool(_underlyingAsset, _lendingType).commitBorrow(tradingCore, _id, _amountToBorrow);
    }

    function repay(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        address _account,
        uint256 _id,
        uint256 _amount,
        bool _forceClose
    ) external override nonReentrant onlyTradingCore returns (
        uint256,
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).repay(_account, _id, _amount, _forceClose);
    }

    function balanceOf(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        address _account
    ) external view override returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).balanceOf(_account);
    }

    function balanceOfUnderlying(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        address _account
    ) external view override returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).balanceOfUnderlying(_account);
    }

    function debtOf(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        uint256 _id
    ) external view override returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).debtOf(_id);
    }

    function debtOfUnderlying(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType,
        uint256 _id
    ) external view override returns (
        uint256
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).debtOfUnderlying(_id);
    }

    function getConversionRates(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType
    ) external view override returns (
        uint256 suppiedConversionRate,
        uint256 borrowedConversionRate
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).getConversionRates();
    }

    function collectInterestFeeAndCommit(
        ERC20PermitUpgradeable _underlyingAsset,
        uint256 _lendingType
    ) external returns (
        uint256 interest,
        uint256 fee
    ) {
        return _getLendingPool(_underlyingAsset, _lendingType).collectInterestFeeAndCommit();
    }

    function setEnableWhitelist(bool _enableWhitelist) external onlyOwner {
        enableWhitelist = _enableWhitelist;
    }

    function setWhitelistedOperator(address[] calldata _accounts, bool[] calldata _isWhitelisted) external onlyOwner {
        uint256 length = _accounts.length;
        for (uint256 i; i < length; ) {
            whitelistedOperator[_accounts[i]] = _isWhitelisted[i];

            unchecked { ++i; }
        }
    }

    function _onlyTradingCore() internal view {
        if (msg.sender != address(tradingCore)) revert CallerIsNotTradingCore();
    }

    function _onlyWhitelistedOperator(address _account) internal view {
        if (enableWhitelist && !whitelistedOperator[_account]) revert NotInWhitelist();
    }

    modifier onlyTradingCore() {
        _onlyTradingCore();
        _;
    }

    modifier onlyWhitelistedOperator(address _account) {
        _onlyWhitelistedOperator(_account);
        _;
    }
}
