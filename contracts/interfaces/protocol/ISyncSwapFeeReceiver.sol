// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

interface ISyncSwapFeeReceiver {
    function factory() external view returns (address);

    function convertTokensAndDistribute(address[] calldata tokens0, address[] calldata tokens1) external returns (uint256 converted, uint256 bounty);
    function convertAndDistribute(address[] calldata pairs) external returns (uint256 converted, uint256 bounty);
}