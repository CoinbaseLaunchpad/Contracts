// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract CoinbaseLaunchpadToken is ERC20, ERC20Burnable {
    constructor() ERC20("Coinbase Launchpad Token", "CLT") {
        _mint(msg.sender, 100000000000000 * 10 ** decimals());
    }
}