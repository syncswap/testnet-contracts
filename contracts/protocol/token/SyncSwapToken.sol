// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import '../../libraries/token/ERC20/ERC20WithPermit.sol';

contract SyncSwapToken is ERC20WithPermit {
    constructor() {
        _initializeMetadata("SyncSwap Token", "SYNC");
        _mint(msg.sender, 1_000_000_000 * 1e18);
    }
}