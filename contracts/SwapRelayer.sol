// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice SwapRelayer is a helper contract for sending calls to arbitray swap router
/// @notice Since there's no need to approve tokens to SwapRelayer, it's safe for Swapper
/// @notice to call arbitrary contracts.
contract SwapRelayer {
    using SafeERC20 for ERC20Upgradeable;

    function swap(
        ERC20Upgradeable _srcToken,
        ERC20Upgradeable _dstToken,
        uint256 _amountIn,
        address _swapRouter,
        bytes calldata _data
    ) external {
        _srcToken.approve(_swapRouter, _amountIn);
        (bool success, bytes memory returndata) = _swapRouter.call(_data);
        uint256 length = returndata.length;
        if (!success) {
            // call failed, propagate revert data
            assembly ("memory-safe") {
                revert(add(returndata, 32), length)
            }
        }
        _srcToken.approve(_swapRouter, 0);

        // send tokens back to caller
        uint256 balance = _srcToken.balanceOf(address(this));
        if (balance > 0) {
            _srcToken.safeTransfer(msg.sender, balance);
        }

        balance = _dstToken.balanceOf(address(this));
        if (balance > 0) {
            _dstToken.safeTransfer(msg.sender, balance);
        }
    }
}