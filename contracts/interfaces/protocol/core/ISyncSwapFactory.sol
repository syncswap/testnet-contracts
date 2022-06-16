// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import "./uniswap/IUniswapV2Factory.sol";

/// @dev SyncSwap factory interface with full Uniswap V2 compatibility
interface ISyncSwapFactory is IUniswapV2Factory {
    function isPair(address pair) external view returns (bool);
    function acceptFeeToSetter() external;

    function swapFeePoint() external view returns (uint16);
    function setSwapFeePoint(uint16 newPoint) external;

    function protocolFeeFactor() external view returns (uint8);
    function setProtocolFeeFactor(uint8 newFactor) external;

    function setSwapFeePointOverride(address pair, uint16 swapFeePointOverride) external;
    function setLiquidityAmplifier(address pair, uint32 liquidityAmplifier) external;
}
