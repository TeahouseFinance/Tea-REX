// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";


interface IOracle {
    // Queries
    function getExchangeRates() external view returns (DenomOracleExchangeRatePair[] memory);
    function getOracleTwaps(uint64 lookback_seconds) external view returns (OracleTwap[] memory);

    // Structs
    struct OracleExchangeRate {
        string exchangeRate;
        string lastUpdate;
        int64 lastUpdateTimestamp;
    }

    struct DenomOracleExchangeRatePair {
        string denom;
        OracleExchangeRate oracleExchangeRateVal;
    }

    struct OracleTwap {
        string denom;
        string twap;
        int64 lookbackSeconds;
    }
}


contract SEINativeOracle is IAssetOracle, Ownable {

    error InvalidAssetAddress();
    error UnknownToken();
    error InvalidPriceString();

    struct OracleInfo {
        bytes32 nameHash;
        uint32 nameLength;
        uint8 assetDecimals;
    }

    address constant private ORACLE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000001008;
    IOracle constant private ORACLE_CONTRACT = IOracle(ORACLE_PRECOMPILE_ADDRESS);

    uint8 private priceDecimals;
    uint64 public lookbackSeconds;
    IERC20Metadata private baseAsset;
    mapping(IERC20Metadata => OracleInfo) public oracleInfo;

    constructor(
        address _owner,
        uint8 _decimals,
        uint64 _lookbackSeconds,
        IERC20Metadata _baseAsset,
        string memory _baseAssetName
    ) Ownable(_owner) {
        priceDecimals = _decimals;
        baseAsset = _baseAsset;
        lookbackSeconds = _lookbackSeconds;
        _addAsset(_baseAsset, _baseAssetName);
    }

    function decimals() external view returns (uint8) {
        return priceDecimals;
    }

    function getBaseAsset() external view returns (address) {
        return address(baseAsset);
    }

    function updateLookbackSeconds(uint64 _lookbackSeconds) external onlyOwner {
        lookbackSeconds = _lookbackSeconds;
    }

    function setAsset(address _asset, string calldata _assetName) external onlyOwner {
        _addAsset(IERC20Metadata(_asset), _assetName);
    }

    function removeAsset(address _asset) external onlyOwner {
        require(_asset != address(0), InvalidAssetAddress());
        require(_asset != address(baseAsset), InvalidAssetAddress());

        delete oracleInfo[IERC20Metadata(_asset)];
    }

    function _addAsset(IERC20Metadata _asset, string memory _assetName) internal {
        require(address(_asset) != address(0), InvalidAssetAddress());

        OracleInfo storage info = oracleInfo[_asset];
        info.nameHash = keccak256(bytes(_assetName));
        info.nameLength = uint32(bytes(_assetName).length);
        info.assetDecimals = _asset.decimals();  // token is assumed to have decimals() function
    }

    function isOracleEnabled(address _asset) external view returns (bool) {
        return oracleInfo[IERC20Metadata(_asset)].nameHash != bytes32(0);
    }

    function getPrice(address _asset) external view returns (uint256 price) {
        OracleInfo memory assetInfo = oracleInfo[IERC20Metadata(_asset)];
        OracleInfo memory baseInfo = oracleInfo[baseAsset];
        require(assetInfo.nameHash != bytes32(0), AssetNotEnabled());

        if (_asset == address(baseAsset)) {
            return 10 ** priceDecimals;
        }

        uint256 basePrice;
        uint256 assetPrice;

        if (lookbackSeconds == 0) {
            // use spot price
            IOracle.DenomOracleExchangeRatePair[] memory results = ORACLE_CONTRACT.getExchangeRates();

            for (uint256 i = 0; i < results.length; ) {
                if (bytes(results[i].denom).length == assetInfo.nameLength && keccak256(bytes(results[i].denom)) == assetInfo.nameHash) {
                    assetPrice = _decodePrice(results[i].oracleExchangeRateVal.exchangeRate);
                }
                else if (bytes(results[i].denom).length == baseInfo.nameLength && keccak256(bytes(results[i].denom)) == baseInfo.nameHash) {
                    basePrice = _decodePrice(results[i].oracleExchangeRateVal.exchangeRate);
                }

                unchecked { ++i; }
            }
        }
        else {
            // use twap price
            IOracle.OracleTwap[] memory results = ORACLE_CONTRACT.getOracleTwaps(lookbackSeconds);

            for (uint256 i = 0; i < results.length; ) {
                if (bytes(results[i].denom).length == assetInfo.nameLength && keccak256(bytes(results[i].denom)) == assetInfo.nameHash) {
                    assetPrice = _decodePrice(results[i].twap);
                }
                else if (bytes(results[i].denom).length == baseInfo.nameLength && keccak256(bytes(results[i].denom)) == baseInfo.nameHash) {
                    basePrice = _decodePrice(results[i].twap);
                }

                unchecked { ++i; }
            }
        }

        if (basePrice == 0 || assetPrice == 0) {
            revert UnknownToken();
        }

        uint256 mulDecimals = baseInfo.assetDecimals + priceDecimals;
        uint256 divDecimals = assetInfo.assetDecimals;
        if (mulDecimals > divDecimals) {
            price = Math.mulDiv(assetPrice, 10 ** (mulDecimals - divDecimals), basePrice);
        }
        else {
            price = assetPrice / (10 ** (divDecimals - mulDecimals)) / basePrice;
        }
    }
    
    function _decodePrice(string memory data) internal view returns (uint256 price) {
        uint256 intPart = 0;
        uint256 decFactor = 10 ** (priceDecimals - 1);
        uint256 decPart = 0;
        uint256 i = 0;
        bytes memory dataBytes = bytes(data);
        uint256 dataLength = bytes(data).length;

        while (i < dataLength) {
            if (dataBytes[i] >= 0x30 && dataBytes[i] <= 0x39) { // digits
                intPart *= 10;
                intPart += uint256(uint8(dataBytes[i])) - 0x30;
            }
            else if (dataBytes[i] == 0x2e) {  // '.'
                i++;
                break;
            }
            else {
                revert InvalidPriceString();
            }

            i++;
        }

        while (i < dataLength) {
            if (dataBytes[i] >= 0x30 && dataBytes[i] <= 0x39) { // digits
                decPart += decFactor * (uint256(uint8(dataBytes[i])) - 0x30);
                decFactor /= 10;
            }
            else {
                revert InvalidPriceString();
            }
            
            i++;
        }

        return intPart * 10 ** priceDecimals + decPart;
    }
}
