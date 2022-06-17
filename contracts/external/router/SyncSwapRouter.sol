// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import './SyncSwapRouterInternal.sol';

import '../../interfaces/protocol/ISyncSwapRouter.sol';
import '../../interfaces/protocol/ISyncPSM.sol';
import '../../interfaces/protocol/core/ISyncSwapFactory.sol';

import '../../libraries/protocol/SyncSwapLibrary.sol';
import '../../libraries/token/ERC20/utils/TransferHelper.sol';

import '../../protocol/farm/SyncSwapFarm.sol';

contract SyncSwapRouter is ISyncSwapRouter, SyncSwapRouterInternal {

    address public immutable override psm;
    address public immutable override factory;

    constructor(address _factory, address _psm) {
        factory = _factory;
        psm = _psm;
    }

    /*//////////////////////////////////////////////////////////////
        Pair Index
    //////////////////////////////////////////////////////////////*/

    mapping(address => mapping(address => bool)) public override isPairIndexed;
    mapping(address => address[]) public override indexedPairs;

    function indexedPairsOf(address account) external view override returns (address[] memory) {
        return indexedPairs[account];
    }

    function indexedPairsRange(address account, uint256 start, uint256 counts) external view override returns (address[] memory) {
        require(counts != 0, "Counts must greater than zero");

        address[] memory pairs = indexedPairs[account];
        require(start + counts <= pairs.length, "Out of bound");

        address[] memory result = new address[](counts);
        for (uint256 i = 0; i < counts; i++) {
            result[i] = pairs[start + i];
        }
        return result;
    }

    function indexedPairsLengthOf(address account) external view override returns (uint256) {
        return indexedPairs[account].length;
    }

    /*//////////////////////////////////////////////////////////////
        PSM
    //////////////////////////////////////////////////////////////*/

    function depositPSM(
        address asset,
        uint256 assetAmount,
        address to,
        uint deadline
    ) external override ensureNotExpired(deadline) {
        address _psm = psm;
        TransferHelper.safeTransferFrom(asset, msg.sender, address(this), assetAmount);
        IERC20(asset).approve(_psm, assetAmount);
        ISyncPSM(_psm).deposit(asset, assetAmount, to);
    }

    function withdrawPSM(
        address asset,
        uint256 nativeAmount,
        address to,
        uint deadline
    ) external override ensureNotExpired(deadline) {
        address _psm = psm;
        TransferHelper.safeTransferFrom(_psm, msg.sender, address(this), nativeAmount);
        ISyncPSM(_psm).withdraw(asset, nativeAmount, to);
    }

    function swapPSM(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        address to,
        uint deadline
    ) external override ensureNotExpired(deadline) {
        address _psm = psm;
        TransferHelper.safeTransferFrom(assetIn, msg.sender, address(this), amountIn);
        IERC20(assetIn).approve(_psm, amountIn);
        ISyncPSM(_psm).swap(assetIn, assetOut, amountIn, to);
    }

    /*//////////////////////////////////////////////////////////////
        Add Liquidity
    //////////////////////////////////////////////////////////////*/

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountAInExpected,
        uint amountBInExpected,
        uint amountAInMin,
        uint amountBInMin,
        address to,
        uint deadline
    ) external override ensureNotExpired(deadline) returns (uint amountAInActual, uint amountBInActual, uint liquidity) {
        address _factory = factory;
        address pair = SyncSwapLibrary.pairFor(_factory, tokenA, tokenB);
        if (pair == address(0)) {
            // create the pair if it doesn't exist yet
            pair = ISyncSwapFactory(_factory).createPair(tokenA, tokenB);

            // input amounts are desired amounts for the first time
            (amountAInActual, amountBInActual) = (amountAInExpected, amountBInExpected);
        } else {
            // ensure optimal input amounts
            (amountAInActual, amountBInActual) = _getOptimalAmountsInForAddLiquidity(
                pair, tokenA, tokenB, amountAInExpected, amountBInExpected, amountAInMin, amountBInMin
            );
        }

        // transfer tokens of (optimal) input amounts to the pair
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountAInActual);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountBInActual);

        // mint the liquidity tokens for sender
        liquidity = ISyncSwapPair(pair).mint(to);

        // index the pair for search
        if (!isPairIndexed[to][pair]) {
            isPairIndexed[to][pair] = true;
            indexedPairs[to].push(pair);
        }
    }

    /*//////////////////////////////////////////////////////////////
        Remove Liquidity
    //////////////////////////////////////////////////////////////*/

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAOutMin,
        uint amountBOutMin,
        address to,
        uint deadline
    ) external override ensureNotExpired(deadline) returns (uint amountAOut, uint amountBOut) {
        address pair = SyncSwapLibrary.pairFor(factory, tokenA, tokenB);
        (amountAOut, amountBOut) = _burnLiquidity(
            pair, tokenA, tokenB, liquidity, amountAOutMin, amountBOutMin, to
        );
    }

    function _removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAOutMin,
        uint amountBOutMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v, bytes32 r, bytes32 s
    ) internal returns (uint amountAOut, uint amountBOut) {
        address pair = SyncSwapLibrary.pairFor(factory, tokenA, tokenB);
        _permit(pair, approveMax, liquidity, deadline, v, r, s);

        (amountAOut, amountBOut) = _burnLiquidity(
            pair, tokenA, tokenB, liquidity, amountAOutMin, amountBOutMin, to
        );
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAOutMin,
        uint amountBOutMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v, bytes32 r, bytes32 s
    ) external override returns (uint amountAOut, uint amountBOut) {
        // wrapped to avoid stack too deep errors
        (amountAOut, amountBOut) = _removeLiquidityWithPermit(tokenA, tokenB, liquidity, amountAOutMin, amountBOutMin, to, deadline, approveMax, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
        Swap
    //////////////////////////////////////////////////////////////*/

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensureNotExpired(deadline) returns (uint[] memory amounts) {
        address _factory = factory;
        amounts = SyncSwapLibrary.getAmountsOutUnchecked(_factory, amountIn, path); // will fail below if path is invalid
        // make sure the final output amount not smaller than the minimum
        require(amounts[amounts.length - 1] >= amountOutMin, 'INSUFFICIENT_OUTPUT_AMOUNT');

        address initialPair = SyncSwapLibrary.pairFor(_factory, path[0], path[1]);
        TransferHelper.safeTransferFrom(path[0], msg.sender, initialPair, amounts[0]);
        _swapCached(_factory, initialPair, amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensureNotExpired(deadline) returns (uint[] memory amounts) {
        address _factory = factory;
        amounts = SyncSwapLibrary.getAmountsInUnchecked(_factory, amountOut, path); // will fail below if path is invalid
        // make sure the final input amount not bigger than the maximum
        require(amounts[0] <= amountInMax, 'EXCESSIVE_INPUT_AMOUNT');

        address initialPair = SyncSwapLibrary.pairFor(_factory, path[0], path[1]);
        TransferHelper.safeTransferFrom(path[0], msg.sender, initialPair, amounts[0]);
        _swapCached(_factory, initialPair, amounts, path, to);
    }

    /*//////////////////////////////////////////////////////////////
        Swap (fee-on-transfer)
    //////////////////////////////////////////////////////////////*/

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensureNotExpired(deadline) {
        address _factory = factory;
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, SyncSwapLibrary.pairFor(_factory, path[0], path[1]), amountIn
        );
        address outputToken = path[path.length - 1];
        uint balanceBefore = IERC20(outputToken).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(_factory, path, to);
        require(
            IERC20(outputToken).balanceOf(to) - balanceBefore >= amountOutMin,
            'INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    /*//////////////////////////////////////////////////////////////
        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function quote(uint amountA, uint reserveA, uint reserveB) external pure override returns (uint amountB) {
        return SyncSwapLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external view override returns (uint amountOut) {
        return SyncSwapLibrary.getAmountOut(amountIn, reserveIn, reserveOut, ISyncSwapFactory(factory).swapFeePoint());
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external view override returns (uint amountIn) {
        return SyncSwapLibrary.getAmountIn(amountOut, reserveIn, reserveOut, ISyncSwapFactory(factory).swapFeePoint());
    }

    function getAmountsOut(uint amountIn, address[] calldata path) external view override returns (uint[] memory amounts) {
        return SyncSwapLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] calldata path) external view override returns (uint[] memory amounts) {
        return SyncSwapLibrary.getAmountsIn(factory, amountOut, path);
    }
}
