// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

interface ISyncPSM {
    function FEE_PRECISION() external view returns (uint256);
    function swapFeeRate() external view returns (uint256);

    function getWithdrawFee(address account, address asset, uint256 amount) external view returns (uint256);
    function getWithdrawOut(address account, address asset, uint256 amount) external view returns (uint256);
    function getSwapOut(address account, address assetIn, address assetOut, uint256 amountIn) external view returns (uint256 amountOut);

    function deposit(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 nativeAmount) external returns (uint256 amountOut);
    function swap(address assetIn, address assetOut, uint256 amountIn) external returns (uint256 amountOut);
}