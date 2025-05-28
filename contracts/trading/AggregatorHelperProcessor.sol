// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {IAggregatorHelper} from "../interfaces/trading/IAggregatorHelper.sol";
import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";

contract AggregatorHelperProcessor is ICalldataProcessor {

    error InvalidCalldata();

    function processCalldata(uint256 amount, bytes calldata data) external pure returns (bytes memory processedCalldata) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == IAggregatorHelper.swapExactOutput.selector) {
            (
                address src,
                address dst,
                uint256 amountIn,
                uint256 amountOut,
                address verifier,
                bytes memory verifierCalldata,
                address aggregator,
                bytes memory aggregatorCalldata,
                address scrapRouter,
                bytes memory scrapCalldata,
                uint256 scrapAmountOffset
            ) = abi.decode(data[4:], (address, address, uint256, uint256, address, bytes, address, bytes, address, bytes, uint256));
            amountOut = amount;
            return abi.encodeCall(IAggregatorHelper.swapExactOutput, (src, dst, amountIn, amountOut, verifier, verifierCalldata, aggregator, aggregatorCalldata, scrapRouter, scrapCalldata, scrapAmountOffset));
        }
        else {
            revert InvalidCalldata();
        }
    }

}
