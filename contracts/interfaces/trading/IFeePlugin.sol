// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ITradingCore} from "./ITradingCore.sol";

interface IFeePlugin {

    function getFeeForAccount(address _account, ITradingCore.FeeConfig memory _baseFeeConfig) external view returns (ITradingCore.FeeConfig memory);

}