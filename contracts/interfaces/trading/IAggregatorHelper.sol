// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title Interface for AggregatorHelper
/// @notice Helper contract to provide an emulated "exact output" swap function to be used with an aggregator.
interface IAggregatorHelper {

    function swapExactOutput(
        ERC20PermitUpgradeable _src,
        ERC20PermitUpgradeable _dst,
        uint256 _amountIn,
        uint256 _amountOut,
        address _aggregator,
        bytes calldata _aggregatorCalldata,
        address _scrapRouter,
        bytes calldata _scrapCalldata,
        uint256 _scrapAmountOffset
    ) external;

}
