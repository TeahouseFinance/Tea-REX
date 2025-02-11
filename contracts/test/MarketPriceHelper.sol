// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {IMarketNFT} from "../interfaces/trading/IMarketNFT.sol";

contract MarketPriceHelper {

    error TooManyMarkets();

    struct MarketPrices {
        uint8 decimals;
        uint256 price0;
        uint256 price1;
    }

    function getMarketPrices(IMarketNFT[] calldata markets) external view returns (MarketPrices[] memory prices, uint256 timestamp) {
        uint256 length = markets.length;
        prices = new MarketPrices[](length);
        timestamp = block.timestamp;

        for (uint i = 0; i < length; i++) {
            (uint8 decimals, uint256 price0, uint256 price1) = markets[i].getTokenPrices();
            prices[i].decimals = decimals;
            prices[i].price0 = price0;
            prices[i].price1 = price1;
        }
    }
}
