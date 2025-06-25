// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

/// @title Swap helper contract for aggregators to support swapExactOutput
/// @notice This contract calls an aggregator for a normal swap input call, and a second call to a
/// @notice normal swap contract with the remaining tokens to swap the extra (scrap) dst tokens back
/// @notice to src token, thus making sure that the amount of dst tokens is exactly the same as specified.
/// @notice This contract replaces the "amountIn" parameter in scrapCalldata to make sure only the extra
/// @notice amount of destination tokens are swapped back.
interface IAggregatorHelper {

    error LengthMismatch();
    error NotWhitelisted();
    error InputAmountNotCleared();
    error OutputScrapNotCleared();
    error IncorrectScrapAmountSize();
    error IncorrectScrapAmountOffset();
    error NoTokenReceived();
    error NotEnoughAmountOut();
    error AmountInTooSmall();

    event SetCheckWhitelist(address sender, bool checkWhitelist);
    event SetRouterWhitelist(address sender, address[] router, bool[] isWhitelisted);
    event SetVerifierWhitelist(address sender, address[] verifier, bool[] isWhitelisted);
    event SetCallerWhitelist(address sender, address[] caller, bool[] isWhitelisted);    
    event SetMaxScraps(address sender, uint256 maxScraps);
    event SetMinAmountIn(address sender, uint256 minAmountIn);

    /// @notice Set whether to check whitelists
    /// @param _checkWhitelist true if want to check whitelists, false if not
    /// @notice only owner can call this function
    function setCheckWhitelist(bool _checkWhitelist) external;

    /// @notice Set whitelist address for swap router and scrap router
    /// @param _router array of addresses of the routers
    /// @param _isWhitelisted array of bools for each router to be whitelisted (true if whitelist and false if not)
    /// @notice only owner can call this function
    function setRouterWhitelist(address[] calldata _router, bool[] calldata _isWhitelisted) external;

    /// @notice Set whitelist address for verifier
    /// @param _verifier array of addresses of the verifiers
    /// @param _isWhitelisted array of bools for each verifier to be whitelisted (true if whitelist and false if not)
    /// @notice only owner can call this function
    function setVerifierWhitelist(address[] calldata _verifier, bool[] calldata _isWhitelisted) external;

    /// @notice Set whitelist address for caller
    /// @param _caller array of addresses of the callers
    /// @param _isWhitelisted array of bools for each caller to be whitelisted (true if whitelist and false if not)
    /// @notice only owner can call this function
    function setCallerWhitelist(address[] calldata _caller, bool[] calldata _isWhitelisted) external;

    /// @notice Set the maximum amount of scraps allowed in swapExactInput
    /// @param _maxScraps amount of maximum amount of scraps allowed
    /// @notice only owner can call this function
    function setMaxScraps(uint256 _maxScraps) external;

    /// @notice retrieve scraps left in the contract
    /// @param _token address of the token to retrieve
    /// @param _amount amount of the token to retrieve
    /// @notice only owner can call this function
    function retrieveTokens(address _token, uint256 _amount) external;

    /// @notice retrieve scraps left in the contract
    /// @param _amount amount of the native token to retrieve
    /// @notice only owner can call this function
    function retrieveNativeToken(uint256 _amount) external;

    /// @notice Function to simulate an exact input swap
    /// @param _src source token
    /// @param _dst destination token
    /// @param _amountIn amount of source tokens to swap
    /// @param _verifier address of the verifier
    /// @param _verifierCalldata calldata for the verifier
    /// @param _router address of the swap router
    /// @param _routerCalldata calldata for the swap router
    function swapExactInput(
        address _src,
        address _dst,
        uint256 _amountIn,
        address _verifier,
        bytes calldata _verifierCalldata,
        address _router,
        bytes calldata _routerCalldata
    ) external;

    /// @notice Function to simulate an exact output swap
    /// @param _src source token
    /// @param _dst destination token
    /// @param _amountIn maximum amount of source tokens to swap
    /// @param _amountOut expected amount of destination tokens
    /// @param _verifier address of the verifier
    /// @param _verifierCalldata calldata for the verifier
    /// @param _router address of the swap router
    /// @param _routerCalldata calldata for the swap router
    /// @param _scrapRouter swap contract for extra (scrap) destination tokens
    /// @param _scrapCalldata calldata for swapping extra destination tokens
    /// @param _scrapAmountOffset offset (in bytes) for the "amountIn" parameter in _scrapCalldata
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
    ) external;

}
