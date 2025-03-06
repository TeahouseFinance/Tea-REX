// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IAggregatorHelper} from "../interfaces/trading/IAggregatorHelper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Swap helper contract for aggregators to support swapExactOutput
/// @notice This contract calls an aggregator for a normal swap input call, and a second call to a
/// @notice normal swap contract with the remaining tokens to swap the extra dst tokens back to src token,
/// @notice thus making sure that the amount of dst tokens is exactly the same as specified.
contract AggregatorHelper is IAggregatorHelper, Ownable {
    using SafeERC20 for ERC20PermitUpgradeable;

    error LengthMismatch();
    error NotWhitelisted();
    error OutputScrapNotCleared();
    error IncorrectScrapAmountSize();
    error IncorrectScrapAmountOffset();

    event SetWhitelist(address sender, address[] router, bool[] isWhitelisted);    

    bool public checkWhitelist;
    mapping(address => bool) public routerWhitelist;    
    
    constructor(address initialOwner) Ownable(initialOwner) {
        checkWhitelist = true;
    }

    function setWhitelist(address[] calldata _router, bool[] calldata _isWhitelisted) external onlyOwner {
        if (_router.length != _isWhitelisted.length) revert LengthMismatch();

        for (uint256 i; i < _router.length; ) {
            routerWhitelist[_router[i]] = _isWhitelisted[i];

            unchecked { ++i; }
        }

        emit SetWhitelist(msg.sender, _router, _isWhitelisted);
    }

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
    ) external {
        if (checkWhitelist && !(routerWhitelist[_aggregator] && routerWhitelist[_scrapRouter])) revert NotWhitelisted();

        ERC20PermitUpgradeable src = ERC20PermitUpgradeable(_src);
        ERC20PermitUpgradeable dst = ERC20PermitUpgradeable(_dst);
        src.safeTransferFrom(msg.sender, address(this), _amountIn);
        src.approve(_aggregator, _amountIn);
        (bool success, bytes memory returndata) = _aggregator.call(_aggregatorCalldata);
        uint256 length = returndata.length;
        if (!success) {
            // call failed, propagate revert data
            assembly ("memory-safe") {
                revert(add(returndata, 32), length)
            }
        }

        src.approve(_aggregator, 0);

        uint256 balanceOut = dst.balanceOf(address(this));
        if (balanceOut > _amountOut) {
            _scrapSwap(dst, balanceOut - _amountOut, _scrapRouter, _scrapCalldata, _scrapAmountOffset);
        }

        balanceOut = dst.balanceOf(address(this));
        if (balanceOut != 0) {
            revert OutputScrapNotCleared();
        }

         // send tokens back to caller
        src.safeTransfer(msg.sender, src.balanceOf(address(this)));
        dst.safeTransfer(msg.sender, dst.balanceOf(address(this)));        
    }

    function _scrapSwap(
        ERC20PermitUpgradeable _dst,
        uint256 _amountIn,
        address _scrapRouter,
        bytes calldata _scrapCalldata,
        uint256 _scrapAmountOffset
    ) internal {
        if (_scrapAmountOffset + 32 > _scrapCalldata.length) {
            revert IncorrectScrapAmountOffset();
        }

        // adjust call data
        bytes memory _adjustedCalldata = _adjustCalldata(_scrapCalldata, _amountIn, _scrapAmountOffset);

        _dst.approve(_scrapRouter, _amountIn);
        (bool success, bytes memory returndata) = _scrapRouter.call(_adjustedCalldata);
        uint256 length = returndata.length;
        if (!success) {
            // call failed, propagate revert data
            assembly ("memory-safe") {
                revert(add(returndata, 32), length)
            }
        }

        _dst.approve(_scrapRouter, 0);
    }

    function _adjustCalldata(
        bytes calldata _calldata,
        uint256 _amount,
        uint256 _amountOffset
    ) internal pure returns (bytes memory) {
        uint256 dataLength = _calldata.length;

        // check for offset
        if (_amountOffset + 32 > dataLength) {
             revert IncorrectScrapAmountOffset();
        }
        if (_amountOffset % 32 != 4){
             revert IncorrectScrapAmountOffset();
        }

        // create a copy of the calldata
        bytes memory newCalldata = new bytes(dataLength);

        assembly {
            let newCalldataPtr := add(newCalldata, 32)

            // store data length
            mstore(newCalldata, dataLength)

            // copy _amountOffset bytes
            calldatacopy(newCalldataPtr, _calldata.offset, _amountOffset)

            // store the uint256 amount at the offset
            mstore(add(newCalldataPtr, _amountOffset), _amount)

            // copy remaining bytes
            let newOffset := add(_amountOffset, 32)
            calldatacopy(add(newCalldataPtr, newOffset), add(_calldata.offset, newOffset), sub(dataLength, newOffset))
        }

        return newCalldata;
    }
}
