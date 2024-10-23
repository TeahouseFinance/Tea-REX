// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
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
import {LendingUtils} from "../libraries/LendingUtils.sol";

import "hardhat/console.sol";
contract Pool is IPool, Initializable, OwnableUpgradeable, ERC20Upgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for ERC20Upgradeable;
    using Math for uint256;
    
    uint8 public DECIMALS;
    IRouter public router;
    ERC20Upgradeable public underlyingAsset;
    IRouter.InterestRateModelType interestRateModelType;
    uint24 public reserveRatio;
    uint256 public supplyCap;
    uint256 public borrowCap;
    uint256 public lastCumulateInterest;
    uint256 public suppliedUnderlying;
    uint256 public borrowedUnderlying;
    uint256 public unpaidBorrowFeeUnderlying;
    uint256 public borrowedTeaToken;
    uint256 private idCounter;
    mapping(uint256 => DebtInfo) public debtInfo;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        ERC20Upgradeable _underlyingAsset,
        IRouter.InterestRateModelType _interestRateModelType,
        uint256 _supplyCap,
        uint256 _borrowCap,
        uint24 _reserveRatio
    ) public initializer {
        __Ownable_init(_owner);
        __ERC20_init(string.concat("TeaREX Supply ", _underlyingAsset.name()), string.concat("Tea", _underlyingAsset.symbol()));
        __Pausable_init();
        __ReentrancyGuard_init();

        if (_borrowCap > _supplyCap) revert InvalidCap();

        router = IRouter(msg.sender);
        underlyingAsset = _underlyingAsset;
        DECIMALS = _underlyingAsset.decimals();

        interestRateModelType = _interestRateModelType;
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

    function _getFeeConfig() internal view returns (IRouter.FeeConfig memory) {
        return router.getFeeConfig();
    }

    function getInterestRateModel() external view override returns (IInterestRateModel) {
        return _getInterestRateModel();
    }

    function _getInterestRateModel() internal view returns (IInterestRateModel) {
        return IInterestRateModel(router.getInterestRateModel(interestRateModelType));
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

        _collectInterestFeeAndCommit(router.getFeeConfig());
        uint256 _suppliedUnderlying = suppliedUnderlying;
        uint256 quota = LendingUtils.getSupplyQuota(supplyCap, _suppliedUnderlying);
        if (quota == 0) revert ExceedsCap();
        depositedUnderlying = quota > _amount ? _amount : quota;
        suppliedUnderlying = suppliedUnderlying + depositedUnderlying;
        uint8 _decimals = decimals();
        mintedTeaToken = LendingUtils.suppliedUnderlyingToTeaToken(_decimals, totalSupply(), _suppliedUnderlying).mulDiv(
            depositedUnderlying,
            10 ** _decimals
        );
        underlyingAsset.safeTransferFrom(_account, address(this), depositedUnderlying);
        _mint(_supplyFor, mintedTeaToken);

        emit Supplied(_account, _supplyFor, depositedUnderlying, mintedTeaToken);
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

        _collectInterestFeeAndCommit(router.getFeeConfig());
        uint256 _suppliedUnderlying = suppliedUnderlying;
        uint256 quota = LendingUtils.getWithdrawQuota(_suppliedUnderlying, unpaidBorrowFeeUnderlying, borrowedUnderlying);
        if (quota == 0) revert NoUnborrowedUnderlying();
        uint8 _decimals = decimals();
        withdrawnUnderlying = LendingUtils.suppliedTeaTokenToUnderlying(_decimals, totalSupply(), _suppliedUnderlying).mulDiv(
            _amount,
            10 ** _decimals
        );
        if (withdrawnUnderlying <= quota) {
            burntTeaToken = _amount;
        }
        else {
            burntTeaToken = _amount.mulDiv(
                quota,
                withdrawnUnderlying,
                Math.Rounding.Ceil
            );
            withdrawnUnderlying = quota;
        }
        if (burntTeaToken == 0) revert ZeroAmountNotAllowed();
        suppliedUnderlying = _suppliedUnderlying - withdrawnUnderlying;
        _burn(_account, burntTeaToken);
        underlyingAsset.safeTransfer(_withdrawTo, withdrawnUnderlying);

        emit Withdrew(_account, _withdrawTo, withdrawnUnderlying, burntTeaToken);
    }

    function getSupplyQuota() external view override returns (uint256) {
        (uint256 interest, ) = _collectInterestAndFee(router.getFeeConfig());

        return LendingUtils.getSupplyQuota(supplyCap, suppliedUnderlying + interest);
    }

    function getWithdrawQuota() external view override returns (uint256) {
        _collectInterestAndFee(router.getFeeConfig());

        // unpaid interest and fee do not affect quota, so no parameter update action happens here.
        return LendingUtils.getWithdrawQuota(
            suppliedUnderlying,
            unpaidBorrowFeeUnderlying,
            borrowedUnderlying
        );
    }

    function _checkBorrowable(uint256 _borrowedUnderlying, uint256 _underlyingAmount) internal view {
        uint256 borrowable = suppliedUnderlying.mulDiv(Percent.MULTIPLIER - reserveRatio, Percent.MULTIPLIER);
        uint256 totalBorrowed = _borrowedUnderlying + _underlyingAmount;
        if (totalBorrowed > borrowable || totalBorrowed > borrowCap) revert ExceedsCap();
    }

    function borrow(address _account, uint256 _underlyingAmount) external override nonReentrant onlyNotPaused onlyRouter {
        if (_underlyingAmount == 0) revert ZeroAmountNotAllowed();
        _checkBorrowable(borrowedUnderlying, _underlyingAmount);

        underlyingAsset.safeTransfer(_account, _underlyingAmount);
    }

    function commitBorrow(
        address _account,
        uint256 _underlyingAmount
    ) external override nonReentrant onlyNotPaused onlyRouter returns (
        uint256 id
    ) {
        if (_underlyingAmount == 0) revert ZeroAmountNotAllowed();
        _collectInterestFeeAndCommit(router.getFeeConfig());
        uint256 _borrowedUnderlying = borrowedUnderlying;
        uint256 _borrowedTeaToken = borrowedTeaToken;
        _checkBorrowable(_borrowedUnderlying, _underlyingAmount);

        uint8 _decimals = decimals();
        uint256 _suppliedTeaToken = totalSupply();
        uint256 _suppliedUnderlying = suppliedUnderlying;
        uint256 rate = LendingUtils.borrowedTeaTokenToUnderlying(
            _decimals,
            _suppliedTeaToken,
            _suppliedUnderlying,
            _borrowedTeaToken,
            _borrowedUnderlying
        );
        uint256 rateWithoutFee = LendingUtils.borrowedTeaTokenToUnderlyingWithoutFee(
            _decimals,
            _suppliedTeaToken,
            _suppliedUnderlying,
            _borrowedTeaToken,
            _borrowedUnderlying,
            unpaidBorrowFeeUnderlying
        );
        uint256 borrowedTeaTokenAmount = _underlyingAmount.mulDiv(
            LendingUtils.borrowedUnderlyingToTeaToken(_decimals, _borrowedTeaToken, _borrowedUnderlying),
            10 ** _decimals,
            Math.Rounding.Ceil
        );
        id = idCounter;
        idCounter = idCounter + 1;
        debtInfo[id] = DebtInfo({
            borrowedTeaToken: borrowedTeaTokenAmount,
            lastBorrowRate: rate,
            lastBorrowRateWithoutFee: rateWithoutFee
        });
        borrowedUnderlying = borrowedUnderlying + _underlyingAmount;
        borrowedTeaToken = borrowedTeaToken + borrowedTeaTokenAmount;

        emit Borrowed(_account, id, _underlyingAmount, borrowedTeaTokenAmount);
    }

    function repay(
        address _account,
        uint256 _id,
        uint256 _underlyingAmount
    ) external override nonReentrant onlyNotPaused returns (
        uint256 repaidUnderlyingAmount,
        uint256 unrepaidUnderlyingAmount
    ) {
        if (_underlyingAmount == 0) revert ZeroAmountNotAllowed();
        IRouter.FeeConfig memory feeConfig = router.getFeeConfig();
        _collectInterestFeeAndCommit(feeConfig);

        uint8 _decimals = decimals();
        uint256 _suppliedTeaToken = totalSupply();
        uint256 _suppliedUnderlying = suppliedUnderlying;
        uint256 _borrowedTeaToken = borrowedTeaToken;
        uint256 _borrowedUnderlying = borrowedUnderlying;
        uint256 rate = LendingUtils.borrowedTeaTokenToUnderlying(
            _decimals,
            _suppliedTeaToken,
            _suppliedUnderlying,
            _borrowedTeaToken,
            _borrowedUnderlying
        );
        uint256 rateWithoutFee = LendingUtils.borrowedTeaTokenToUnderlyingWithoutFee(
            _decimals,
            _suppliedTeaToken,
            _suppliedUnderlying,
            _borrowedTeaToken,
            _borrowedUnderlying,
            unpaidBorrowFeeUnderlying
        );

        DebtInfo memory _debtInfo = debtInfo[_id];
        uint256 _teaTokenAmount = _underlyingAmount.mulDiv(
            LendingUtils.borrowedUnderlyingToTeaToken(_decimals, _borrowedTeaToken, _borrowedUnderlying),
            10 ** _decimals
        );
        if (_teaTokenAmount >= _debtInfo.borrowedTeaToken) {
            _teaTokenAmount = _debtInfo.borrowedTeaToken;
        }

        uint256 borrowFee = _teaTokenAmount.mulDiv(
            rate + _debtInfo.lastBorrowRate - rateWithoutFee - _debtInfo.lastBorrowRateWithoutFee,
            10 ** _decimals
        );
        repaidUnderlyingAmount = _teaTokenAmount.mulDiv(10 ** _decimals, rate);
        unrepaidUnderlyingAmount = _debtInfo.borrowedTeaToken.mulDiv(rate, 10 ** _decimals) - repaidUnderlyingAmount;
        ERC20Upgradeable _underlyingAsset = underlyingAsset;
        _underlyingAsset.safeTransferFrom(_account, address(this), repaidUnderlyingAmount);
        _underlyingAsset.safeTransfer(feeConfig.treasury, borrowFee);
        debtInfo[_id].borrowedTeaToken = debtInfo[_id].borrowedTeaToken - _teaTokenAmount;

        borrowedUnderlying = _borrowedUnderlying - repaidUnderlyingAmount;
        borrowedTeaToken = _borrowedTeaToken - _teaTokenAmount;
        unpaidBorrowFeeUnderlying = unpaidBorrowFeeUnderlying - borrowFee;

        emit Repaid(_account, _id, _teaTokenAmount, repaidUnderlyingAmount);
    }

    function suppliedTeaTokenToUnderlying() external view override returns (uint256) {
        return _suppliedTeaTokenToUnderlying();
    }
    
    function _suppliedTeaTokenToUnderlying() internal view returns (uint256) {
        (uint256 interest, ) = _collectInterestAndFee(router.getFeeConfig());

        return LendingUtils.suppliedTeaTokenToUnderlying(DECIMALS, totalSupply(), suppliedUnderlying + interest);
    }

    function balanceOf(address _account) public view override(IPool, ERC20Upgradeable) returns (uint256) {
        return super.balanceOf(_account);
    }

    function balanceOfUnderlying(address _account) external view override returns (uint256) {
        return balanceOf(_account).mulDiv(_suppliedTeaTokenToUnderlying(), 10 ** DECIMALS);
    }

    function debtOf(uint256 _id) external view override returns (uint256) {
        return debtInfo[_id].borrowedTeaToken;
    }

    function borrowedTeaTokenToUnderlying() external view override returns (uint256) {
        return _borrowedTeaTokenToUnderlying();
    }

    function _borrowedTeaTokenToUnderlying() internal view returns (uint256) {
        (uint256 interest, uint256 fee) = _collectInterestAndFee(router.getFeeConfig());

        return LendingUtils.borrowedTeaTokenToUnderlying(
            DECIMALS,
            totalSupply(),
            suppliedUnderlying + interest,
            borrowedTeaToken,
            borrowedUnderlying + interest + fee
        );
    }

    function debtOfUnderlying(uint256 _id) external view override returns (uint256) {
        return debtInfo[_id].borrowedTeaToken.mulDiv(_borrowedTeaTokenToUnderlying(), 10 ** DECIMALS);
    }

    function getLendingStatus() external override view returns (uint256, uint256, uint24) {
        (uint256 interest, uint256 fee) = _collectInterestAndFee(router.getFeeConfig());

        return (suppliedUnderlying + interest, borrowedUnderlying + interest + fee, reserveRatio);
    }

    function collectInterestFeeAndCommit(IRouter.FeeConfig memory _feeConfig) external override returns (uint256 interest, uint256 fee) {
        return _collectInterestFeeAndCommit(_feeConfig);
    }

    function _collectInterestAndFee(IRouter.FeeConfig memory _feeConfig) internal view returns (uint256 interest, uint256 fee) {
        uint256 timeElapsed = block.timestamp - lastCumulateInterest;
        uint256 _borrowedUnderlying = borrowedUnderlying;
        if (_borrowedUnderlying == 0) return (interest, fee);
        
        uint256 rate = IInterestRateModel(router.getInterestRateModel(interestRateModelType)).getBorrowRate(
            suppliedUnderlying,
            _borrowedUnderlying,
            reserveRatio
        );

        // TODO: optimization?
        interest = _calculateInterests(_borrowedUnderlying, rate, timeElapsed);
        fee = _calculateInterests(_borrowedUnderlying, _feeConfig.borrowFee, timeElapsed);
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

    function _collectInterestFeeAndCommit(IRouter.FeeConfig memory _feeConfig) internal returns (uint256 interest, uint256 fee) {
        (interest, fee) = _collectInterestAndFee(_feeConfig);
        lastCumulateInterest = block.timestamp;
        suppliedUnderlying = suppliedUnderlying + interest;
        borrowedUnderlying = borrowedUnderlying + interest + fee;
        unpaidBorrowFeeUnderlying = unpaidBorrowFeeUnderlying + fee;

        if (interest > 0) emit InterestAccumulated(block.timestamp, interest);
        if (fee > 0) emit BorrowFeeAccumulated(block.timestamp, fee);
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