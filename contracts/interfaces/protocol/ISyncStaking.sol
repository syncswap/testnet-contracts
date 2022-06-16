// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import '../ERC20/IERC20.sol';

interface ISyncStaking {
    function token() external view returns (IERC20);
    function depositBalance() external view returns (uint256);
    function rewardTokens(uint256) external view returns (IERC20);
    function rewardTokensLength() external view returns (uint256);
    function isRewardToken(IERC20) external view returns (bool);
    function feeCollector() external view returns (address);
    function depositFeePercent() external view returns (uint256);
    function getUserInfo(address user, IERC20 rewardToken) external view returns (uint256, uint256);

    struct PendingReward {
        address rewardToken;
        uint256 pendingReward;
        uint256 lastPeriodRewardPerShare;
        uint256 currentPeriodRewardPerShare;
        uint256 currentPeriodDuration;
    }

    function pendingReward(address user, IERC20 token) external view returns (PendingReward memory);
    function allPendingRewards(address user) external view returns (PendingReward[] memory pendingRewards);
    function summary(address _user) external view returns (
        uint256 depositFeePercent,
        uint256 totalDeposit,
        uint256 userDeposit,
        uint256 userBalance,
        uint256 userAllowance,
        PendingReward[] memory pendingRewards
    );

    function updateReward(IERC20 token) external;
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;

    /// @notice Emitted when a user deposits SYNC
    event Deposit(address indexed user, uint256 amount, uint256 fee);

    /// @notice Emitted when owner changes the deposit fee percentage
    event DepositFeeChanged(uint256 newFee, uint256 oldFee);

    /// @notice Emitted when a user withdraws SYNC
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims reward
    event ClaimReward(address indexed user, address indexed rewardToken, uint256 amount);

    /// @notice Emitted when a user emergency withdraws its SYNC
    event EmergencyWithdraw(address indexed user, uint256 amount);

    /// @notice Emitted when owner adds a token to the reward tokens list
    event RewardTokenAdded(address token);

    /// @notice Emitted when owner removes a token from the reward tokens list
    event RewardTokenRemoved(address token);
}