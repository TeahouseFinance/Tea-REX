// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

interface IInterestRateModel {

    /// @notice Get oracle decimals
    /// @dev Return APY in percentage will be multiplied by 10^decimals
    /// @dev E.g. Return APY 12500 equals to 1.25%
    function decimals() external view returns (uint8 decimals);

    /// @notice Get supplied APY with a given lending condition
    /// @param supplied Current total supplied amount
    /// @param borrowed Current total borrowed amount
    /// @param reserveRatio Reserve ratio of the lending pool
    /// @return supplyRate Supplied APY
    function getSupplyRate(uint256 supplied, uint256 borrowed, uint24 reserveRatio) external view returns (uint256 supplyRate);
    
    /// @notice Get supplied APY with a given lending condition and the amount to supply
    /// @param supplied Current total supplied amount
    /// @param borrowed Current total borrowed amount
    /// @param reserveRatio Reserve ratio of the lending pool
    /// @param toSupply Amount to supply
    /// @return supplyRate Supplied APY
    function getSupplyRate(uint256 supplied, uint256 borrowed, uint24 reserveRatio, uint256 toSupply) external view returns (uint256 supplyRate);
    
    /// @notice Get borrowed APY with a given lending condition
    /// @param supplied Current total supplied amount
    /// @param borrowed Current total borrowed amount
    /// @param reserveRatio Reserve ratio of the lending pool
    /// @return borrowRate Borrowed APY
    function getBorrowRate(uint256 supplied, uint256 borrowed, uint24 reserveRatio) external view returns (uint256 borrowRate);
    
    /// @notice Get borrowed APY with a given lending condition and the amount to borrow
    /// @param supplied Current total supplied amount
    /// @param borrowed Current total borrowed amount
    /// @param reserveRatio Reserve ratio of the lending pool
    /// @param toBorrow Amount to borrow
    /// @return borrowRate Borrowed APY
    function getBorrowRate(uint256 supplied, uint256 borrowed, uint24 reserveRatio, uint256 toBorrow) external view returns (uint256 borrowRate);

}