// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

interface ISyncSwapFeeReceiver {
    function factory() external view returns (address);
    function swapFor() external view returns (address);
    function swapAndDistributeWithTokens(address[] calldata tokens0, address[] calldata tokens1) external returns (uint256 amountOut);
    function swapAndDistribute(address[] calldata pairs) external returns (uint256 amountOut);
    event Distribute(uint256 amount);
}