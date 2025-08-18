// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {IV2SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV2SwapRouter.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {IMulticallExtended} from "@uniswap/swap-router-contracts/contracts/interfaces/IMulticallExtended.sol";
import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";

interface ISwapRouter02 is IV2SwapRouter, IV3SwapRouter, IMulticallExtended {
}

/// replace 
contract DragonswapProcessor is ICalldataProcessor {

    function processCalldata(uint256 amount, bytes calldata data) external pure returns (bytes memory processedCalldata) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == IV3SwapRouter.exactOutputSingle.selector) {
            (ISwapRouter02.ExactOutputSingleParams memory params) = abi.decode(data[4:], (IV3SwapRouter.ExactOutputSingleParams));
            params.amountOut = amount;
            return abi.encodeCall(IV3SwapRouter.exactOutputSingle, (params));
        }
        else if (selector == IV3SwapRouter.exactOutput.selector) {
            (IV3SwapRouter.ExactOutputParams memory params) = abi.decode(data[4:], (IV3SwapRouter.ExactOutputParams));
            params.amountOut = amount;
            return abi.encodeCall(IV3SwapRouter.exactOutput, (params));
        }
        else if (selector == IV2SwapRouter.swapTokensForExactTokens.selector) {
            (uint256 amountOut, uint256 amountInMax, address[] memory path, address to) = abi.decode(data[4:], (uint256, uint256, address[], address));
            amountOut = amount;
            return abi.encodeCall(IV2SwapRouter.swapTokensForExactTokens, (amountOut, amountInMax, path, to));
        }
        else {
            revert InvalidCalldata();
        }
    }
}
