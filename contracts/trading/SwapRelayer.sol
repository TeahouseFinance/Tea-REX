// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRelayer} from "../interfaces/trading/ISwapRelayer.sol";

/// @notice SwapRelayer is a helper contract for sending calls to arbitray swap router
/// @notice Since there's no need to approve tokens to SwapRelayer, it's safe for Swapper
/// @notice to call arbitrary contracts.
contract SwapRelayer is ISwapRelayer, Ownable {
    using SafeERC20 for ERC20PermitUpgradeable;

    bool public checkWhitelist;
    address public tradingCore;
    mapping(address => bool) public routerWhitelist;
    mapping(address => bool) public verifierWhitelist;

    receive() external payable {}

    constructor(address _initialOwner) Ownable(_initialOwner) {
        checkWhitelist = true;
    }
    
    /// @inheritdoc ISwapRelayer
    function setTradingCore(address _tradingCore) external override onlyOwner {
        tradingCore = _tradingCore;
    }

    /// @inheritdoc ISwapRelayer
    function setCheckWhitelist(bool _checkWhitelist) external override onlyOwner {
        checkWhitelist = _checkWhitelist;
    }

    /// @inheritdoc ISwapRelayer
    function setRouterWhitelist(address[] calldata _routers, bool[] calldata _isWhitelisted) external override onlyOwner {
        if (_routers.length != _isWhitelisted.length) revert LengthMismatch();

        for (uint256 i; i < _routers.length; ) {
            routerWhitelist[_routers[i]] = _isWhitelisted[i];

            unchecked { ++i; }
        }

        emit SetRouterWhitelist(msg.sender, _routers, _isWhitelisted);
    }

    /// @inheritdoc ISwapRelayer
    function setVerifierWhitelist(address[] calldata _verifiers, bool[] calldata _isWhitelisted) external override onlyOwner {
        if (_verifiers.length != _isWhitelisted.length) revert LengthMismatch();

        for (uint256 i; i < _verifiers.length; ) {
            verifierWhitelist[_verifiers[i]] = _isWhitelisted[i];

            unchecked { ++i; }
        }

        emit SetVerifierWhitelist(msg.sender, _verifiers, _isWhitelisted);
    }

    /// @inheritdoc ISwapRelayer
    function swap(
        ERC20PermitUpgradeable _src,
        ERC20PermitUpgradeable _dst,
        uint256 _amountIn,
        address _swapRouter,
        bytes calldata _data
    ) external override {
        if (msg.sender != tradingCore) revert NotTradingCore();
        if (checkWhitelist && !routerWhitelist[_swapRouter]) revert NotWhitelisted();

        _src.approve(_swapRouter, _amountIn);
        (bool success, bytes memory returndata) = _swapRouter.call(_data);
        uint256 length = returndata.length;
        if (!success) {
            // call failed, propagate revert data
            assembly ("memory-safe") {
                revert(add(returndata, 32), length)
            }
        }

        _src.approve(_swapRouter, 0);
 
         // send tokens back to caller
        _src.safeTransfer(msg.sender, _src.balanceOf(address(this)));
        _dst.safeTransfer(msg.sender, _dst.balanceOf(address(this)));
    }

    /// @inheritdoc ISwapRelayer
    function verify(address _verifier, bytes calldata _data) external override {
        if (msg.sender != tradingCore) revert NotTradingCore();
        if (checkWhitelist && !verifierWhitelist[_verifier]) revert NotWhitelisted();

        (bool success, bytes memory returndata) = _verifier.call(_data);
        uint256 length = returndata.length;
        if (!success) {
            // call failed, propagate revert data
            assembly ("memory-safe") {
                revert(add(returndata, 32), length)
            }
        }
    }
}
