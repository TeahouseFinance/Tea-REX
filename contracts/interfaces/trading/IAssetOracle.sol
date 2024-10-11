// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

interface IAssetOracle {

    error BaseAssetCannotBeReenabled();
    error ConfigLengthMismatch();
    error BaseAssetMismatch();
    error AssetNotEnabled();
    error BatchLengthMismatched();
    error AssetNotInPool();
    error ZeroTwapIntervalNotAllowed();    

    /*
        sample: asset = USDT (decimals = 6), price (USDT/USDC) = 1.001, oracle decimals = 4, amount = 123000000
        returns:
            getValue: 123 * getTwap = 1231230
            getPrice: 10010
    */

    /// @notice get oracle decimals
    function decimals() external view returns (uint8);

    /// @notice get oracle base asset
    function getBaseAsset() external view returns (address);

    /// @notice get whether asset oracle is enabled
    function isOracleEnabled(address _asset) external view returns (bool);

    /// @notice get price of asset
    function getPrice(address _asset) external view returns (uint256 price);

}