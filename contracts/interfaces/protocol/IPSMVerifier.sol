// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

interface IPSMVerifier {
    /**
     * @dev Returns whether a deposit is allowed.
     */
    function verifyDeposit(address caller, address asset, uint256 assetAmount) external view returns (bool);

    /**
     * @dev Returns whether a swap is allowed.
     */
    function verifySwap(address caller, address assetIn, address assetOut, uint256 amountIn) external view returns (bool);
}