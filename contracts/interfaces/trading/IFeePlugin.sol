// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ITradingCore} from "./ITradingCore.sol";

interface IFeePlugin {

    /// @notice Get fee config for the account
    /// @param account Query account
    /// @param baseFeeConfig Base fee config
    /// @return accountFeeConfig Fee config for the account
    function getFeeForAccount(address account, ITradingCore.FeeConfig memory baseFeeConfig) external view returns (ITradingCore.FeeConfig memory);

}