// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";


contract MockOracle is IAssetOracle, Ownable {

    error InvalidAssetAddress();

    uint8 private priceDecimals;
    address private baseAsset;
    mapping(address => uint256) public assetPrice;

    constructor(address _owner, uint8 _decimals, address _baseAsset) Ownable(_owner) {
        priceDecimals = _decimals;
        baseAsset = _baseAsset;
    }

    function decimals() external view returns (uint8) {
        return priceDecimals;
    }

    function getBaseAsset() external view returns (address) {
        return baseAsset;
    }

    function setTokenPrice(address _asset, uint256 _price) external onlyOwner {
        assetPrice[_asset] = _price;
    }

    function removeToken(address _asset) external onlyOwner {
        require(address(_asset) != address(0), InvalidAssetAddress());
        require(_asset != address(baseAsset), InvalidAssetAddress());

        delete assetPrice[_asset];
    }

    function isOracleEnabled(address _asset) external view returns (bool) {
        return assetPrice[_asset] != 0;
    }

    function getPrice(address _asset) external view returns (uint256 price) {
        if (_asset == baseAsset) {
            return 10 ** priceDecimals;
        }

        require(assetPrice[_asset] != 0, AssetNotEnabled());
        return assetPrice[_asset];
    }
}
