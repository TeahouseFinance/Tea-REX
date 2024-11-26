// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface ISwapRelayer {

    error LengthMismatch();
    error NotWhitelisted();

    event SetWhitelist(address sender, address[] router, bool[] isWhitelisted);

    receive() external payable;

    /// @notice Switch of router whitelist check
    /// @notice Only owner can call this function
    /// @param checkWhitelist Whether the whitelist mechanism is enabled
    function setCheckWhitelist(bool checkWhitelist) external;

    /// @notice Set up router whitelist
    /// @notice Only owner can call this function
    /// @param router Addresses of routers
    /// @param isWhitelisted Setting for routers
    function setWhitelist(address[] calldata router, bool[] calldata isWhitelisted) external;

    /// @notice Swap for caller
    /// @dev Source token should be transferred the swap relayer in advance
    /// @param srcToken Source token of the swap
    /// @param dstToken Destination token of the swap
    /// @param amountIn Amount of source token to swap
    /// @param swapRouter Swap router to be used
    /// @param data Calldata for the assigned swap router
    function swap(
        ERC20Upgradeable srcToken,
        ERC20Upgradeable dstToken,
        uint256 amountIn,
        address swapRouter,
        bytes calldata data
    ) external;

}