// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";

interface IDragonswapRouter {

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

/// replace 
contract DragonswapProcessor is ICalldataProcessor {

    error InvalidCalldata();

    function processCalldata(uint256 amount, bytes calldata data) external pure returns (bytes memory processedCalldata) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == IDragonswapRouter.swapTokensForExactTokens.selector) {
            (, uint amountInMax, address[] memory path, address to, uint deadline) = abi.decode(data[4:], (uint, uint, address[], address, uint));
            return abi.encodeCall(IDragonswapRouter.swapTokensForExactTokens, (amount, amountInMax, path, to, deadline));
        }
        else {
            revert InvalidCalldata();
        }
    }

}
