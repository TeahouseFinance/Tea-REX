// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IRouter} from "../interfaces/lending/IRouter.sol";
import {IPool} from "../interfaces/lending/IPool.sol";
import {IInterestRateModel} from "../interfaces/lending/IInterestRateModel.sol";
import {ITradingCore} from "../interfaces/trading/ITradingCore.sol";
import {Constant} from "../libraries/Constant.sol";
import {Percent} from "../libraries/Percent.sol";

// import "hardhat/console.sol";

contract Pool is IPool, Initializable, OwnableUpgradeable, ERC20PermitUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for ERC20PermitUpgradeable;
    using Math for uint256;
    
    uint8 public DECIMALS;
    uint8 public DECIMALS_OFFSET;
    uint256 public DECIMALS_MULTIPLIER;
    uint256 public RATE_MULTIPLIER;
    IRouter public router;
    ERC20PermitUpgradeable public underlyingAsset;
    IRouter.InterestRateModelType interestRateModelType;
    uint24 public reserveRatio;
    uint256 public supplyCap;
    uint256 public borrowCap;
    uint256 public borrowedTeaToken;
    uint256 private suppliedConversionRate;
    uint256 private borrowedConversionRate;
    uint256 private pendingFee;
    uint256 public lastAccumulateTimestamp;
    uint256 private idCounter;
    mapping(uint256 => DebtInfo) public debtInfo;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        ERC20PermitUpgradeable _underlyingAsset,
        IRouter.InterestRateModelType _interestRateModelType,
        uint256 _supplyCap,
        uint256 _borrowCap,
        uint24 _reserveRatio
    ) public initializer {
        string memory tokenName = string.concat("TeaREX Supply ", _underlyingAsset.name());
        __Ownable_init(_owner);
        __ERC20_init(tokenName, string.concat("Tea", _underlyingAsset.symbol()));
        __ERC20Permit_init(tokenName);
        __Pausable_init();
        __ReentrancyGuard_init();

        if (_borrowCap > _supplyCap) revert InvalidCap();

        router = IRouter(msg.sender);
        underlyingAsset = _underlyingAsset;
        interestRateModelType = _interestRateModelType;
        DECIMALS_OFFSET = 18;
        DECIMALS_MULTIPLIER = 10 ** DECIMALS_OFFSET;
        RATE_MULTIPLIER = 10 ** 18;
        suppliedConversionRate = RATE_MULTIPLIER;
        borrowedConversionRate = RATE_MULTIPLIER;
        DECIMALS = _underlyingAsset.decimals() + DECIMALS_OFFSET;
        
        _setSupplyCap(_supplyCap);
        _setBorrowCap(_borrowCap);
        _setReserveRatio(_reserveRatio);
    }

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function decimals() public override view returns (uint8) {
        return DECIMALS;
    }

    function setSupplyCap(uint256 _cap) external override onlyOwner {
        _setSupplyCap(_cap);
    }

    function _setSupplyCap(uint256 _cap) internal {
        supplyCap = _cap == 0 ? Constant.UINT256_MAX : _cap;
    }

    function setBorrowCap(uint256 _cap) external override onlyOwner {
        _setBorrowCap(_cap);
    }

    function _setBorrowCap(uint256 _cap) internal {
        borrowCap = _cap == 0 ? Constant.UINT256_MAX : _cap;
    }

    function setReserveRatio(uint24 _ratio) external override onlyOwner {
        _setReserveRatio(_ratio);
    }

    function _setReserveRatio(uint24 _ratio) internal {
        if (_ratio >= Percent.MULTIPLIER) revert InvalidPercentage();

        reserveRatio = _ratio;
    }

    function getInterestRateModel() external view override returns (IInterestRateModel) {
        return _getInterestRateModel();
    }

    function _getInterestRateModel() internal view returns (IInterestRateModel) {
        return IInterestRateModel(router.getInterestRateModel(interestRateModelType));
    }

    function _toUnderlying(
        uint256 _teaTokenAmount,
        uint256 _conversionRate,
        bool _isRoundingUp
    ) internal view returns (
        uint256 underlyingAmount
    ) {
        underlyingAmount = _isRoundingUp ? 
            _teaTokenAmount.mulDiv(_conversionRate, RATE_MULTIPLIER * DECIMALS_MULTIPLIER) : 
            _teaTokenAmount.mulDiv(_conversionRate, RATE_MULTIPLIER * DECIMALS_MULTIPLIER, Math.Rounding.Ceil);
    }

    function _toTeaToken(
        uint256 _underlyingAmount,
        uint256 _conversionRate,
        bool _isRoundingUp
    ) internal view returns (
        uint256 teaTokenAmount
    ) {
        teaTokenAmount = _isRoundingUp ? 
            _underlyingAmount.mulDiv(RATE_MULTIPLIER * DECIMALS_MULTIPLIER, _conversionRate) : 
            _underlyingAmount.mulDiv(RATE_MULTIPLIER * DECIMALS_MULTIPLIER, _conversionRate, Math.Rounding.Ceil);
    }

    function supply(
        address _account,
        address _supplyFor,
        uint256 _amount
    ) external override nonReentrant onlyNotPaused onlyRouter returns (
        uint256 depositedUnderlying,
        uint256 mintedTeaToken
    ) {
        if (_amount == 0) revert ZeroAmountNotAllowed();

        (, , uint256 newSuppliedConversionRate, ) = _collectInterestFeeAndCommit();
        uint256 suppliedUnderlying = _toUnderlying(totalSupply(), newSuppliedConversionRate, false);
        uint256 quota = _getSupplyQuota(suppliedUnderlying);
        if (quota == 0) revert ExceedsCap();
        
        depositedUnderlying = quota > _amount ? _amount : quota;
        mintedTeaToken = _toTeaToken(depositedUnderlying, newSuppliedConversionRate, false);

        underlyingAsset.safeTransferFrom(_account, address(this), depositedUnderlying);
        _mint(_supplyFor, mintedTeaToken);

        emit Supplied(_account, _supplyFor, depositedUnderlying, mintedTeaToken);
    }

    function getSupplyQuota() external view override returns (uint256) {
        (, , uint256 newSuppliedConversionRate, ) = _collectInterestAndFee();

        return _getSupplyQuota(_toUnderlying(totalSupply(), newSuppliedConversionRate, false));
    }

    function _getSupplyQuota(uint256 _suppliedUnderlying) internal view returns (uint256) {
        uint256 _cap = supplyCap;

        return _suppliedUnderlying >= _cap ? 0 : _cap - _suppliedUnderlying;
    }

    function withdraw(
        address _account,
        address _withdrawTo,
        uint256 _amount
    ) external override nonReentrant onlyNotPaused onlyRouter returns (
        uint256 withdrawnUnderlying,
        uint256 burntTeaToken
    ) {
        if (_amount == 0) revert ZeroAmountNotAllowed();

        (, , uint256 newSuppliedConversionRate, ) = _collectInterestFeeAndCommit();
        ERC20PermitUpgradeable _underlyingAsset = underlyingAsset;
        uint256 quota = _getPoolUnderlyingBalance(_underlyingAsset);
        if (quota == 0) revert NoUnborrowedUnderlying();

        withdrawnUnderlying = _toUnderlying(_amount, newSuppliedConversionRate, false);
        if (withdrawnUnderlying <= quota) {
            burntTeaToken = _amount;
        }
        else {
            withdrawnUnderlying = quota;
            burntTeaToken = _toTeaToken(quota, newSuppliedConversionRate, true);
        }

        if (burntTeaToken == 0) revert ZeroAmountNotAllowed();
        _burn(_account, burntTeaToken);

        IRouter.FeeConfig memory feeConfig = router.getFeeConfig();
        uint256 withdrawalFee = withdrawnUnderlying.mulDiv(feeConfig.withdrawalFee, Percent.MULTIPLIER, Math.Rounding.Ceil);
        if (withdrawalFee > 0) _underlyingAsset.safeTransfer(feeConfig.treasury, withdrawalFee);
        _underlyingAsset.safeTransfer(_withdrawTo, withdrawnUnderlying - withdrawalFee);

        emit Withdrew(_account, _withdrawTo, withdrawalFee, withdrawnUnderlying, burntTeaToken);
    }

    function getWithdrawQuota() external view override returns (uint256) {
        return _getPoolUnderlyingBalance(underlyingAsset);
    }

    function _getPoolUnderlyingBalance(ERC20PermitUpgradeable _underlyingAsset) internal view returns (uint256) {
        return _underlyingAsset.balanceOf(address(this));
    }

    function claimFee() external override nonReentrant onlyNotPaused returns (uint256 claimedFee, uint256 unclaimedFee) {
        _collectInterestFeeAndCommit();
        
        uint256 balance = underlyingAsset.balanceOf(address(this));
        claimedFee = balance > pendingFee ? pendingFee : balance;
        if (claimedFee > 0) {
            pendingFee -= claimedFee;
            address treasury = router.getFeeConfig().treasury;
            underlyingAsset.safeTransfer(treasury, claimedFee);

            emit FeeClaimed(treasury, claimedFee);
        }
        unclaimedFee = pendingFee;
    }

    function getUnclaimedFee() external override view returns (uint256 unclaimedFee, uint256 claimableFee) {
        uint256 balance = _getPoolUnderlyingBalance(underlyingAsset);
        (, uint256 fee, , ) = _collectInterestAndFee();

        unclaimedFee = pendingFee + fee;
        claimableFee = balance > unclaimedFee ? unclaimedFee : balance;
    }

    function _checkBorrowable(
        uint256 _suppliedUnderlying,
        uint256 _borrowedUnderlying,
        uint256 _amountToBorrow
    ) internal view {
        uint256 borrowable = _suppliedUnderlying.mulDiv(Percent.MULTIPLIER - reserveRatio, Percent.MULTIPLIER);
        uint256 totalBorrowed = _borrowedUnderlying + _amountToBorrow;
        if (
            totalBorrowed > borrowable || totalBorrowed > borrowCap || _amountToBorrow > _getPoolUnderlyingBalance(underlyingAsset)
        ) revert ExceedsCap();
    }

    function borrow(address _account, uint256 _amountToBorrow) external override nonReentrant onlyNotPaused onlyRouter {
        if (_amountToBorrow == 0) revert ZeroAmountNotAllowed();

        underlyingAsset.safeTransfer(_account, _amountToBorrow);
    }

    function commitBorrow(
        address _account,
        uint256 _amountToBorrow
    ) external override nonReentrant onlyNotPaused onlyRouter returns (
        uint256 id
    ) {
        if (_amountToBorrow == 0) revert ZeroAmountNotAllowed();
        (, , uint256 newSuppliedConversionRate, uint256 newBorrowedConversionRate) = _collectInterestFeeAndCommit();
        uint256 _borrowedTeaToken = borrowedTeaToken;
        uint256 suppliedUnderlying = _toUnderlying(totalSupply(), newSuppliedConversionRate, false);
        uint256 borrowedUnderlying = _toUnderlying(_borrowedTeaToken, newBorrowedConversionRate, false);
        _checkBorrowable(suppliedUnderlying, borrowedUnderlying, _amountToBorrow);

        uint256 borrowedTeaTokenAmount = _toTeaToken(_amountToBorrow, newBorrowedConversionRate, false);
        id = idCounter;
        idCounter = idCounter + 1;
        debtInfo[id] = DebtInfo({
            isClosed: false,
            borrowedTeaToken: borrowedTeaTokenAmount
        });
        borrowedTeaToken = borrowedTeaToken + borrowedTeaTokenAmount;

        emit Borrowed(_account, id, _amountToBorrow, borrowedTeaTokenAmount);
    }

    function repay(
        address _account,
        uint256 _id,
        uint256 _amount,
        bool _forceClose
    ) external override nonReentrant onlyNotPaused onlyRouter returns (
        uint256 repaidUnderlyingAmount,
        uint256 unrepaidUnderlyingAmount
    ) {
        if (_amount == 0) revert ZeroAmountNotAllowed();

        (, , , uint256 newBorrowedConversionRate) = _collectInterestFeeAndCommit();
        uint256 _borrowedTeaToken = borrowedTeaToken;

        DebtInfo memory _debtInfo = debtInfo[_id];
        uint256 _teaTokenAmount = _toTeaToken(_amount, newBorrowedConversionRate, false);
        if (_teaTokenAmount > _debtInfo.borrowedTeaToken) {
            _teaTokenAmount = _debtInfo.borrowedTeaToken;
            repaidUnderlyingAmount = _toUnderlying(_teaTokenAmount, newBorrowedConversionRate, true);
        }
        else {
            repaidUnderlyingAmount = _amount;
        }
        unrepaidUnderlyingAmount = _toUnderlying(_debtInfo.borrowedTeaToken, newBorrowedConversionRate, true) - repaidUnderlyingAmount;
        
        ERC20PermitUpgradeable _underlyingAsset = underlyingAsset;
        _underlyingAsset.safeTransferFrom(_account, address(this), repaidUnderlyingAmount);

        borrowedTeaToken = _borrowedTeaToken - _teaTokenAmount;
        _debtInfo.borrowedTeaToken = _debtInfo.borrowedTeaToken - _teaTokenAmount;
        if (_debtInfo.borrowedTeaToken == 0) {
            _debtInfo.isClosed = true;
        }
        else if (_forceClose) {
            _debtInfo.isClosed = true;
            // H-03
            uint256 loss = _toUnderlying(_debtInfo.borrowedTeaToken, newBorrowedConversionRate, false);
            uint256 _pendingFee = pendingFee;
            if (loss > _pendingFee) {
                // H-05
                suppliedConversionRate = _calculateSuppliedRate(false, loss - _pendingFee);
                pendingFee = 0;
            }
            else {
                pendingFee = _pendingFee - loss;
            }
        }
        debtInfo[_id] = _debtInfo;

        emit Repaid(_account, _id, _teaTokenAmount, repaidUnderlyingAmount);
    }

    function balanceOf(address _account) public view override(IPool, ERC20Upgradeable) returns (uint256) {
        return super.balanceOf(_account);
    }

    function balanceOfUnderlying(address _account) external view override returns (uint256) {
        (, , uint256 newSuppliedConversionRate, ) = _collectInterestAndFee();

        return _toUnderlying(balanceOf(_account), newSuppliedConversionRate, false);
    }

    function debtOf(uint256 _id) external view override returns (uint256) {
        return debtInfo[_id].borrowedTeaToken;
    }

    function debtOfUnderlying(uint256 _id) external view override returns (uint256) {
        (, , , uint256 newBorrowedConversionRate) = _collectInterestAndFee();

        return _toUnderlying(debtInfo[_id].borrowedTeaToken, newBorrowedConversionRate, true);
    }

    function getConversionRates() external override view returns (uint256, uint256) {
        (, , uint256 newSuppiedConversionRate, uint256 newBorrowedConversionRate) = _collectInterestAndFee();

        return (newSuppiedConversionRate, newBorrowedConversionRate);
    }

    function getLendingStatus() external override view returns (uint256, uint256, uint256, uint24) {
        (
            ,
            uint256 fee,
            uint256 newSuppliedConversionRate,
            uint256 newBorrowedConversionRate
        ) = _collectInterestAndFee();

        uint256 suppliedUnderlying = totalSupply().mulDiv(newSuppliedConversionRate, RATE_MULTIPLIER);
        uint256 borrowedUnderlying = borrowedTeaToken.mulDiv(newBorrowedConversionRate, RATE_MULTIPLIER);
        uint256 unclaimedFee = pendingFee + fee;

        return (suppliedUnderlying, borrowedUnderlying, unclaimedFee, reserveRatio);
    }

    function _calculateSuppliedRate(bool _isIncrease, uint256 _amountDelta) internal view returns (uint256 rate) {
        rate = suppliedConversionRate;

        if (_amountDelta > 0) {
            uint256 rateDelta = _amountDelta / totalSupply();
            // H-01
            rate = _isIncrease ? rate + rateDelta : rate - rateDelta;
        }
    }

    function collectInterestFeeAndCommit() external override returns (uint256 interest, uint256 fee) {
        (interest, fee, , ) = _collectInterestFeeAndCommit();
    }

    function _collectInterestFeeAndCommit() internal returns (
        uint256 interest,
        uint256 fee,
        uint256 newSuppliedConversionRate,
        uint256 newBorrowedConversionRate
    ) {
        (interest, fee, newSuppliedConversionRate, newBorrowedConversionRate) = _collectInterestAndFee();

        lastAccumulateTimestamp = block.timestamp;
        suppliedConversionRate = newSuppliedConversionRate;
        borrowedConversionRate = newBorrowedConversionRate;
        
        if (fee > 0) {
            pendingFee = pendingFee + fee;
            emit BorrowFeeAccumulated(block.timestamp, fee);
        }
        if (interest > 0) emit InterestAccumulated(block.timestamp, interest);
    }

    function _collectInterestAndFee() internal view returns (
        uint256 interest,
        uint256 fee,
        uint256 newSuppliedConversionRate,
        uint256 newBorrowedConversionRate
    ) {
        uint256 timeElapsed = block.timestamp - lastAccumulateTimestamp;
        uint256 _borrowedTeaToken = borrowedTeaToken;
        if (_borrowedTeaToken == 0) return (interest, fee, suppliedConversionRate, borrowedConversionRate);
        
        uint256 suppliedTeaToken = totalSupply();
        uint256 suppliedUnderlying = suppliedTeaToken.mulDiv(suppliedConversionRate, RATE_MULTIPLIER);
        uint256 borrowedUnderlying = _borrowedTeaToken.mulDiv(borrowedConversionRate, RATE_MULTIPLIER);
        uint256 _borrowedConversionRate = borrowedConversionRate;

        uint256 interestRate = IInterestRateModel(router.getInterestRateModel(interestRateModelType)).getBorrowRate(
            suppliedUnderlying,
            borrowedUnderlying,
            reserveRatio
        );

        uint256 rateDeltaInterest = _calculateInterests(_borrowedConversionRate, interestRate, timeElapsed);
        uint256 rateDeltaFee = _calculateInterests(_borrowedConversionRate, router.getFeeConfig().borrowFee, timeElapsed);
        // H-02
        interest = _borrowedTeaToken.mulDiv(rateDeltaInterest, RATE_MULTIPLIER * DECIMALS_MULTIPLIER);
        fee = _borrowedTeaToken.mulDiv(rateDeltaFee, RATE_MULTIPLIER * DECIMALS_MULTIPLIER);
        newSuppliedConversionRate = _calculateSuppliedRate(true, interest);
        newBorrowedConversionRate = _borrowedConversionRate + rateDeltaInterest + rateDeltaFee;
    }

    /// calculate interests
    function _calculateInterests(uint256 _borrowed, uint256 _rate, uint256 _timeElapsed) internal pure returns (uint256 result) {
        uint256 baseYear = ((Percent.MULTIPLIER + _rate) << 96) / Percent.MULTIPLIER;
        uint256 base = _inversePower96(baseYear, Constant.SEC_PER_YEAR);
        uint256 multiplier = _power96(base, _timeElapsed);
        result = multiplier.mulDiv(_borrowed, 1 << 96) - _borrowed;
    }

    /// @notice Calculate _base ** (1/_exp) where _base is a 96 bits fixed point number (i.e. 1 << 96 means 1).
    /// @notice This function assumes _base and result are less than (1 << 97), but does not verify to save gas.
    /// @notice Caller is responsible for making sure that _base and result are within range.
    function _inversePower96(uint256 _base, uint256 _exp) internal pure returns (uint256 result) {
        uint256 one = (1 << 96);
        if (_base < one) {
            result = one - (one - _base) / _exp;
        }
        else {
            result = one + (_base - one) / _exp;
        }

        unchecked {
            uint256 step;
            do {
                uint256 power = _power96(result, _exp - 1);
                uint256 power2 = (power * result) >> 96;
                // for _base < (1 << 97), power2 converges to e (~ 2.718281828) when _exp gets larger, so it won't overflow on the first round
                // since step is smaller when _exp is large, the new result won't change much for later rounds
                // thus power2 should always be in range no matter how large _exp is

                if (power2 > _base) {
                    uint256 an = power2 - _base;
                    uint256 slope = power * _exp;
                    step = (an << 96) / slope;
                    result = result - step;
                }
                else {
                    uint256 an = _base - power2;
                    uint256 slope = power * _exp;
                    step = (an << 96) / slope;
                    result = result + step;
                }
            } while(step != 0);
        }

        return result;
    }

    /// @notice Calculate _base ** _exp where _base is a 96 bits fixed point number (i.e. 1 << 96 means 1).
    /// @notice This function assumes _base and result are less than (1 << 128), but does not verify to save gas.
    /// @notice Caller is responsible for making sure that _base and result are within range.
    function _power96(uint256 _base, uint256 _exp) internal pure returns (uint256 result) {
        result = (1 << 96);

        unchecked {
            while(_exp > 0) {
                if ((_exp & 1) == 1) {
                    result *= _base;
                    result >>= 96;
                }

                _exp >>= 1;
                _base *= _base;
                _base >>= 96;
            }
        }

        return result;
    }

    modifier onlyNotPaused() {
        _onlyNotPaused();
        _;
    }

    modifier onlyRouter() {
        _onlyRouter();
        _;
    }

    function _onlyNotPaused() internal view {
        if (paused() || router.isAllPoolPaused()) revert EnforcedPause();
    }

    function _onlyRouter() internal view {
        if (msg.sender != address(router)) revert CallerIsNotRouter();
    }
}