// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";

interface ITeaRouter {
    struct Path {
        address pool;       // pool address
        address toToken;    // address of target token, use address(0) for native token
        bytes extraData;    // depends on adapter, use adapter's encodeExtraData function
    }

    function swapExactOutput(IERC20 _fromToken, uint256 _amountOut, uint256 _amountInMax, address payable _recipient, Path calldata _path) external payable returns (uint256 amount);
}

/// replace 
contract TeaRouterProcessor is ICalldataProcessor {

    function processCalldata(uint256 amount, bytes calldata data) external pure returns (bytes memory processedCalldata) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == ITeaRouter.swapExactOutput.selector) {
            (
                IERC20 fromToken,
                uint256 amountOut,
                uint256 amountInMax,
                address payable recipient,
                ITeaRouter.Path memory path
            ) = abi.decode(data[4:], (IERC20, uint256, uint256, address, ITeaRouter.Path));
            amountOut = amount;
            return abi.encodeCall(ITeaRouter.swapExactOutput, (fromToken, amountOut, amountInMax, recipient, path));
        }
        else {
            revert InvalidCalldata();
        }
    }
}
