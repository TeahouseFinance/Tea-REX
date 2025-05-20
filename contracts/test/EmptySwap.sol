// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Dump very small amount of assets for closing positions with very little assets
contract EmptySwap is Ownable {

    using SafeERC20 for IERC20;

    error InvalidReceiver();
    error InvalidInAmount();

    event TokenRetrieved(address indexed sender, address indexed token, address indexed receiver, uint256 amount);

    uint256 maxInAmount;

    constructor(address _owner, uint256 _maxInAmount) Ownable(_owner) {
        maxInAmount = _maxInAmount;
    }

    function changeMaxInAmount(uint256 _newMaxInAmount) external onlyOwner {
        maxInAmount = _newMaxInAmount;
    }

    /// Retrieve ERC20 token in the contract
    /// @param _token address of the ERC20 token
    /// @param _receiver receving address
    /// @param _amount amount of tokens to retrieve
    /// @notice only owner can call this function
    function retrieveToken(address _token, address _receiver, uint256 _amount) external onlyOwner {
        require(_receiver != address(0), InvalidReceiver());

        emit TokenRetrieved(msg.sender, _token, _receiver, _amount);
        IERC20(_token).safeTransfer(_receiver, _amount);
    }

    /// Dump input tokens to output tokens input amount
    /// @param _inToken input ERC20 token
    /// @param _inAmount amount of input tokens
    function dump(
        address _inToken,
        uint256 _inAmount
    ) external {
        require(_inAmount <= maxInAmount, InvalidInAmount());

        IERC20(_inToken).safeTransferFrom(msg.sender, address(this), _inAmount);
    }
}
