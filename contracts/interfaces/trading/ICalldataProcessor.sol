// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

interface ICalldataProcessor {
    
    function processCalldata(uint256 amount, bytes memory data) external view returns (bytes memory processedCalldata);

}