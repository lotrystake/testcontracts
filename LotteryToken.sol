// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol"; // Optional: If LotteryContract burns tokens

/**
 * @title LotteryToken
 * @dev Simple ERC20 token earned via staking, mintable only by the owner (StakingContract).
 * Inherits Burnable if the LotteryContract will burn tokens upon entry.
 */
contract LotteryToken is ERC20, Ownable, ERC20Burnable { // Include ERC20Burnable if needed
    constructor() ERC20("Lottery Token", "LTK") Ownable(msg.sender) {
        // Owner is deployer initially, will be transferred to StakingContract
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply. Only callable by the owner (the StakingContract).
     * Emits a {Transfer} event with `from` set to the zero address.
     */
    function mint(address account, uint256 amount) public onlyOwner {
        _mint(account, amount);
    }

    // If LotteryContract burns tokens, no extra function needed,
    // just ensure LotteryContract has approval to call burnFrom or users call burn.
}
