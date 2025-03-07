// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

/// @title Swap helper contract for aggregators to support swapExactOutput
/// @notice This contract calls an aggregator for a normal swap input call, and a second call to a
/// @notice normal swap contract with the remaining tokens to swap the extra (scrap) dst tokens back
/// @notice to src token, thus making sure that the amount of dst tokens is exactly the same as specified.
/// @notice This contract replaces the "amountIn" parameter in scrapCalldata to make sure only the extra
/// @notice amount of destination tokens are swapped back.
interface IAggregatorHelper {

    /// @notice Function to simulate an exact output swap
    /// @param _src source token
    /// @param _dst destination token
    /// @param _amountIn maximum amount of source tokens to swap
    /// @param _amountOut expected amount of destination tokens
    /// @param _aggregator address of the aggregator
    /// @param _aggregatorCalldata calldata for the aggregator
    /// @param _scrapRouter swap contract for extra (scrap) destination tokens
    /// @param _scrapCalldata calldata for swapping extra destination tokens
    /// @param _scrapAmountOffset offset (in bytes) for the "amountIn" parameter in _scrapCalldata
    function swapExactOutput(
        address _src,
        address _dst,
        uint256 _amountIn,
        uint256 _amountOut,
        address _aggregator,
        bytes calldata _aggregatorCalldata,
        address _scrapRouter,
        bytes calldata _scrapCalldata,
        uint256 _scrapAmountOffset
    ) external;

}
