// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface ISwapRelayer {

    error LengthMismatch();
    error NotWhitelisted();

    event SetWhitelist(address sender, address[] router, bool[] isWhitelisted);

    receive() external payable;

    function setCheckWhitelist(bool _checkWhitelist) external;
    function setWhitelist(address[] calldata _router, bool[] calldata _isWhitelisted) external;

    function swap(
        ERC20Upgradeable _srcToken,
        ERC20Upgradeable _dstToken,
        uint256 _amountIn,
        address _swapRouter,
        bytes calldata _data
    ) external;

}