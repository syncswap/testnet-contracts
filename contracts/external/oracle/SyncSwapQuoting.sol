// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import '../../interfaces/protocol/core/ISyncSwapFactory.sol';
import '../../interfaces/protocol/core/ISyncSwapPair.sol';

/**
 * @dev A helper contract for off-chain price quotes.
 *
 * Note this contract is not gas efficient and should NOT be called on chain.
 */
contract SyncSwapQuoting {

    /// @dev Quote amount of `tokenB` at the same value of `tokenA`, without slippage or fees.
    function quote(address factory, address tokenA, uint amountA, address tokenB) public view returns (uint amountB) {
        if (amountA == 0 || tokenA == tokenB) {
            return amountA;
        }

        address pair = ISyncSwapFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            return 0;
        }

        (uint reserve0, uint reserve1) = ISyncSwapPair(pair).getReservesSimple();
        if (reserve0 == 0 || reserve1 == 0) {
            return 0;
        }

        (uint reserveA, uint reserveB) = tokenA < tokenB ? (reserve0, reserve1) : (reserve1, reserve0);
        return amountA * reserveB / reserveA;
    }

    /// @dev Quote amounts of `tokensIn` at the same value of `tokenOut`, without slippage or fees.
    function quoteMulti(address factory, address[] memory tokensIn, uint[] memory amountsIn, address tokenOut) public view returns (uint[] memory amountsOut) {
        require(tokensIn.length == amountsIn.length, "SyncSwapQuoting: inconsistent data length");

        amountsOut = new uint[](tokensIn.length);

        for (uint i; i < tokensIn.length; i++) {
            amountsOut[i] = quote(factory, tokensIn[i], amountsIn[i], tokenOut);
        }
    }

    /// @dev Quote amount of `tokenB` at the same value of `tokenA` with path tokens, without slippage or fees.
    function quoteWithPath(address factory, address tokenA, uint amountA, address tokenB, address[] memory pathTokens) public view returns (uint amountB) {
        uint amountBDirect = quote(factory, tokenA, amountA, tokenB);
        if (amountBDirect != 0) {
            return amountBDirect;
        }

        for (uint i; i < pathTokens.length; i++) {
            address pathToken = pathTokens[i];

            uint amountPath = quote(factory, tokenA, amountA, pathToken);
            if (amountPath == 0) {
                continue;
            }

            uint amountBRoute = quote(factory, pathToken, amountPath, tokenB);
            if (amountBRoute != 0) {
                return amountBRoute;
            }
        }
    }

    /// @dev Quote amounts of `tokensIn` at the same value of `tokenOut` with path tokens, without slippage or fees.
    function quoteMultiWithPath(address factory, address[] memory tokensIn, uint[] memory amountsIn, address tokenOut, address[] memory pathTokens) public view returns (uint[] memory amountsOut) {
        require(tokensIn.length == amountsIn.length, "SyncSwapQuoting: inconsistent data length");

        amountsOut = new uint[](tokensIn.length);

        for (uint i; i < tokensIn.length; i++) {
            amountsOut[i] = quoteWithPath(factory, tokensIn[i], amountsIn[i], tokenOut, pathTokens);
        }
    }
}