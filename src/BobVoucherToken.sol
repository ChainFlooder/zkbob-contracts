// SPDX-License-Identifier: CC0-1.0

pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./token/ERC677.sol";
import "./token/ERC2612.sol";
import "./token/MintableERC20.sol";
import "./utils/Claimable.sol";

/**
 * @title BobVoucherToken
 */
contract BobVoucherToken is ERC20, ERC677, ERC2612, MintableERC20, Claimable {
    /**
     * @dev Creates a proxy implementation for BobVoucherToken.
     * @param _self address of the proxy contract, linked to the deployed implementation,
     * required for correct EIP712 domain derivation.
     */
    constructor(address _self) ERC20("", "") ERC2612(_self) {}

    /**
     * @dev Returns the name of the token.
     */
    function name() public view override returns (string memory) {
        return "BOB Voucher Token";
    }

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() public view override returns (string memory) {
        return "vBOB";
    }
}
