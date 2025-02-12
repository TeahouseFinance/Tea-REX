// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;


import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketNFT} from "../trading/MarketNFT.sol";


contract MarketPriceHelper {
    using Math for uint256;

    error TooManyMarkets();

    uint8 public decimals;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function getMarketPrices(MarketNFT[] calldata markets) external view returns (uint256[] memory prices, uint256 timestamp) {
        uint256 length = markets.length;
        prices = new uint256[](length);
        timestamp = block.timestamp;

        for (uint i = 0; i < length; i++) {
            (, uint256 price0, uint256 price1) = markets[i].getTokenPrices();
            bool isToken0Margin = markets[i].isToken0Margin();
            uint8 token0Decimals = IERC20Metadata(markets[i].token0()).decimals();
            uint8 token1Decimals = IERC20Metadata(markets[i].token1()).decimals();

            if (isToken0Margin) {
                if (decimals + token1Decimals >= token0Decimals) {
                    uint256 exp = 10 ** (decimals + token1Decimals - token0Decimals);
                    prices[i] = price1.mulDiv(exp, price0);
                }
                else {
                    uint256 exp = 10 ** (token0Decimals - decimals - token1Decimals);
                    prices[i] = price1 / price0 / exp;
                }
            }
            else {
                if (decimals + token0Decimals >= token1Decimals) {
                    uint256 exp = 10 ** (decimals + token0Decimals - token1Decimals);
                    prices[i] = price0.mulDiv(exp, price1);
                }
                else {
                    uint256 exp = 10 ** (token1Decimals - decimals - token0Decimals);
                    prices[i] = price0 / price1 / exp;
                }
            }
        }
    }
}
