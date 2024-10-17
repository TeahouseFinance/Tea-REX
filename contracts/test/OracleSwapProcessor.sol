// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {OracleSwap} from './OracleSwap.sol';
import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";

/// replace 
contract OracleSwapProcessor is ICalldataProcessor {

    error InvalidCalldata();

    function processCalldata(uint256 amount, bytes calldata data) external pure returns (bytes memory processedCalldata) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == OracleSwap.swapExactOutput.selector) {
            (address inToken, address outToken,, address receiver, uint256 maxInAmount) = abi.decode(data[4:], (address, address, uint256, address, uint256));
            return abi.encodeWithSelector(selector, inToken, outToken, amount, receiver, maxInAmount);
        }
        else {
            revert InvalidCalldata();
        }
    }
}
