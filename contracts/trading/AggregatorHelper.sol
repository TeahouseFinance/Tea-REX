// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAggregatorHelper} from "../interfaces/trading/IAggregatorHelper.sol";
import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";

/// @title Swap helper contract for aggregators to support price oralces with pull mode, swapExactInput, and swapExactOutput
/// @notice This contract calls an aggregator for a normal swap input call, and a second call to a
/// @notice normal swap contract with the remaining tokens to swap the extra dst tokens back to src token,
/// @notice thus making sure that the amount of dst tokens is exactly the same as specified.
contract AggregatorHelper is IAggregatorHelper, Ownable {
    using SafeERC20 for ERC20PermitUpgradeable;

    bool public checkWhitelist;
    mapping(address => bool) public routerWhitelist;
    mapping(address => bool) public callerWhitelist;
    mapping(address => uint256) public minAmount;
    uint256 public maxScraps;
    
    constructor(address initialOwner) Ownable(initialOwner) {
        checkWhitelist = true;
    }

    function setCheckWhitelist(bool _checkWhitelist) external onlyOwner {
        checkWhitelist = _checkWhitelist;

        emit SetCheckWhitelist(msg.sender, _checkWhitelist);
    }

    function setMinAmount(address _token, uint256 _minAmount) external onlyOwner {
        minAmount[_token] = _minAmount;

        emit SetMinAmount(msg.sender, _token, _minAmount);
    }

    function setRouterWhitelist(address[] calldata _router, bool[] calldata _isWhitelisted) external onlyOwner {
        require(_router.length == _isWhitelisted.length, LengthMismatch());

        for (uint256 i; i < _router.length; ) {
            routerWhitelist[_router[i]] = _isWhitelisted[i];

            unchecked { ++i; }
        }

        emit SetRouterWhitelist(msg.sender, _router, _isWhitelisted);
    }

    function setCallerWhitelist(address[] calldata _caller, bool[] calldata _isWhitelisted) external onlyOwner {
        require(_caller.length == _isWhitelisted.length, LengthMismatch());

        for (uint256 i; i < _caller.length; ) {
            callerWhitelist[_caller[i]] = _isWhitelisted[i];

            unchecked { ++i; }
        }

        emit SetCallerWhitelist(msg.sender, _caller, _isWhitelisted);
    }

    function setMaxScraps(uint256 _maxScraps) external onlyOwner {
        maxScraps = _maxScraps;

        emit SetMaxScraps(msg.sender, _maxScraps);
    }

    function retrieveTokens(address _token, uint256 _amount) external onlyOwner {
        ERC20PermitUpgradeable token = ERC20PermitUpgradeable(_token);
        token.safeTransfer(msg.sender, _amount);
    }

    function retrieveNativeToken(uint256 _amount) external onlyOwner {
        payable(msg.sender).transfer(_amount);
    }

    function swapExactInput(
        address _src,
        address _dst,
        uint256 _amountIn,
        address _router,
        bytes calldata _routerCalldata
    ) external returns (uint256 amountOut) {
        if (checkWhitelist) {
            require(callerWhitelist[msg.sender], NotWhitelisted());
            require(_verifier == address(0) || verifierWhitelist[_verifier], NotWhitelisted());
            require(routerWhitelist[_router], NotWhitelisted());
        }

        require(_amountIn >= minAmount[_src], AmountInTooSmall());

        // call aggregator to swap tokens
        ERC20PermitUpgradeable src = ERC20PermitUpgradeable(_src);
        ERC20PermitUpgradeable dst = ERC20PermitUpgradeable(_dst);
        src.safeTransferFrom(msg.sender, address(this), _amountIn);
        src.approve(_router, _amountIn);
        _safeCall(_router, _routerCalldata);
        src.approve(_router, 0);

        uint256 balanceSrc = src.balanceOf(address(this));
        uint256 balanceDst = dst.balanceOf(address(this));

        // send tokens back to caller
        require(balanceSrc <= maxScraps, InputAmountNotCleared());

        if (balanceDst != 0) {
            dst.safeTransfer(msg.sender, balanceDst);
        }

        return balanceDst;
    }

    function swapExactOutput(
        address _src,
        address _dst,
        uint256 _amountIn,
        uint256 _amountOut,
        address _router,
        bytes calldata _routerCalldata,
        address _calldataProcessor,
        address _scrapRouter,
        bytes calldata _scrapCalldata,
        uint256 _scrapAmountOffset
    ) external returns (uint256 amountIn) {
        if (checkWhitelist) {
            require(callerWhitelist[msg.sender], NotWhitelisted());
            require(_verifier == address(0) || verifierWhitelist[_verifier], NotWhitelisted());
            require(routerWhitelist[_router] && routerWhitelist[_scrapRouter], NotWhitelisted());
        }

        require(_amountOut >= minAmount[_dst], AmountOutTooSmall());

        // call aggregator to swap tokens
        ERC20PermitUpgradeable src = ERC20PermitUpgradeable(_src);
        ERC20PermitUpgradeable dst = ERC20PermitUpgradeable(_dst);
        src.safeTransferFrom(msg.sender, address(this), _amountIn);
        src.approve(_router, _amountIn);
        // if there's a calldataProcessor, process the calldata
        if (address(_calldataProcessor) != address(0)) {
            bytes memory _data = ICalldataProcessor(_calldataProcessor).processCalldata(_amountOut, _routerCalldata);
            _safeCallMemory(_router, _data);
        }
        else {
            _safeCall(_router, _routerCalldata);
        }
        src.approve(_router, 0);

        uint256 balanceOut = dst.balanceOf(address(this));
        require(balanceOut > 0, NoTokenReceived());
        require(balanceOut >= _amountOut, NotEnoughAmountOut());

        if (balanceOut > _amountOut) {
            _scrapSwap(dst, balanceOut - _amountOut, _scrapRouter, _scrapCalldata, _scrapAmountOffset);

            balanceOut = dst.balanceOf(address(this));
            require(balanceOut == _amountOut, OutputScrapNotCleared());
        }

        // send tokens back to caller
        dst.safeTransfer(msg.sender, balanceOut);            

        uint256 balanceSrc = src.balanceOf(address(this));
        if (balanceSrc != 0) {
            src.safeTransfer(msg.sender, balanceSrc);
        }

        return _amountIn - balanceSrc;
    }

    function _scrapSwap(
        ERC20PermitUpgradeable _dst,
        uint256 _amountIn,
        address _scrapRouter,
        bytes calldata _scrapCalldata,
        uint256 _scrapAmountOffset
    ) internal {
        // adjust call data
        bytes memory _adjustedCalldata = _adjustCalldata(_scrapCalldata, _amountIn, _scrapAmountOffset);

        _dst.approve(_scrapRouter, _amountIn);
        _safeCallMemory(_scrapRouter, _adjustedCalldata);
        _dst.approve(_scrapRouter, 0);
    }

    function _adjustCalldata(
        bytes calldata _calldata,
        uint256 _amount,
        uint256 _amountOffset
    ) internal pure returns (bytes memory) {
        uint256 dataLength = _calldata.length;

        // check for offset
        require(_amountOffset + 32 <= dataLength, IncorrectScrapAmountOffset());

        // create a copy of the calldata
        bytes memory newCalldata = new bytes(dataLength);

        assembly ("memory-safe") {
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

    function _safeCall(address _contract, bytes calldata _calldata) internal {
        (bool success, bytes memory returndata) = _contract.call(_calldata);
        uint256 length = returndata.length;
        if (!success) {
            // call failed, propagate revert data
            assembly ("memory-safe") {
                revert(add(returndata, 32), length)
            }
        }
    }

    function _safeCallMemory(address _contract, bytes memory _calldata) internal {
        (bool success, bytes memory returndata) = _contract.call(_calldata);
        uint256 length = returndata.length;
        if (!success) {
            // call failed, propagate revert data
            assembly ("memory-safe") {
                revert(add(returndata, 32), length)
            }
        }        
    }
}
