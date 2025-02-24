// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";

/// replace 
contract UniswapV3Processor is ICalldataProcessor {

    error InvalidCalldata();

    function processCalldata(uint256 amount, bytes calldata data) external pure returns (bytes memory processedCalldata) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == ISwapRouter.exactOutputSingle.selector) {
            (ISwapRouter.ExactOutputSingleParams memory params) = abi.decode(data[4:], (ISwapRouter.ExactOutputSingleParams));
            params.amountOut = amount;
            return abi.encodeCall(ISwapRouter.exactOutputSingle, (params));
        }
        else if (selector == ISwapRouter.exactOutput.selector) {
            (ISwapRouter.ExactOutputParams memory params) = abi.decode(data[4:], (ISwapRouter.ExactOutputParams));
            params.amountOut = amount;
            return abi.encodeCall(ISwapRouter.exactOutput, (params));
        }
        else if (selector == IV3SwapRouter.exactOutputSingle.selector) {
            (IV3SwapRouter.ExactOutputSingleParams memory params) = abi.decode(data[4:], (IV3SwapRouter.ExactOutputSingleParams));
            params.amountOut = amount;
            return abi.encodeCall(IV3SwapRouter.exactOutputSingle, (params));
        }
        else if (selector == IV3SwapRouter.exactOutput.selector) {
            (IV3SwapRouter.ExactOutputParams memory params) = abi.decode(data[4:], (IV3SwapRouter.ExactOutputParams));
            params.amountOut = amount;
            return abi.encodeCall(IV3SwapRouter.exactOutput, (params));
        }
        else {
            revert InvalidCalldata();
        }
    }

}
