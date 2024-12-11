// SPDX-License-Identifier: Unlicensed
// Mock ERC20 contract for testing purpose

pragma solidity =0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockToken is ERC20, Ownable, ERC20Pausable, ERC20Permit {

    uint8 private tokenDecimals;

    constructor(address _owner, string memory _name, string memory _symbol, uint256 _initialSupply, uint8 _decimals)
        ERC20(_name, _symbol)
        Ownable(_owner)
        ERC20Permit(_name)
    {
        _mint(msg.sender, _initialSupply);
        tokenDecimals = _decimals;
    }

    function decimals() public view virtual override returns (uint8) {
        return tokenDecimals;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    // The following functions are overrides required by Solidity.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }
}