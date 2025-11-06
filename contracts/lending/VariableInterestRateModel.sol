// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IInterestRateModel} from "../interfaces/lending/IInterestRateModel.sol";
import {Percent} from "../libraries/Percent.sol";

contract VariableInterestRateModel is IInterestRateModel, Ownable {
    using Math for uint256;

    struct RateConfig {
        uint256 baseRate;
        uint256 hikedRate;
    }

    RateConfig public defaultRateConfig;
    
    mapping(address => RateConfig) public rateConfig;

    constructor(address _initialOwner, RateConfig memory _defaultRateConfig) Ownable(_initialOwner) {
        defaultRateConfig = _defaultRateConfig;
    }

    function decimals() external pure returns (uint8) {
        return Percent.DECIMALS;
    }

    function setRateConfig(address _pool, RateConfig memory _rateConfig) external onlyOwner {
        rateConfig[_pool] = _rateConfig;
    }

    function _getRateConfig() internal view returns (RateConfig memory) {
        RateConfig memory _rateConfig = rateConfig[msg.sender];
        
        return (_rateConfig.baseRate + _rateConfig.hikedRate == 0) ? defaultRateConfig : _rateConfig;
    }

    function getSupplyRate(
        uint256 supplied,
        uint256 borrowed,
        uint24 reserveRatio
    ) public view override returns (
        uint256 supplyRate
    ) {
        supplyRate = getSupplyRate(supplied, borrowed, reserveRatio, 0);
    }

    function getSupplyRate(
        uint256 supplied,
        uint256 borrowed,
        uint24 reserveRatio,
        uint256 toSupply
    ) public view override returns (
        uint256 supplyRate
    ) {
        if (supplied == 0) return 0;

        uint256 totalSupplied = supplied + toSupply;
        supplyRate = borrowed.mulDiv(
            getBorrowRate(totalSupplied, borrowed, reserveRatio),
            totalSupplied
        );
    }

    function getBorrowRate(
        uint256 supplied,
        uint256 borrowed,
        uint24 reserveRatio
    ) public view override returns (
        uint256 borrowRate
    ) {
        borrowRate = getBorrowRate(supplied, borrowed, reserveRatio, 0);
    }

    function getBorrowRate(
        uint256 supplied,
        uint256 borrowed,
        uint24 reserveRatio,
        uint256 toBorrow
    ) public view override returns (
        uint256 borrowRate
    ) {
        RateConfig memory _rateConfig = _getRateConfig();
        if (supplied == 0) return _rateConfig.baseRate;

        uint256 _hikedRate = _rateConfig.hikedRate.mulDiv(
            (borrowed + toBorrow) * Percent.MULTIPLIER,
            supplied * (Percent.MULTIPLIER - reserveRatio)
        );

        borrowRate = _rateConfig.baseRate + (_hikedRate > _rateConfig.hikedRate ? _rateConfig.hikedRate : _hikedRate);
    }
}
