// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";

contract UniswapV3TwapOracle is IAssetOracle, Ownable {
    using FullMath for uint256;

    error AssetNotInPool();
    error ZeroTwapIntervalNotAllowed();  
    error ConfigLengthMismatch();
    error BaseAssetCannotBeReenabled();
    error BaseAssetMismatch();

    struct PoolInfo {
        IUniswapV3Pool pool;
        uint32 twapInterval;
        uint8 decimals0;
        uint8 decimals1;
        bool assetIsToken0;
    }
    
    uint256 private constant POW_2_64 = 1 << 64;
    uint256 private constant POW_2_128 = 1 << 128;
    uint256 private constant POW_2_192 = 1 << 192;
    address immutable public baseAsset;
    uint8 private constant DECIMALS = 36;
    mapping(address => PoolInfo[]) public poolInfoChain;

    constructor(address _owner, address _baseAsset) Ownable(_owner) {
        baseAsset = _baseAsset;

        poolInfoChain[_baseAsset].push(PoolInfo({
            pool: IUniswapV3Pool(address(1)),
            twapInterval: 0,
            decimals0: ERC20(_baseAsset).decimals(),
            decimals1: 0,
            assetIsToken0: true
        }));
    }

    /// @inheritdoc IAssetOracle
    function decimals() external override pure returns (uint8) {
        return DECIMALS;
    }

    /// @inheritdoc IAssetOracle
    function getBaseAsset() external override view returns (address) {
        return baseAsset;
    }

    /// @inheritdoc IAssetOracle
    function isOracleEnabled(address _asset) external override view returns (bool) {
        return poolInfoChain[_asset].length != 0;
    }

    function enableOracle(address _asset, IUniswapV3Pool[] calldata _pools, uint32[] calldata _twapIntervals) external onlyOwner {
        if (_pools.length != _twapIntervals.length) revert ConfigLengthMismatch();
        if (_asset == baseAsset) revert BaseAssetCannotBeReenabled();

        // reset mapping before setting
        delete poolInfoChain[_asset];
        PoolInfo[] storage _poolInfoChain = poolInfoChain[_asset];
        address token0;
        address token1;
        
        for (uint256 i; i < _pools.length; ) {
            if (_twapIntervals[i] == 0) revert ZeroTwapIntervalNotAllowed();
            token0 = _pools[i].token0();
            token1 = _pools[i].token1();
            if (_asset != token0 && _asset != token1) revert AssetNotInPool();
            _poolInfoChain.push(PoolInfo({
                pool: _pools[i],
                twapInterval: _twapIntervals[i],
                decimals0: ERC20(token0).decimals(),
                decimals1: ERC20(token1).decimals(),
                assetIsToken0: _asset == token0
            }));
            _asset = _asset == token0 ? token1 : token0;

            unchecked { i = i + 1; }
        }
        if (token0 != baseAsset && token1 != baseAsset) revert BaseAssetMismatch();
    }

    /// @inheritdoc IAssetOracle
    function getPrice(address _asset) external override view returns (uint256 price) {
        PoolInfo[] memory _poolInfoChain = poolInfoChain[_asset];
        if (_poolInfoChain.length == 0) revert AssetNotEnabled();

        price = 10 ** DECIMALS;
        if (address(_poolInfoChain[0].pool) == address(1)) {
            return price;
        }

        uint256 relativePrice;
        uint32[] memory secondsAgo = new uint32[](2);
        int56[] memory tickCumulatives;
        uint256 sqrtPriceX96;
        PoolInfo memory _poolInfo;

        for (uint256 i; i < _poolInfoChain.length; ) {
            _poolInfo = _poolInfoChain[i];

            secondsAgo[0] = _poolInfo.twapInterval;
            (tickCumulatives, ) = _poolInfo.pool.observe(secondsAgo);
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
                int24((tickCumulatives[1] - tickCumulatives[0]) / int64(uint64(_poolInfo.twapInterval)))
            );
            if (_poolInfo.assetIsToken0) {
                if (sqrtPriceX96 <= type(uint128).max) {
                    uint256 priceX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
                    relativePrice = _poolInfo.decimals0 > _poolInfo.decimals1 ? 
                        priceX192.mulDiv(10 ** (DECIMALS + _poolInfo.decimals0 - _poolInfo.decimals1), POW_2_192) : 
                        priceX192.mulDiv(10 ** DECIMALS, POW_2_192) / (10 ** (_poolInfo.decimals1 - _poolInfo.decimals0));
                }
                else {
                    uint256 priceX128 = sqrtPriceX96.mulDiv(sqrtPriceX96, POW_2_64);
                    relativePrice = _poolInfo.decimals0 > _poolInfo.decimals1 ? 
                        priceX128.mulDiv(10 ** (DECIMALS + _poolInfo.decimals0 - _poolInfo.decimals1), POW_2_128) : 
                        priceX128.mulDiv(10 ** DECIMALS, POW_2_128) / (10 ** (_poolInfo.decimals1 - _poolInfo.decimals0));
                }
            }
            else {
                relativePrice = _poolInfo.decimals1 > _poolInfo.decimals0 ? 
                    POW_2_192.mulDiv(10 ** DECIMALS, sqrtPriceX96).mulDiv(
                        10 ** (_poolInfo.decimals1 - _poolInfo.decimals0),
                        sqrtPriceX96
                    ) : 
                    POW_2_192.mulDiv(
                        10 ** DECIMALS,
                        sqrtPriceX96
                    ) / 10 ** (_poolInfo.decimals0 - _poolInfo.decimals1) / sqrtPriceX96;
            }
            price = price.mulDiv(relativePrice, 10 ** DECIMALS);

            unchecked { i = i + 1; }
        }
    }
}