// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import '../../libraries/security/ReentrancyGuard.sol';
import '../../libraries/access/Ownable.sol';
import '../../interfaces/ERC20/IERC20.sol';

import '../../libraries/token/ERC20/ERC20Readonly.sol';
import '../../libraries/token/ERC20/utils/SafeERC20.sol';
import '../../interfaces/ERC20/IERC20Metadata.sol';

import '../../libraries/utils/math/Math.sol';

contract SyncSwapFarm is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
        CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Precision for float numbers
    uint256 public constant PRECISION = 1e18;

    /// @dev Maximum allowed amount of reward tokens, to limit gas use
    uint256 public constant MAXIMUM_REWARD_TOKENS = 5;

    /// @dev Grace period between every enter time update.
    uint256 public constant ENTER_TIME_GRACE_PERIOD = 10 minutes;

    /*//////////////////////////////////////////////////////////////
        Pool Data
    //////////////////////////////////////////////////////////////*/

    /// @dev Share token to stake
    address public shareToken;

    /// @dev Withdraw cooldown in seconds (could be zero)
    uint256 public withdrawCooldown = 7 days;

    /// @dev Fee rate of early withdraw
    uint256 public earlyWithdrawFeeRate = 1e16; // 1%

    /// @dev Recipient of early withdraw fee
    address public feeRecipient; // zero address indicates not enabled

    /// @dev Amount of total staked share token in this pool
    uint256 public totalShare;

    /*//////////////////////////////////////////////////////////////
        Reward Token Data
    //////////////////////////////////////////////////////////////*/

    struct RewardTokenData {
        /// @dev Whether it is a reward token.
        bool isRewardToken;

        /// @dev Reward emissions per second (rate) of this reward tokem
        uint256 rewardPerSecond;

        /// @dev Start time of this reward emission (inclusive, applicable for reward)
        uint256 startTime;

        /// @dev End time of this reward emission (inclusive, applicable for reward)
        uint256 endTime;

        /// @dev Accumulated reward per share for this reward token
        uint256 accRewardPerShare; // INCREASE ONLY

        /// @dev Timestamp of last update
        uint256 lastUpdate;
    }

    /// @dev Data of reward tokens, support multiple reward tokens
    mapping(address => RewardTokenData) public rewardTokenData; // token -> data

    /// @dev Added reward tokens for this pool
    address[] public rewardTokens;

    /// @dev Helper to access length of reward tokens array
    function rewardTokensLength() public view returns (uint256) {
        return rewardTokens.length;
    }

    /*//////////////////////////////////////////////////////////////
        User Data
    //////////////////////////////////////////////////////////////*/

    /// @dev User enter time, useful when early withdraw fee is enabled
    mapping(address => uint256) public enterTime; // user -> enterTime

    /// @dev Amount of user staked share token
    mapping(address => uint256) public userShare; // user -> share

    struct UserRewardData {
        /// @dev Accrued rewards in this reward token available for claiming
        uint256 accruedRewards;

        /// @dev Reward debt per share for this reward token
        uint256 debtRewardPerShare;
    }

    /// @dev User data of each reward token
    mapping(address => mapping(address => UserRewardData)) public userRewardData; // token -> user -> data

    /*//////////////////////////////////////////////////////////////
        EVENTS
    //////////////////////////////////////////////////////////////*/

    event Stake(address indexed from, uint256 amount, address indexed onBehalf);
    event Withdraw(address indexed account, uint256 amount, address indexed to);
    event Harvest(address indexed account, address rewardToken, uint256 rewardAmount, address indexed to);

    event AddRewardToken(address indexed rewardToken);
    event SetRewardParams(address indexed rewardToken, uint256 rewardPerSecond, uint256 startTime, uint256 endTime);
    event UpdateRewardPerShare(address indexed rewardToken, uint256 lastUpdateTime, uint256 totalShare, uint256 accRewardPerShare);

    constructor(address _shareToken, address _feeRecipient) {
        require(_shareToken != address(0), "Invalid share token");
        shareToken = _shareToken;
        feeRecipient = _feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns last time the reward is applicable, a time between start time and end time.
     */
    function _lastTimeRewardApplicable(RewardTokenData memory tokenData) internal view returns (uint256) {
        return Math.max(tokenData.startTime, Math.min(block.timestamp, tokenData.endTime));
    }

    /**
     * @dev Returns first time the reward is applicable, a time between start time and end time.
     */
    function _firstTimeRewardApplicable(RewardTokenData memory tokenData) internal pure returns (uint256) {
        return Math.min(tokenData.endTime, Math.max(tokenData.lastUpdate, tokenData.startTime));
    }

    /**
     * @dev Returns pending `rewardPerShare` for a reward.
     *
     * Pending `rewardPerShare` is accumulated `rewardPerShare` that has not been
     * write into stroage since last update.
     *
     * It will returns zero when:
     * - The token is not a reward (anymore).
     * - The reward emission rate is zero.
     * - The reward emission is not started or was ended.
     * - The elapsed time since last update is zero.
     * - There is no share token staked.
     */
    function _pendingRewardPerShare(RewardTokenData memory rewardData, uint256 _totalShare) internal view returns (uint256) {
        if (
            rewardData.rewardPerSecond == 0 ||
            rewardData.lastUpdate == block.timestamp ||
            _totalShare == 0
        ) {
            return 0;
        }

        uint256 lastTimeRewardApplicable = _lastTimeRewardApplicable(rewardData);
        uint256 firstTimeRewardApplicable = _firstTimeRewardApplicable(rewardData);
        if (lastTimeRewardApplicable <= firstTimeRewardApplicable) {
            return 0;
        }

        uint256 elapsedSeconds = lastTimeRewardApplicable - firstTimeRewardApplicable;
        uint256 pendingRewards = elapsedSeconds * rewardData.rewardPerSecond;
        uint256 pendingRewardPerShare = pendingRewards * PRECISION / _totalShare;

        // Revert if rounded to zero to prevent reward loss.
        require(pendingRewardPerShare != 0, "No pending reward to accumulate");
        return pendingRewardPerShare;
    }

    /**
     * @dev Returns latest `rewardPerShare` for given reward.
     *
     * Note that it may includes pending `rewardPerShare` that has not been written
     * into the storage and thus can be used to PREVIEW ONLY.
     */
    function _latestRewardPerShare(RewardTokenData memory rewardData, uint256 _totalShare) internal view returns (uint256) {
        return rewardData.accRewardPerShare + _pendingRewardPerShare(rewardData, _totalShare);
    }

    /**
     * @dev Returns pending rewards for given account and reward.
     */
    function _pendingRewards(uint256 rewardPerShare, uint256 debtRewardPerShare, uint256 _userShare) internal pure returns (uint256) {
        if (rewardPerShare > debtRewardPerShare) {
            return (rewardPerShare - debtRewardPerShare) * _userShare / PRECISION;
        }
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns data for all reward tokens.
     */
    function allRewardTokenData() external view returns (RewardTokenData[] memory data) {
        uint256 _len = rewardTokensLength();
        data = new RewardTokenData[](_len);

        for (uint256 i = 0; i < _len; ) {
            data[i] = rewardTokenData[rewardTokens[i]];
            unchecked { i++; }
        }
    }

    /**
     * @dev Returns user data for all reward tokens.
     */
    function allUserRewardData(address account) external view returns (UserRewardData[] memory data) {
        uint256 _len = rewardTokensLength();
        data = new UserRewardData[](_len);

        for (uint256 i = 0; i < _len; ) {
            data[i] = userRewardData[rewardTokens[i]][account];
            unchecked { i++; }
        }
    }

    /**
     * @dev see {availableRewardOf}
     */
    function _availableRewardOf(address account, address token, uint256 _totalShare, uint256 _userShare) internal view returns (uint256) {
        UserRewardData memory user = userRewardData[token][account];
        uint256 pendingRewards = _userShare == 0 ? 0 : _pendingRewards(
            _latestRewardPerShare(rewardTokenData[token], _totalShare),
            user.debtRewardPerShare,
            _userShare
        );
        return user.accruedRewards + pendingRewards;
    }

    /**
     * @dev Returns how many rewards is claimable for the given account.
     *
     * This is useful for frontend to show available rewards.
     */
    function availableRewardOf(address account, address token) external view returns (uint256) {
        return _availableRewardOf(account, token, totalShare, userShare[account]);
    }

    /**
     * @dev see {availableRewardOf}.
     */
    function allAvailableRewardsOf(address account) external view returns (uint256[] memory availableRewards) {
        uint256 _len = rewardTokensLength();
        uint256 _totalShare = totalShare;
        uint256 _userShare = userShare[account];
        availableRewards = new uint256[](_len);

        for (uint256 i = 0; i < _len; ) {
            availableRewards[i] = _availableRewardOf(account, rewardTokens[i], _totalShare, _userShare);
            unchecked { i++; }
        }
    }

    /**
     * @dev Returns the first time which is possible to withdraw without fee.
     */
    function firstTimeFreeWithdrawOf(address account) external view returns (uint256) {
        if (feeRecipient == address(0)) {
            return block.timestamp;
        }

        uint256 sinceLastEnter = block.timestamp - enterTime[account];
        uint256 _withdrawCooldown = withdrawCooldown;
        uint256 remaining = sinceLastEnter < _withdrawCooldown ? withdrawCooldown - sinceLastEnter : 0;

        return block.timestamp + remaining;
    }

    /*//////////////////////////////////////////////////////////////
        Update Reward Per Share
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Updates `rewardPerShare` for given reward token with its `totalShare`.
     *
     * MUST update SINGLE reward token before made changes to:
     * - `rewardPerSecond`
     * - `startTime`
     * - `endTime`
     *
     * MUST update ALL reward tokens before made changes to:
     * - `totalShare`
     */
    function _updateRewardPerShare(address token, uint256 _totalShare) internal returns (uint256 updatedRewardPerShare) {
        RewardTokenData memory rewardData = rewardTokenData[token];

        uint256 pendingRewardPerShare = _pendingRewardPerShare(rewardData, _totalShare);
        updatedRewardPerShare = rewardData.accRewardPerShare + pendingRewardPerShare;

        if (pendingRewardPerShare != 0) {
            rewardTokenData[token].accRewardPerShare = updatedRewardPerShare;
        }

        rewardTokenData[token].lastUpdate = block.timestamp;
        emit UpdateRewardPerShare(token, rewardData.lastUpdate, _totalShare, updatedRewardPerShare);

        return updatedRewardPerShare;
    }

    /*//////////////////////////////////////////////////////////////
        Accrue Rewards
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Updates `accruedRewards` for given account and reward token.
     *
     * Note this will use accumulated `rewardPerShare` in the storage,
     * which does not includes the pending `rewardPerShare`.
     *
     * Should call {updateRewardPerShare} first to update `rewardPerShare`
     * to include pending `rewardPerShare`.
     *
     * MUST accrue ALL rewards before made changes to:
     * - `userShare`
     *
     * MUST update SINGLE reward token before made changes to:
     * - `rewardPerSecond`
     * - `startTime`
     * - `endTime`
     *
     * MUST update ALL reward tokens before made changes to:
     * - `totalShare`
     */
    function _accrueReward(address account, address token, uint256 _rewardPerShare, uint256 _userShare) internal {
        UserRewardData memory user = userRewardData[token][account];
        uint256 pendingRewards = _userShare == 0 ? 0 : _pendingRewards(
            _rewardPerShare,
            user.debtRewardPerShare,
            _userShare
        );

        if (pendingRewards != 0) {
            userRewardData[token][account].accruedRewards += pendingRewards;
        }
        userRewardData[token][account].debtRewardPerShare = _rewardPerShare;
    }

    /**
     * @dev Updates `rewardPerShare` for all reward tokens,
     * and `accruedRewards` for given account and all reward tokens.
     *
     * MUST accrue ALL rewards before made changes to:
     * - `userShare`
     *
     * MUST update SINGLE reward token before made changes to:
     * - `rewardPerSecond`
     * - `startTime`
     * - `endTime`
     *
     * MUST update ALL reward tokens before made changes to:
     * - `totalShare`
     */
    function _updateAndAccrueAllRewards(address account) internal {
        uint256 _len = rewardTokensLength();
        uint256 _totalShare = totalShare;
        uint256 _userShare = userShare[account];

        for (uint256 i = 0; i < _len; ) {
            address token = rewardTokens[i];
            uint256 _rewardPerShare = _updateRewardPerShare(token, _totalShare);
            _accrueReward(account, token, _rewardPerShare, _userShare);
            unchecked { i++; }
        }
    }

    /*//////////////////////////////////////////////////////////////
        Reward Management
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Set cooldown for early withdraw.
     */
    function setWithdrawCooldown(uint256 newCooldown) external onlyOwner {
        require(newCooldown != 0, "Invalid cooldown");
        withdrawCooldown = newCooldown;
    }

    /**
     * @dev Set fee rate for early withdraw. Cannot exceeds precision.
     */
    function setEarlyWithdrawFeeRate(uint256 newFeeRate) external onlyOwner {
        require(newFeeRate != 0 && newFeeRate <= PRECISION, "Invalid fee rate");
        earlyWithdrawFeeRate = newFeeRate;
    }

    /**
     * @dev Set recipient for early withdraw fee.
     *
     * The zero address indicates early withdraw fee is not enabled.
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        feeRecipient = newRecipient;
    }

    /**
     * @dev Returns remaining rewards that expected be distributed from current time to end time.
     */
    function _remainingRewards(uint256 rewardPerSecond, uint256 startTime, uint256 endTime) internal view returns (uint256) {
        if (rewardPerSecond == 0 || startTime == 0 || endTime == 0) {
            return 0;
        }

        uint256 firstTimeRewardApplicable = Math.min(endTime, Math.max(block.timestamp, startTime));
        return (endTime - firstTimeRewardApplicable) * rewardPerSecond;
    }

    function _isRewardBalanceSufficient(address token, uint256 rewardPerSecond, uint256 startTime, uint256 endTime) internal view returns (bool) {
        uint256 rewardsRequire = _remainingRewards(rewardPerSecond, startTime, endTime);
        if (rewardsRequire == 0) {
            return true;
        }

        uint256 rewardTokenBalance = IERC20(token).balanceOf(address(this));
        uint256 rewardsBalance = token == shareToken ? rewardTokenBalance - totalShare : rewardTokenBalance;

        return rewardsBalance >= rewardsRequire;
    }

    /**
     * @dev Add a new reward token.
     *
     * Be careful to add a reward token because it's impossible to remove it!
     */
    function addRewardToken(address token) external onlyOwner {
        require(token != address(0), "Invalid reward token");
        require(!rewardTokenData[token].isRewardToken, "Token is already reward");
        require(rewardTokensLength() < MAXIMUM_REWARD_TOKENS, "Too many reward tokens");

        rewardTokens.push(token);
        rewardTokenData[token].isRewardToken = true;

        emit AddRewardToken(token);
    }

    /**
     * @dev Set reward params for given reward token.
     *
     * Requires there is sufficient balance to pay the rewards.
     */
    function setRewardParams(address token, uint256 newRewardPerSecond, uint256 newStartTime, uint256 newEndTime) external onlyOwner {
        RewardTokenData memory data = rewardTokenData[token];
        require(data.isRewardToken, "Token is not reward");
        require(newStartTime < newEndTime, "Start must earlier than end");

        // MUST update reward before made changes.
        _updateRewardPerShare(token, totalShare);

        // Configure reward emission rate
        rewardTokenData[token].rewardPerSecond = newRewardPerSecond;

        // Configure start time
        if (newStartTime != data.startTime) {
            require(newStartTime > block.timestamp, "Invalid start time");
            rewardTokenData[token].startTime = newStartTime;
        }

        // Configure End time
        if (newEndTime != data.endTime) {
            require(newEndTime > block.timestamp, "Invalid end time");
            rewardTokenData[token].endTime = newEndTime;
        }

        require(newStartTime != 0 && newEndTime != 0, "Reward time not set");
        require(_isRewardBalanceSufficient(token, newRewardPerSecond, newStartTime, newEndTime), "Insufficient reward balance");

        emit SetRewardParams(token, newRewardPerSecond, newStartTime, newEndTime);
    }

    /**
     * @dev Reclaim tokens that are not in use safely.
     */
    function reclaimToken(address token, address to) external onlyOwner {
        require(to != address(0), "Invalid to");

        uint256 amount = IERC20(token).balanceOf(address(this));

        RewardTokenData memory rewardData = rewardTokenData[token];
        // Remove remaining rewards from amount if it's a reward token.
        if (rewardData.isRewardToken) {
            amount -= _remainingRewards(
                rewardData.rewardPerSecond, rewardData.startTime, rewardData.endTime
            );
        }

        // Remove user funds from amount if it's share token.
        if (token == shareToken) {
            amount -= totalShare;
        }

        require(amount != 0, "No available token to reclaim");
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @dev Transfer tokens other than user funds to recipient.
     *
     * Be careful when use this to transfer funds as it may break reward emissions!
     */
    function transferToken(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Invalid to");

        if (token != shareToken) {
            IERC20(token).safeTransfer(to, amount);
        } else {
            uint256 maximum = IERC20(token).balanceOf(address(this)) - totalShare;
            uint256 spendable = Math.min(maximum, amount);
            require(spendable != 0, "No available token to transfer");
            IERC20(token).safeTransfer(to, spendable);
        }
    }

    /*//////////////////////////////////////////////////////////////
        Stake
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Updates enter time for given account based on weight of increased share.
     *
     * This is helpful for small share increases. For example, if user share
     * increased by 1%, it will adds only 1% of elapsed duration on his enter time.
     *
     * It won't update if less than `ENTER_TIME_GRACE_PERIOD` seconds since
     * last enter time update.
     *
     * It will use current time as enter time if:
     * - The user has never staked before.
     * - The new share is more than whole previous share.
     */
    function _updateEnterTimeWeighted(address account, uint256 newShare) internal {
        uint256 previousEnterTime = enterTime[account];

        if (previousEnterTime != 0) {
            uint256 sinceLastEnter = block.timestamp - previousEnterTime;
            if (sinceLastEnter < ENTER_TIME_GRACE_PERIOD) {
                return;
            }

            uint256 previousShare = userShare[account];
            if (previousShare != 0 && newShare < previousShare) {
                uint256 shareWeight = newShare * PRECISION / previousShare;
                uint256 durationWeighted = sinceLastEnter * shareWeight / PRECISION;
                enterTime[account] += durationWeighted;
                return;
            }
        }

        enterTime[account] = block.timestamp;
    }

    /**
     * @dev See {stake}.
     */
    function _stake(address from, uint256 amount, address onBehalf) internal {
        amount = _safeTransferFrom(shareToken, from, amount);

        if (feeRecipient != address(0)) {
            _updateEnterTimeWeighted(onBehalf, amount);
        }

        totalShare += amount;
        userShare[onBehalf] += amount;

        emit Stake(from, amount, onBehalf);
    }

    /**
     * @dev Stake share token in given amount.
     */
    function stake(uint256 amount, address onBehalf) external nonReentrant {
        require(amount != 0, "Cannot stake zero");

        // MUST update and accure ALL rewards because `totalShare` and `userShare` will changes.
        _updateAndAccrueAllRewards(onBehalf);
        _stake(msg.sender, amount, onBehalf);
    }

    /*//////////////////////////////////////////////////////////////
        Withdraw
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {withdraw}.
     */
    function _withdraw(address account, address token, uint256 amount, address to) internal {
        require(to != address(0), "Invalid to");

        totalShare -= amount;
        userShare[account] -= amount;

        // Charge early withdraw fee if possible.
        address _feeRecipient = feeRecipient;
        if (_feeRecipient != address(0)) {
            uint256 sinceLastStake = block.timestamp - enterTime[account];
            // If user staked before fee enabling, `enterTime` will be zero
            // thus won't met the condition.
            if (sinceLastStake < withdrawCooldown) {
                uint256 fee = amount * earlyWithdrawFeeRate / PRECISION;
                if (fee != 0) {
                    amount -= fee;
                    IERC20(token).safeTransfer(_feeRecipient, fee);
                }
            }
        }

        IERC20(token).safeTransfer(to, amount);
        emit Withdraw(account, amount, to);
    }

    /**
     * @dev Withdraw staked share token in given amount.
     */
    function withdraw(uint256 amount, address to) external nonReentrant {
        require(amount != 0, "Cannot withdraw zero");

        // MUST update and accure ALL rewards because `totalShare` and `userShare` will changes.
        _updateAndAccrueAllRewards(msg.sender);
        _withdraw(msg.sender, shareToken, amount, to);
    }

    /**
     * @dev Withdraw all staked share token without accuring rewards. EMERGENCY ONLY.
     *
     * This will discard pending rewards since last accrual.
     */
    function emergencyWithdraw(address to) external nonReentrant {
        _withdraw(msg.sender, shareToken, userShare[msg.sender], to);
    }

    /*//////////////////////////////////////////////////////////////
        Harvest
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {harvest}.
     */
    function _harvest(address account, address to) internal {
        require(to != address(0), "Invalid to");

        uint256 _len = rewardTokensLength();
        uint256 _totalShare = totalShare;
        uint256 _userShare = userShare[account];

        for (uint256 i = 0; i < _len; ) {
            address token = rewardTokens[i];
            uint256 _rewardPerShare = _updateRewardPerShare(token, _totalShare);
            _accrueReward(account, token, _rewardPerShare, _userShare);

            uint256 accruedRewards = userRewardData[token][account].accruedRewards;
            if (accruedRewards != 0) {
                userRewardData[token][account].accruedRewards = 0;
                IERC20(token).safeTransfer(to, accruedRewards);
                emit Harvest(account, token, accruedRewards, to);
            }

            unchecked { i++; }
        }
    }

    /**
     * @dev Update, accrue and send all rewards for given account.
     */
    function harvest(address account, address to) external nonReentrant {
        require(account == msg.sender || to == account, "No permission to set recipient");
        _harvest(account, to);
    }

    /**
     * @dev Harvest and withdraw staked share token in given amount.
     *
     * See {harvest} and {withdraw}.
     */
    function harvestAndWithdraw(uint256 amount, address to) external nonReentrant {
        require(amount != 0, "Cannot withdraw zero");

        _harvest(msg.sender, to);
        _withdraw(msg.sender, shareToken, amount, to);
    }

    /*//////////////////////////////////////////////////////////////
        MISC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Transfer given token from given address to current contract, supports fee-on-transfer.
     */
    function _safeTransferFrom(address token, address from, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        return IERC20(token).balanceOf(address(this)) - before;
    }
}