// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

interface ICalldataProcessor {
    
    /// @notice Modify the exact output amount of the given calldata
    /// @param amount Expect exact output amount
    /// @param data Original calldata
    /// @return processedCalldata Modified calldata
    function processCalldata(uint256 amount, bytes calldata data) external view returns (bytes memory processedCalldata);

}