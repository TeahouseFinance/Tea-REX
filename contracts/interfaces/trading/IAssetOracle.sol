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

    /// @notice get asset value with the given amount
    function getValue(address _asset, uint256 _amount) external view returns (uint256 value);

    /// @notice batch version of getValue
    function getBatchValue(address[] calldata _assets,uint256[] calldata _amounts) external view returns (uint256[] memory values);
    
    /// @notice get asset value with the given amount and price
    function getValueWithPrice(address _asset, uint256 _amount, uint256 _price) external view returns (uint256 value);

    /// @notice batch version of getValueWithPrice
    function getBatchValueWithPrice(
        address[] calldata _assets,
        uint256[] calldata _amounts,
        uint256[] calldata _prices
    ) external view returns (
        uint256[] memory values
    );

    /// @notice get price of asset
    function getPrice(address _asset) external view returns (uint256 price);

    /// @notice batch version of getPrice
    function getBatchPrice(address[] calldata _assets) external view returns (uint256[] memory prices);

}