// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

interface IInterestRateModel {

    function decimals() external view returns (uint8 decimals);
    function getSupplyRate(uint256 supplied, uint256 borrowed, uint256 reserveRatio) external pure returns (uint256 supplyRate);
    function getSupplyRate(uint256 supplied, uint256 borrwoed, uint256 reserveRatio, uint256 toSupply) external pure returns (uint256 supplyRate);
    function getBorrowRate(uint256 supplied, uint256 borrowed, uint256 reserveRatio) external pure returns (uint256 borrowRate);
    function getBorrowRate(uint256 supplied, uint256 borrowed, uint256 reserveRatio, uint256 toBorrow) external pure returns (uint256 borrowRate);

}