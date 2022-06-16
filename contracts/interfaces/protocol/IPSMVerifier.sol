// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

interface IPSMVerifier {
    function verifyDeposit(address asset, uint256 assetAmount) external view returns (bool);
    function verifySwap(address assetIn, address assetOut, uint256 amountIn) external view returns (bool);
}