// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";
import {IFeeManager} from "../interfaces/3rdparty/IFeeManager.sol";
import {IVerifierProxy} from "../interfaces/3rdparty/IVerifierProxy.sol";
import {IVerifierFeeManager} from "../interfaces/3rdparty/IVerifierFeeManager.sol";
import {Common} from "../libraries/3rdparty/Common.sol";


/// @title Price oracle contract for Chainlink Data Streams
contract ChainlinkDataStreamOracle is IAssetOracle, Ownable {

    error InvalidAddress();
    error InvalidFeedId();
    error OraclePriceIsInvalid();
    error OraclePriceIsTooOld();
    error NotWhitelisted();
    error InvalidReportVersion(uint16 version);

    event AddAsset(address indexed asset, bytes32 feedId, uint8 priceDecimals, uint32 priceTimeLimit);
    event RemoveAsset(address indexed asset, bytes32 feedId);
    event ChangePriceTimeLimit(address indexed asset, uint32 priceTimeLimit);
    event SetWhitelist(address indexed caller, bool allow);
    event WithdrawTokens(address indexed token, uint256 amount, address receiver);
    event VerifyReport(address indexed token, bytes32 feedId, int192 price, uint32 validFromTimestamp);

    // ----------------- Report schemas -----------------
    // More info: https://docs.chain.link/data-streams/reference/report-schema
    struct ReportV2 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
    }

    /**
     * @dev Data Streams report schema v3 (crypto streams).
     *      Prices, bids and asks use 8 or 18 decimals depending on the stream.
     */
    struct ReportV3 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        int192 bid;
        int192 ask;
    }

    /**
     * @dev Data Streams report schema v4 (RWA streams).
     */
    struct ReportV4 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        uint32 marketStatus;
    }

    struct OracleInfo {
        bytes32 feedId;
        int192 lastPrice;
        uint32 validFromTimestamp;
        uint32 priceTimeLimit;
        uint8 assetDecimals;
        uint8 priceDecimals;
        uint8 totalDecimals;
    }

    uint8 immutable private priceDecimals;
    address immutable private baseAsset;
    IVerifierProxy immutable private verifierProxy;
    mapping(bytes32 => address) public assets;
    mapping(address => OracleInfo) public oracleInfo;
    mapping(address => bool) public whitelist;

    constructor(
        address _owner,
        uint8 _decimals,
        IVerifierProxy _verifierProxy,
        address _baseAsset,
        bytes32 _baseFeedId,
        uint8 _basePriceDecimals,
        uint32 _priceTimeLimit
    ) Ownable(_owner) {
        verifierProxy = _verifierProxy;
        priceDecimals = _decimals;
        baseAsset = _baseAsset;
        _addAsset(_baseAsset, _baseFeedId, _basePriceDecimals, _priceTimeLimit);
    }

    function decimals() external view returns (uint8) {
        return priceDecimals;
    }

    function getBaseAsset() external view returns (address) {
        return address(baseAsset);
    }

    function getVerifierProxy() external view returns (address) {
        return address(verifierProxy);
    }

    function setAsset(address _asset, bytes32 _feedId, uint8 _priceDecimals, uint32 _priceTimeLimit) external onlyOwner {
        _addAsset(_asset, _feedId, _priceDecimals, _priceTimeLimit);
    }

    function removeAsset(address _asset) external onlyOwner {
        require(_asset != address(0), InvalidAddress());
        require(_asset != address(baseAsset), InvalidAddress());

        bytes32 feedId = oracleInfo[_asset].feedId;
        require(feedId != bytes32(0), InvalidFeedId());

        delete assets[feedId];
        delete oracleInfo[_asset];

        emit RemoveAsset(_asset, feedId);
    }

    function changeAssetPriceTimeLimit(address _asset, uint32 _priceTimeLimit) external onlyOwner {
        require(_asset != address(0), InvalidAddress());

        OracleInfo storage info = oracleInfo[_asset];
        info.priceTimeLimit = _priceTimeLimit;

        emit ChangePriceTimeLimit(_asset, _priceTimeLimit);
    }

    function setWhitelist(address _caller, bool _allow) external onlyOwner {
        require(_caller != address(0), InvalidAddress());
        whitelist[_caller] = _allow;

        emit SetWhitelist(_caller, _allow);
    }

    function withdrawTokens(address _token, uint256 _amount, address _receiver) external onlyOwner {
        require(_token != address(0), InvalidAddress());
        require(_receiver != address(0), InvalidAddress());

        IERC20Metadata(_token).transfer(_receiver, _amount);

        emit WithdrawTokens(_token, _amount, _receiver);
    }

    function _addAsset(address _asset, bytes32 _feedId, uint8 _priceDecimals, uint32 _priceTimeLimit) internal {
        require(address(_asset) != address(0), InvalidAddress());
        require(assets[_feedId] == address(0), InvalidFeedId());

        assets[_feedId] = _asset;
        OracleInfo storage info = oracleInfo[_asset];

        info.feedId = _feedId;
        info.priceTimeLimit = _priceTimeLimit;
        info.assetDecimals = IERC20Metadata(_asset).decimals();
        info.priceDecimals = _priceDecimals;
        info.totalDecimals = info.assetDecimals + info.priceDecimals;

        emit AddAsset(_asset, _feedId, _priceDecimals, _priceTimeLimit);
    }

    function isOracleEnabled(address _asset) external view returns (bool) {
        return oracleInfo[_asset].feedId != bytes32(0);
    }

    function getPrice(address _asset) external view returns (uint256 price) {
        OracleInfo storage assetInfo = oracleInfo[_asset];
        require(assetInfo.feedId != bytes32(0), AssetNotEnabled());

        if (_asset == address(baseAsset)) {
            return 10 ** priceDecimals;
        }

        OracleInfo storage baseInfo = oracleInfo[baseAsset];

        int256 assetPrice = assetInfo.lastPrice;
        uint32 assetUpdateTime = assetInfo.validFromTimestamp;
        int256 basePrice = baseInfo.lastPrice;
        uint32 baseUpdateTime = baseInfo.validFromTimestamp;

        if (assetUpdateTime + assetInfo.priceTimeLimit < block.timestamp) {
            revert OraclePriceIsTooOld();
        }

        if (baseUpdateTime + baseInfo.priceTimeLimit < block.timestamp) {
            revert OraclePriceIsTooOld();
        }

        if (assetPrice < 0) revert OraclePriceIsInvalid();
        if (basePrice < 0) revert OraclePriceIsInvalid();

        uint256 mulDecimals = baseInfo.totalDecimals + priceDecimals;
        uint256 divDecimals = assetInfo.totalDecimals;
        if (mulDecimals > divDecimals) {
            price = Math.mulDiv(uint256(assetPrice), 10 ** (mulDecimals - divDecimals), uint256(basePrice));
        }
        else {
            price = uint256(assetPrice) / (10 ** (divDecimals - mulDecimals)) / uint256(basePrice);
        }
    }

    function verifyReports(bytes[] memory unverifiedReports) external {
        require(whitelist[msg.sender], NotWhitelisted());

        for (uint256 i = 0; i < unverifiedReports.length; i++) {
            _verifyReport(unverifiedReports[i]);
        }
    }

    // from Chainlink's tutorial contract
    function _verifyReport(bytes memory unverifiedReport) internal {
        // ─── 1. & 2. Extract reportData and schema version ──
        (, bytes memory reportData) = abi.decode(
            unverifiedReport,
            (bytes32[3], bytes)
        );

        uint16 reportVersion = (uint16(uint8(reportData[0])) << 8) |
            uint16(uint8(reportData[1]));

        // ─── 3. Fee handling ──
        IFeeManager feeManager = IFeeManager(
            address(verifierProxy.s_feeManager())
        );

        bytes memory parameterPayload;
        if (address(feeManager) != address(0)) {
            // FeeManager exists — always quote & approve
            address feeToken = feeManager.i_linkAddress();

            (Common.Asset memory fee, , ) = feeManager.getFeeAndReward(
                address(this),
                reportData,
                feeToken
            );

            IERC20Metadata(feeToken).approve(feeManager.i_rewardManager(), fee.amount);
            parameterPayload = abi.encode(feeToken);
        } else {
            // No FeeManager deployed on this chain
            parameterPayload = bytes("");
        }

        // ─── 4. Verify through the proxy ──
        bytes memory verified = verifierProxy.verify(
            unverifiedReport,
            parameterPayload
        );

        // ─── 5. Decode & store price ──
        if (reportVersion == 2) {
            ReportV2 memory report = abi.decode(verified, (ReportV2));
            address asset = assets[report.feedId];
            require(asset != address(0), InvalidFeedId());

            OracleInfo storage info = oracleInfo[asset];
            if (info.validFromTimestamp < report.validFromTimestamp) {
                info.lastPrice = report.price;
                info.validFromTimestamp = report.validFromTimestamp;
            }

            emit VerifyReport(asset, report.feedId, report.price, report.validFromTimestamp);
        }
        else if (reportVersion == 3) {
            ReportV3 memory report = abi.decode(verified, (ReportV3));
            address asset = assets[report.feedId];
            require(asset != address(0), InvalidFeedId());

            OracleInfo storage info = oracleInfo[asset];
            if (info.validFromTimestamp < report.validFromTimestamp) {
                info.lastPrice = report.price;
                info.validFromTimestamp = report.validFromTimestamp;
            }

            emit VerifyReport(asset, report.feedId, report.price, report.validFromTimestamp);
        }
        else if (reportVersion == 4) {
            ReportV4 memory report = abi.decode(verified, (ReportV4));
            address asset = assets[report.feedId];
            require(asset != address(0), InvalidFeedId());

            OracleInfo storage info = oracleInfo[asset];
            if (info.validFromTimestamp < report.validFromTimestamp) {
                info.lastPrice = report.price;
                info.validFromTimestamp = report.validFromTimestamp;
            }

            emit VerifyReport(asset, report.feedId, report.price, report.validFromTimestamp);
        }
        else {
            revert InvalidReportVersion(reportVersion);
        }
    }
}
