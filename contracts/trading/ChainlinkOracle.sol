// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";


contract ChainlinkOracle is IAssetOracle, Ownable {

    error InvalidAssetAddress();
    error OraclePriceIsInvalid();
    error OraclePriceIsTooOld();

    struct OracleInfo {
        AggregatorV3Interface priceOracle;
        uint8 priceDecimals;
        uint8 assetDecimals;
        uint8 totalDecimals;
        uint64 priceTimeLimit;
    }

    uint8 private priceDecimals;
    IERC20Metadata private baseAsset;
    mapping(IERC20Metadata => OracleInfo) public oracleInfo;

    constructor(
        address _owner,
        uint8 _decimals,
        IERC20Metadata _baseAsset,
        AggregatorV3Interface _baseOracle
    ) Ownable(_owner) {
        priceDecimals = _decimals;
        baseAsset = _baseAsset;
        _addAsset(_baseAsset, _baseOracle);
    }

    function decimals() external view returns (uint8) {
        return priceDecimals;
    }

    function getBaseAsset() external view returns (address) {
        return address(baseAsset);
    }

    function setAsset(address _asset, AggregatorV3Interface _priceOracle) external onlyOwner {
        _addAsset(IERC20Metadata(_asset), _priceOracle);
    }

    function removeAsset(address _asset) external onlyOwner {
        require(_asset != address(0), InvalidAssetAddress());
        require(_asset != address(baseAsset), InvalidAssetAddress());

        delete oracleInfo[IERC20Metadata(_asset)];
    }

    function _addAsset(IERC20Metadata _asset, AggregatorV3Interface _priceOracle) internal {
        require(address(_asset) != address(0), InvalidAssetAddress());

        OracleInfo storage info = oracleInfo[_asset];
        info.priceOracle = _priceOracle;
        info.assetDecimals = _asset.decimals();  // token is assumed to have decimals() function
        info.priceDecimals = _priceOracle.decimals();
        info.totalDecimals = info.assetDecimals + info.priceDecimals;
    }

    function isOracleEnabled(address _asset) external view returns (bool) {
        return address(oracleInfo[IERC20Metadata(_asset)].priceOracle) != address(0);
    }

    function getPrice(address _asset) external view returns (uint256 price) {
        OracleInfo storage assetInfo = oracleInfo[IERC20Metadata(_asset)];
        require(address(assetInfo.priceOracle) != address(0), AssetNotEnabled());

        if (_asset == address(baseAsset)) {
            return 10 ** priceDecimals;
        }

        OracleInfo storage baseInfo = oracleInfo[baseAsset];

        (,int256 assetPrice,,uint256 assetUpdateTime,) = assetInfo.priceOracle.latestRoundData();
        (,int256 basePrice,,uint256 baseUpdateTime,) = baseInfo.priceOracle.latestRoundData();

        // L-07
        if (assetUpdateTime + assetInfo.priceTimeLimit < block.timestamp) {
            revert OraclePriceIsTooOld();
        }

        if (baseUpdateTime + baseInfo.priceTimeLimit < block.timestamp) {
            revert OraclePriceIsTooOld();
        }

        // L-01
        if (assetPrice < 0) revert OraclePriceIsInvalid();
        if (basePrice < 0) revert OraclePriceIsInvalid();

        // L-07
        if (assetUpdateTime + uint256(assetInfo.priceTimeLimit) < block.timestamp) {
            revert OraclePriceIsTooOld();
        }

        if (baseUpdateTime + uint256(baseInfo.priceTimeLimit) < block.timestamp) {
            revert OraclePriceIsTooOld();
        }

        uint256 mulDecimals = baseInfo.totalDecimals + priceDecimals;
        uint256 divDecimals = assetInfo.totalDecimals;
        if (mulDecimals > divDecimals) {
            price = Math.mulDiv(uint256(assetPrice), 10 ** (mulDecimals - divDecimals), uint256(basePrice));
        }
        else {
            price = uint256(assetPrice) / (10 ** (divDecimals - mulDecimals)) / uint256(basePrice);
        }
    }
}
