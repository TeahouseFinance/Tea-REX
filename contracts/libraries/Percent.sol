// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library Percent {
    using Math for uint256;
    using SafeCast for uint256;

    uint8 constant DECIMALS = 4;
    uint24 constant MULTIPLIER = 1000000;

    function getPortionFloor(uint256 _num, uint24 _percent) internal pure returns (uint256) {
        return _num.mulDiv(_percent, MULTIPLIER);
    }

    function getPortionCeil(uint256 _num, uint24 _percent) internal pure returns (uint256) {
        return _num.mulDiv(_percent, MULTIPLIER, Math.Rounding.Ceil);
    }
}