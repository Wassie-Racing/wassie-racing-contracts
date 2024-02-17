// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*  contract purpose is purely to overcome address == account restriction of ERC20Rebasing contract
    main contract sends USDB or WETH to this contract then uses transferFrom to send it back
*/

contract RerouteYield {
    constructor(address mainContract, address WETH, address USDB)  {
        IERC20(WETH).approve(mainContract, type(uint256).max);
        IERC20(USDB).approve(mainContract, type(uint256).max);
    }
}