// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LendingUtils {
    using Math for uint256;

    function getSupplyQuota(uint256 _cap, uint256 _suppliedUnderlying) internal pure returns (uint256) {
        return _suppliedUnderlying >= _cap ? 0 : _cap - _suppliedUnderlying;
    }

    function getWithdrawQuota(
        uint256 _suppliedUnderlying,
        uint256 _unpaidBorrowFeeUnderlying,
        uint256 _borrowedUnderlying
    ) internal pure returns (uint256) {
        return _suppliedUnderlying + _unpaidBorrowFeeUnderlying > _borrowedUnderlying ?
            _suppliedUnderlying + _unpaidBorrowFeeUnderlying - _borrowedUnderlying :
            0;
    }

    function suppliedTeaTokenToUnderlying(
        uint8 _decimals,
        uint256 _suppliedTeaToken,
        uint256 _suppliedUnderlying
    ) internal pure returns (uint256) {
        return _suppliedTeaToken != 0 ?
            _suppliedUnderlying.mulDiv(10 ** _decimals, _suppliedTeaToken) :
            10 ** _decimals;
    }

    function suppliedUnderlyingToTeaToken(
        uint8 _decimals,
        uint256 _suppliedTeaToken,
        uint256 _suppliedUnderlying
    ) internal pure returns (uint256) {
        return _suppliedUnderlying != 0 ?
            _suppliedTeaToken.mulDiv(10 ** _decimals, _suppliedUnderlying) :   
            10 ** _decimals;
    }

    function borrowedTeaTokenToUnderlying(
        uint8 _decimals,
        uint256 _suppliedTeaToken,
        uint256 _suppliedUnderlying,
        uint256 _borrowedTeaToken,
        uint256 _borrowedUnderlying
    ) internal pure returns (uint256) {
        return _borrowedTeaToken != 0 ?
            _borrowedUnderlying.mulDiv(10 ** _decimals, _borrowedTeaToken) :
            _suppliedTeaToken != 0 ?
                _suppliedUnderlying.mulDiv(10 ** _decimals, _suppliedTeaToken) :
                10 ** _decimals;
    }

    function borrowedUnderlyingToTeaToken(
        uint8 _decimals,
        uint256 _borrowedTeaToken,
        uint256 _borrowedUnderlying
    ) internal pure returns (uint256 rate) {
        return _borrowedUnderlying != 0 ?
            _borrowedTeaToken.mulDiv(10 ** _decimals, _borrowedUnderlying) :
            10 ** _decimals;
    }

    function borrowedTeaTokenToUnderlyingWithoutFee(
        uint8 _decimals,
        uint256 _suppliedTeaToken,
        uint256 _suppliedUnderlying,
        uint256 _borrowedTeaToken,
        uint256 _borrowedUnderlying,
        uint256 _unpaidBorrowFeeUnderlying
    ) internal pure returns (uint256 rate) {
        return _borrowedTeaToken != 0 ?
            (_borrowedUnderlying - _unpaidBorrowFeeUnderlying).mulDiv(10 ** _decimals, _borrowedTeaToken) :
            _suppliedTeaToken != 0 ?
                _suppliedUnderlying.mulDiv(10 ** _decimals, _suppliedTeaToken) :
                10 ** _decimals;
    }

    function borrowedUnderlyingWithoutFeeToTeaToken(
        uint8 _decimals,
        uint256 _borrowedTeaToken,
        uint256 _borrowedUnderlying,
        uint256 _unpaidBorrowFeeUnderlying
    ) internal pure returns (uint256 rate) {
        return _borrowedUnderlying != 0 ?
            _borrowedTeaToken.mulDiv(10 ** _decimals, _borrowedUnderlying - _unpaidBorrowFeeUnderlying) :   
            10 ** _decimals;
    }
}