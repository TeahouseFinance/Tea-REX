// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {ISwapRouter} from '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";

/// replace 
contract UniswapV3Processor is ICalldataProcessor {

    error InvalidCalldata();

    function processCalldata(uint256 amount, bytes calldata data) external pure returns (bytes memory processedCalldata) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == ISwapRouter.exactOutputSingle.selector) {
            (ISwapRouter.ExactOutputSingleParams memory params) = abi.decode(data[4:], (ISwapRouter.ExactOutputSingleParams));
            params.amountOut = amount;
            return abi.encodeWithSelector(selector, (params));
        }
        else if (selector == ISwapRouter.exactOutput.selector) {
            (ISwapRouter.ExactOutputParams memory params) = abi.decode(data[4:], (ISwapRouter.ExactOutputParams));
            params.amountOut = amount;
            return abi.encodeWithSelector(selector, (params));
        }
        else {
            revert InvalidCalldata();
        }
    }

}
