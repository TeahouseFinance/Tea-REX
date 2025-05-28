// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IAggregatorHelper} from "../interfaces/trading/IAggregatorHelper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Swap helper contract for aggregators to support price oralces with pull mode, swapExactInput, and swapExactOutput
/// @notice This contract calls an aggregator for a normal swap input call, and a second call to a
/// @notice normal swap contract with the remaining tokens to swap the extra dst tokens back to src token,
/// @notice thus making sure that the amount of dst tokens is exactly the same as specified.
contract AggregatorHelper is IAggregatorHelper, Ownable {
    using Address for address;
    using SafeERC20 for ERC20PermitUpgradeable;

    bool public checkWhitelist;
    mapping(address => bool) public routerWhitelist;
    mapping(address => bool) public verifierWhitelist;
    mapping(address => bool) public callerWhitelist;
    uint256 public maxScraps;
    
    constructor(address initialOwner) Ownable(initialOwner) {
        checkWhitelist = true;
    }

    function setCheckWhitelist(bool _checkWhitelist) external onlyOwner {
        checkWhitelist = _checkWhitelist;

        emit SetCheckWhitelist(msg.sender, _checkWhitelist);
    }

    function setRouterWhitelist(address[] calldata _router, bool[] calldata _isWhitelisted) external onlyOwner {
        if (_router.length != _isWhitelisted.length) revert LengthMismatch();

        for (uint256 i; i < _router.length; ) {
            routerWhitelist[_router[i]] = _isWhitelisted[i];

            unchecked { ++i; }
        }

        emit SetRouterWhitelist(msg.sender, _router, _isWhitelisted);
    }

    function setVerifierWhitelist(address[] calldata _verifier, bool[] calldata _isWhitelisted) external onlyOwner {
        if (_verifier.length != _isWhitelisted.length) revert LengthMismatch();

        for (uint256 i; i < _verifier.length; ) {
            verifierWhitelist[_verifier[i]] = _isWhitelisted[i];

            unchecked { ++i; }
        }

        emit SetVerifierWhitelist(msg.sender, _verifier, _isWhitelisted);
    }

    function setCallerWhitelist(address[] calldata _caller, bool[] calldata _isWhitelisted) external onlyOwner {
        if (_caller.length != _isWhitelisted.length) revert LengthMismatch();

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
        Address.sendValue(payable(msg.sender), _amount);
    }

    function swapExactInput(
        address _src,
        address _dst,
        uint256 _amountIn,
        address _verifier,
        bytes calldata _verifierCalldata,
        address _router,
        bytes calldata _routerCalldata
    ) external {
        if (checkWhitelist) {
            require(callerWhitelist[msg.sender], NotWhitelisted());
            require(_verifier == address(0) || verifierWhitelist[_verifier], NotWhitelisted());
            require(routerWhitelist[_router], NotWhitelisted());
        }

        // call verifier if required, for oracles with pull model
        if (_verifier != address(0)) {
            _verifier.functionCall(_verifierCalldata);
        }   

        // call aggregator to swap tokens
        ERC20PermitUpgradeable src = ERC20PermitUpgradeable(_src);
        ERC20PermitUpgradeable dst = ERC20PermitUpgradeable(_dst);
        src.safeTransferFrom(msg.sender, address(this), _amountIn);
        src.approve(_router, _amountIn);
        _router.functionCall(_routerCalldata);
        src.approve(_router, 0);

        uint256 balanceSrc = src.balanceOf(address(this));
        uint256 balanceDst = dst.balanceOf(address(this));

        // send tokens back to caller
        if (balanceSrc >= maxScraps) {
            revert InputAmountNotCleared();
        }

        if (balanceDst != 0) {
            dst.safeTransfer(msg.sender, balanceDst);
        }
    }

    function swapExactOutput(
        address _src,
        address _dst,
        uint256 _amountIn,
        uint256 _amountOut,
        address _verifier,
        bytes calldata _verifierCalldata,
        address _router,
        bytes calldata _routerCalldata,
        address _scrapRouter,
        bytes calldata _scrapCalldata,
        uint256 _scrapAmountOffset
    ) external {
        if (checkWhitelist) {
            require(callerWhitelist[msg.sender], NotWhitelisted());
            require(_verifier == address(0) || verifierWhitelist[_verifier], NotWhitelisted());
            require(routerWhitelist[_router] && routerWhitelist[_scrapRouter], NotWhitelisted());
        }

        // call verifier if required, for oracles with pull model
        if (_verifier != address(0)) {
            _verifier.functionCall(_verifierCalldata);
        }   

        // call aggregator to swap tokens
        ERC20PermitUpgradeable src = ERC20PermitUpgradeable(_src);
        ERC20PermitUpgradeable dst = ERC20PermitUpgradeable(_dst);
        src.safeTransferFrom(msg.sender, address(this), _amountIn);
        src.approve(_router, _amountIn);
        _router.functionCall(_routerCalldata);
        src.approve(_router, 0);

        uint256 balanceOut = dst.balanceOf(address(this));
        if (balanceOut == 0) {
            revert NoTokenReceived();
        }

        if (balanceOut > _amountOut) {
            _scrapSwap(dst, balanceOut - _amountOut, _scrapRouter, _scrapCalldata, _scrapAmountOffset);
        }

        balanceOut = dst.balanceOf(address(this));
        if (balanceOut != _amountOut) {
            revert OutputScrapNotCleared();
        }

        uint256 balanceSrc = src.balanceOf(address(this));
        if (balanceSrc == 0) {
            revert NoTokenReceived();
        }

         // send tokens back to caller
        src.safeTransfer(msg.sender, balanceSrc);
        dst.safeTransfer(msg.sender, balanceOut);
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
        _scrapRouter.functionCall(_adjustedCalldata);
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
