// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

interface IAssetOracle {

    error AssetNotEnabled();  

    /*
        sample: price someToken (decimals = 8) / USDC (decimals = 6) = 1.234, oracle decimals = 10
        returns:
            getPrice: int(1.234 * 10 ^(6 - 8) * 10 ^ 10) = 123400000
    */

    /// @notice Get oracle decimals
    /// @return decimals Oracle decimals
    function decimals() external view returns (uint8);

    /// @notice Get oracle base asset
    /// @return baseAsset Base asset address
    function getBaseAsset() external view returns (address);

    /// @notice Get whether asset oracle is enabled
    /// @param asset Query asset
    /// @return isEnabled Whether the asset is enabled
    function isOracleEnabled(address asset) external view returns (bool);

    /// @notice Get price of asset in terms of minimal unit (e.g. weth: price of 1 wei)
    /// @param asset Query asset
    /// @return price Asset price
    function getPrice(address asset) external view returns (uint256 price);

}