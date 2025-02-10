// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IInterestRateModel} from "../interfaces/lending/IInterestRateModel.sol";
import {Percent} from "../libraries/Percent.sol";

// import "hardhat/console.sol";
contract VariableInterestRateModel is IInterestRateModel {
    using Math for uint256;

    uint256 constant BASE_RATE = 10000;
    uint256 constant HIKED_RATE = 240000;

    function decimals() external pure returns (uint8) {
        return Percent.DECIMALS;
    }

    function getSupplyRate(
        uint256 supplied,
        uint256 borrowed,
        uint24 reserveRatio
    ) public pure override returns (
        uint256 supplyRate
    ) {
        supplyRate = getSupplyRate(supplied, borrowed, reserveRatio, 0);
    }

    function getSupplyRate(
        uint256 supplied,
        uint256 borrowed,
        uint24 reserveRatio,
        uint256 toSupply
    ) public pure override returns (
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
    ) public pure override returns (
        uint256 borrowRate
    ) {
        borrowRate = getBorrowRate(supplied, borrowed, reserveRatio, 0);
    }

    function getBorrowRate(
        uint256 supplied,
        uint256 borrowed,
        uint24 reserveRatio,
        uint256 toBorrow
    ) public pure override returns (
        uint256 borrowRate
    ) {
        if (supplied == 0) return BASE_RATE;

        borrowRate = BASE_RATE + HIKED_RATE.mulDiv(
            (borrowed + toBorrow) * Percent.MULTIPLIER,
            supplied * (Percent.MULTIPLIER - reserveRatio)
        );
    }
}