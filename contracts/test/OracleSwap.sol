// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";

/// Allow users to swap tokens using ChainLink price data feeds for token price 
contract OracleSwap is Ownable {

    using SafeERC20 for IERC20;

    error InvalidPriceSpread();
    error InvalidTokenAddress();
    error InvalidReceiver();
    error UnsupportedToken();
    error NoOutAmount();
    error InsufficientOutput(uint256 outAmount, uint256 minOutAmount);
    error NoInAmount();
    error ExceedingInput(uint256 inAmount, uint256 maxInAmount);

    event PriceSpreadChanged(address indexed sender, uint256 oldPriceSpread, uint256 newPriceSpread);
    event TokenRetrieved(address indexed sender, address indexed token, address indexed receiver, uint256 amount);
    event TokenChanged(address indexed sender, address indexed token, address priceOracle);
    event Swap(address indexed sender, address indexed inToken, address indexed outToken, address receiver, uint256 inAmount, uint256 outAmount);

    struct TokenInfo {
        uint8 decimals;
        IAssetOracle priceOracle;
        uint8 priceDecimals;
        uint8 totalDecimals;
    }

    uint256 public priceSpread; // price spread for trading, in 0.0001%
    mapping(address => TokenInfo) public tokenInfo; // tokenInfo from token address

    constructor(address _owner, uint256 _priceSpread) Ownable(_owner) {
        _setPriceSpread(_priceSpread);
    }

    /// Set price spread
    /// @param _newPriceSpread new price spread, in 0.0001% (e.g. 1000 means 0.1%)
    /// @notice only owner can call this function
    function setPriceSpread(uint256 _newPriceSpread) external onlyOwner {
        _setPriceSpread(_newPriceSpread);
    }

    function _setPriceSpread(uint256 _newPriceSpread) internal {
        require(_newPriceSpread < 1000000, InvalidPriceSpread());

        emit PriceSpreadChanged(msg.sender, priceSpread, _newPriceSpread);
        priceSpread = _newPriceSpread;
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

    /// Allow a token to be swapped
    /// @param _token address of the ERC20 token
    /// @param _priceOracle address of the price oracle (must be in USD, e.g. oracles for ETH/USD or USDC/USD)
    /// @notice only owner can call this function
    function setToken(address _token, IAssetOracle _priceOracle) external onlyOwner {
        require(_token != address(0), InvalidTokenAddress());

        TokenInfo storage info = tokenInfo[_token];
        info.decimals = IERC20Metadata(_token).decimals();  // token is assumed to have decimals() function
        info.priceOracle = _priceOracle;
        info.priceDecimals = _priceOracle.decimals();

        // test if it's possible to get price data
        _priceOracle.getPrice(_token);

        emit TokenChanged(msg.sender, _token, address(_priceOracle));
    }    

    /// Disallow a token to be swapped
    /// @param _token address of the ERC20 token
    /// @notice only owner can call this function
    function removeToken(address _token) external onlyOwner {
        require(_token != address(0), InvalidTokenAddress());

        delete tokenInfo[_token];
        emit TokenChanged(msg.sender, _token, address(0));
    }

    /// See if a token is supported
    /// @param _token address of the ERC20 token
    /// @return supported true if supported, false if not
    function tokenSupported(address _token) external view returns (bool supported) {
        return address(tokenInfo[_token].priceOracle) != address(0);
    }

    /// Get current token price
    /// @param _token address of the ERC20 token
    /// @return price current price
    /// @return decimals decimals of current price
    function currentTokenPrice(address _token) external view returns (uint256 price, uint8 decimals) {
        TokenInfo storage info = tokenInfo[_token];
        require(address(info.priceOracle) != address(0), UnsupportedToken());

        price = info.priceOracle.getPrice(_token);
        decimals = info.priceDecimals;
    }

    /// Calculate the estimated output amount based on current price
    /// @param _inToken input ERC20 token
    /// @param _outToken output ERC20 token
    /// @param _inAmount amount of input tokens
    /// @return outAmount estimated amount of output tokens
    function calculateOutAmount(
        address _inToken,
        address _outToken,
        uint256 _inAmount
    ) public view returns (uint256 outAmount) {
        TokenInfo storage inTokenInfo = tokenInfo[_inToken];
        TokenInfo storage outTokenInfo = tokenInfo[_outToken];

        require(address(inTokenInfo.priceOracle) != address(0), UnsupportedToken());
        require(address(outTokenInfo.priceOracle) != address(0), UnsupportedToken());

        uint256 inTokenPrice = inTokenInfo.priceOracle.getPrice(_inToken);
        uint256 outTokenPrice = outTokenInfo.priceOracle.getPrice(_outToken);

        uint256 mulDecimals = outTokenInfo.priceDecimals;
        uint256 divDecimals = inTokenInfo.priceDecimals;
        if (mulDecimals > divDecimals) {
            outAmount = Math.mulDiv(_inAmount, (10 ** (mulDecimals - divDecimals)) * inTokenPrice, outTokenPrice);
        }
        else {
            outAmount = Math.mulDiv(_inAmount, inTokenPrice, (10 ** (divDecimals - mulDecimals)) * outTokenPrice);
        }

        outAmount -= outAmount * priceSpread / 1000000;
    }

    /// Swap input tokens to output tokens with exact input amount
    /// @param _inToken input ERC20 token
    /// @param _outToken output ERC20 token
    /// @param _inAmount amount of input tokens
    /// @param _receiver receiving address
    /// @param _minOutAmount minimum output amount, revert if outAmount is less
    /// @return outAmount amount of output tokens received
    function swapExactInput(
        address _inToken,
        address _outToken,
        uint256 _inAmount,
        address _receiver,
        uint256 _minOutAmount
    ) external returns (uint256 outAmount) {
        require(_receiver != address(0), InvalidReceiver());

        outAmount = calculateOutAmount(_inToken, _outToken, _inAmount);

        require(outAmount > 0, NoOutAmount());
        require(outAmount >= _minOutAmount, InsufficientOutput(outAmount, _minOutAmount));

        IERC20(_inToken).safeTransferFrom(msg.sender, address(this), _inAmount);
        IERC20(_outToken).safeTransfer(_receiver, outAmount);

        emit Swap(msg.sender, _inToken, _outToken, _receiver, _inAmount, outAmount);
    }

    /// Calculate the required input amount based on current price
    /// @param _inToken input ERC20 token
    /// @param _outToken output ERC20 token
    /// @param _outAmount amount of output tokens
    /// @return inAmount estimated amount of input tokens
    function calculateInAmount(
        address _inToken,
        address _outToken,
        uint256 _outAmount
    ) public view returns (uint256 inAmount) {
        TokenInfo storage inTokenInfo = tokenInfo[_inToken];
        TokenInfo storage outTokenInfo = tokenInfo[_outToken];

        require(address(inTokenInfo.priceOracle) != address(0), UnsupportedToken());
        require(address(outTokenInfo.priceOracle) != address(0), UnsupportedToken());

        uint256 inTokenPrice = inTokenInfo.priceOracle.getPrice(_inToken);
        uint256 outTokenPrice = outTokenInfo.priceOracle.getPrice(_outToken);

        uint256 mulDecimals = inTokenInfo.priceDecimals;
        uint256 divDecimals = outTokenInfo.priceDecimals;
        if (mulDecimals > divDecimals) {
            inAmount = Math.mulDiv(_outAmount, (10 ** (mulDecimals - divDecimals)) * outTokenPrice, inTokenPrice);
        }
        else {
            inAmount = Math.mulDiv(_outAmount, outTokenPrice, (10 ** (divDecimals - mulDecimals)) * inTokenPrice);
        }       

        inAmount += inAmount * priceSpread / 1000000;
    }

    /// Swap input tokens to output tokens with exact output amount
    /// @param _inToken input ERC20 token
    /// @param _outToken output ERC20 token
    /// @param _outAmount amount of output tokens
    /// @param _receiver receiving address
    /// @param _maxInAmount maximum input amount, revert if inAmount is more
    /// @return inAmount amount of input tokens used
    function swapExactOutput(
        address _inToken,
        address _outToken,
        uint256 _outAmount,
        address _receiver,
        uint256 _maxInAmount
    ) external returns (uint256 inAmount) {
        require(_receiver != address(0), InvalidReceiver());

        inAmount = calculateInAmount(_inToken, _outToken, _outAmount);

        require(inAmount > 0, NoInAmount());
        require(inAmount <= _maxInAmount, ExceedingInput(inAmount, _maxInAmount));

        IERC20 inToken = IERC20(_inToken);
        IERC20 outToken = IERC20(_outToken);

        inToken.safeTransferFrom(msg.sender, address(this), inAmount);
        outToken.safeTransfer(_receiver, _outAmount);

        emit Swap(msg.sender, _inToken, _outToken, _receiver, inAmount, _outAmount);
    }    
}
