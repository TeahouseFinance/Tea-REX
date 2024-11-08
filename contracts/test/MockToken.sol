// SPDX-License-Identifier: Unlicensed
// Mock ERC20 contract for testing purpose

pragma solidity =0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {

    uint8 private tokenDecimals;

    constructor(string memory _name, string memory _symbol, uint256 _initialSupply, uint8 _decimals) ERC20(_name, _symbol) {
        _mint(msg.sender, _initialSupply);
        tokenDecimals = _decimals;
    }

    function decimals() public view virtual override returns (uint8) {
        return tokenDecimals;
    }
}