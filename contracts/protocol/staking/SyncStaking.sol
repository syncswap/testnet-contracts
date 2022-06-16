// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import '../../interfaces/ERC20/IERC20.sol';
import '../../interfaces/protocol/ISyncStaking.sol';

import '../../libraries/utils/Context.sol';
import '../../libraries/access/Ownable.sol';
import '../../libraries/security/ReentrancyGuard.sol';
import '../../libraries/token/ERC20/utils/SafeERC20.sol';

contract SyncStaking is ISyncStaking, Context, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Info of each user
    struct UserInfo {
        uint256 amount;
        mapping(IERC20 => uint256) rewardDebt;
        /**
         * @notice We do some fancy math here. Basically, any point in time, the amount of SYNCs
         * entitled to a user but is pending to be distributed is:
         *
         *   pending reward = (user.amount * accRewardPerShare) - user.rewardDebt[token]
         *
         * Whenever a user deposits or withdraws SYNC. Here's what happens:
         *   1. accRewardPerShare (and `lastRewardBalance`) gets updated
         *   2. User receives the pending reward sent to his/her address
         *   3. User's `amount` gets updated
         *   4. User's `rewardDebt[token]` gets updated
         */
    }

    IERC20 public override token;

    /// @dev Internal balance of SYNC, this gets updated on user deposits / withdrawals
    /// this allows to reward users with SYNC
    uint256 public override depositBalance;
    /// @notice Array of tokens that users can claim
    IERC20[] public override rewardTokens;
    mapping(IERC20 => bool) public override isRewardToken;
    /// @notice Last reward balance of `token`
    mapping(IERC20 => uint256) public lastRewardBalance;

    address public override feeCollector;

    /// @notice The deposit fee, scaled to `DEPOSIT_FEE_PERCENT_PRECISION`
    uint256 public override depositFeePercent;
    /// @notice The precision of `depositFeePercent`
    uint256 public DEPOSIT_FEE_PERCENT_PRECISION = 1e18;

    /// @notice Accumulated `token` rewards per share, scaled to `ACC_REWARD_PER_SHARE_PRECISION`
    mapping(IERC20 => uint256) public accRewardPerShare;
    /// @notice The precision of `accRewardPerShare`
    uint256 public ACC_REWARD_PER_SHARE_PRECISION = 1e24;

    /// @dev Info of each user that stakes SYNC
    mapping(address => UserInfo) private userInfo;

    /// @dev Duration of periods, used to track APRs
    uint256 public constant PERIOD_DURATION = 7 days;
    /// @dev Accumulated reward per share in last period, used to track APRs
    mapping(IERC20 => uint256) public lastPeriodRewardPerShare;
    /// @dev Start timestamp of current period, used to track APRs
    mapping(IERC20 => uint256) public currentPeriodStart;
    /// @dev Accumulated reward per share in current period, used to track APRs
    mapping(IERC20 => uint256) public currentPeriodRewardPerShare;

    /**
     * @notice Initialize a new contract
     * @dev This contract needs to receive an ERC20 `_rewardToken` in order to distribute them
     * (with MoneyMaker in our case)
     * @param _rewardToken The address of the ERC20 reward token
     * @param _sync The address of the SYNC token
     * @param _feeCollector The address where deposit fees will be sent
     * @param _depositFeePercent The deposit fee percent, scalled to 1e18, e.g. 3% is 3e16
     */
    constructor(
        IERC20 _rewardToken,
        IERC20 _sync,
        address _feeCollector,
        uint256 _depositFeePercent
    ) Ownable() {
        require(address(_rewardToken) != address(0), "SyncSwapStaking: reward token can't be address(0)");
        require(address(_sync) != address(0), "SyncSwapStaking: sync can't be address(0)");
        require(_feeCollector != address(0), "SyncSwapStaking: fee collector can't be address(0)");
        require(_depositFeePercent <= 5e17, "SyncSwapStaking: max deposit fee can't be greater than 50%");

        token = _sync;
        depositFeePercent = _depositFeePercent;
        feeCollector = _feeCollector;

        isRewardToken[_rewardToken] = true;
        rewardTokens.push(_rewardToken);
    }

    // ------------------------------
    //  Management Functions
    // ------------------------------

    /**
     * @notice Set the fee collector address
     * @param _collector The new fee collector address
     */
    function setFeeCollector(address _collector) external onlyOwner {
        require(_collector != address(0), "SyncSwapStaking: fee collector can't be address(0)");
        feeCollector = _collector;
    }

    /**
     * @notice Set the deposit fee percent
     * @param _depositFeePercent The new deposit fee percent
     */
    function setDepositFeePercent(uint256 _depositFeePercent) external onlyOwner {
        require(_depositFeePercent <= 5e17, "SyncSwapStaking: deposit fee can't be greater than 50%");
        uint256 oldFee = depositFeePercent;
        depositFeePercent = _depositFeePercent;
        emit DepositFeeChanged(_depositFeePercent, oldFee);
    }

    /**
     * @notice Add a reward token
     * @param _rewardToken The address of the reward token
     */
    function addRewardToken(IERC20 _rewardToken) external onlyOwner {
        require(address(_rewardToken) != address(0), "SyncSwapStaking: invalid token address");
        require(!isRewardToken[_rewardToken], "SyncSwapStaking: duplicate token");
        require(rewardTokens.length < 25, "SyncSwapStaking: list of token too big");
        rewardTokens.push(_rewardToken);
        isRewardToken[_rewardToken] = true;
        updateReward(_rewardToken);
        emit RewardTokenAdded(address(_rewardToken));
    }

    /**
     * @notice Remove a reward token
     * @param _rewardToken The address of the reward token
     */
    function removeRewardToken(IERC20 _rewardToken) external onlyOwner {
        require(isRewardToken[_rewardToken], "SyncSwapStaking: token is not reward");
        updateReward(_rewardToken);
        isRewardToken[_rewardToken] = false;
        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            if (rewardTokens[i] == _rewardToken) {
                rewardTokens[i] = rewardTokens[_len - 1];
                rewardTokens.pop();
                break;
            }
        }
        emit RewardTokenRemoved(address(_rewardToken));
    }

    // ------------------------------
    //  View Functions
    // ------------------------------

    /**
     * @notice Get user info
     * @param _user The address of the user
     * @param _rewardToken The address of the reward token
     * @return The amount of SYNC user has deposited
     * @return The reward debt for the chosen token
     */
    function getUserInfo(address _user, IERC20 _rewardToken) external view override returns (uint256, uint256) {
        UserInfo storage user = userInfo[_user];
        return (user.amount, user.rewardDebt[_rewardToken]);
    }

    /**
     * @notice Get the number of reward tokens
     * @return The length of the array
     */
    function rewardTokensLength() external view override returns (uint256) {
        return rewardTokens.length;
    }

    /**
     * @notice View function to see pending reward token on frontend
     * @param _user The address of the user
     * @param _token The address of the token
     * @return `_user`'s pending reward token
     */
    function pendingReward(address _user, IERC20 _token) external view override returns (ISyncStaking.PendingReward memory) {
        require(isRewardToken[_token], "SyncSwapStaking: wrong reward token");
        UserInfo storage user = userInfo[_user];
        uint256 _totalSync = depositBalance;
        uint256 _accRewardTokenPerShare = accRewardPerShare[_token];

        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == token ? (_currRewardBalance - _totalSync) : _currRewardBalance;

        if (_rewardBalance != lastRewardBalance[_token] && _totalSync != 0) {
            uint256 _accruedReward = _rewardBalance - lastRewardBalance[_token];

            _accRewardTokenPerShare = _accRewardTokenPerShare + (
                _accruedReward * ACC_REWARD_PER_SHARE_PRECISION / _totalSync
            );
        }

        return PendingReward({
            rewardToken: address(_token),
            pendingReward: (user.amount * _accRewardTokenPerShare / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt[_token],
            lastPeriodRewardPerShare: lastPeriodRewardPerShare[_token],
            currentPeriodRewardPerShare: currentPeriodRewardPerShare[_token],
            currentPeriodDuration: block.timestamp - currentPeriodStart[_token]
        });
    }

    function allPendingRewards(address _user) public view returns (ISyncStaking.PendingReward[] memory _pendingRewards) {
        uint256 _len = rewardTokens.length;
        _pendingRewards = new PendingReward[](_len);

        UserInfo storage user = userInfo[_user];
        uint256 _totalSync = depositBalance;

        for (uint256 i = 0; i < _len; i++) {
            IERC20 _token = IERC20(rewardTokens[i]);
            uint256 _accRewardTokenPerShare = accRewardPerShare[_token];
            uint256 _currRewardBalance = _token.balanceOf(address(this));
            uint256 _rewardBalance = _token == token ? (_currRewardBalance - _totalSync) : _currRewardBalance;

            if (_rewardBalance != lastRewardBalance[_token] && _totalSync != 0) {
                uint256 _accruedReward = _rewardBalance - lastRewardBalance[_token];

                _accRewardTokenPerShare = _accRewardTokenPerShare + (
                    _accruedReward * ACC_REWARD_PER_SHARE_PRECISION / _totalSync
                );
            }

            _pendingRewards[i] = PendingReward({
                rewardToken: address(_token),
                pendingReward: (user.amount * _accRewardTokenPerShare / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt[_token],
                lastPeriodRewardPerShare: lastPeriodRewardPerShare[_token],
                currentPeriodRewardPerShare: currentPeriodRewardPerShare[_token],
                currentPeriodDuration: block.timestamp - currentPeriodStart[_token]
            });
        }
    }

    function summary(address _user) external view returns (
        uint256 _depositFeePercent,
        uint256 _totalDeposit,
        uint256 _userDeposit,
        uint256 _userBalance,
        uint256 _userAllowance,
        ISyncStaking.PendingReward[] memory _pendingRewards
    ) {
        _depositFeePercent = depositFeePercent;
        _totalDeposit = depositBalance;
        _userDeposit = userInfo[_user].amount;
        _userBalance = token.balanceOf(_user);
        _userAllowance = token.allowance(_user, address(this));
        _pendingRewards = allPendingRewards(_user);
    }

    // ------------------------------
    //  External Functions
    // ------------------------------

    /**
     * @notice Update reward variables
     * @param _token The address of the reward token
     * @dev Needs to be called before any deposit or withdrawal
     */
    function updateReward(IERC20 _token) public override {
        require(isRewardToken[_token], "SyncSwapStaking: wrong reward token");

        uint256 _totalSync = depositBalance;

        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == token ? (_currRewardBalance - _totalSync) : _currRewardBalance;

        // Did we receive any token?
        if (_rewardBalance == lastRewardBalance[_token] || _totalSync == 0) {
            return;
        }

        uint256 _accruedReward = _rewardBalance - lastRewardBalance[_token];
        uint256 _accruedRewardPerShare = _accruedReward * ACC_REWARD_PER_SHARE_PRECISION / _totalSync;

        accRewardPerShare[_token] += _accruedRewardPerShare;
        lastRewardBalance[_token] = _rewardBalance;

        // Track APRs
        _updatePeriod(_accruedRewardPerShare);
    }

    function _updatePeriod(uint256 _accruedRewardPerShare) private {
        uint256 _currentPeriodStart = currentPeriodStart[token];

        if (_currentPeriodStart != 0 && block.timestamp - _currentPeriodStart < PERIOD_DURATION) {
            // Accumulate reward per share
            currentPeriodRewardPerShare[token] += _accruedRewardPerShare;
        } else {
            // Starts a new period
            uint256 _currentRewardPerShare = currentPeriodRewardPerShare[token];
            if (_currentRewardPerShare != 0) {
                lastPeriodRewardPerShare[token] = _currentRewardPerShare;
            }
            
            currentPeriodStart[token] = block.timestamp;
            currentPeriodRewardPerShare[token] = _accruedRewardPerShare;
        }
    }

    /**
     * @notice Safe token transfer function, just in case if rounding error
     * causes pool to not have enough reward tokens
     * @param _token The address of then token to transfer
     * @param _to The address that will receive `_amount` `rewardToken`
     * @param _amount The amount to send to `_to`
     */
    function _safeTransferReward(
        IERC20 _token,
        address _to,
        uint256 _amount
    ) internal {
        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == token ? (_currRewardBalance - depositBalance) : _currRewardBalance;

        if (_amount > _rewardBalance) {
            lastRewardBalance[_token] -= _rewardBalance;
            _token.safeTransfer(_to, _rewardBalance);
        } else {
            lastRewardBalance[_token] -= _amount;
            _token.safeTransfer(_to, _amount);
        }
    }

    /**
     * @notice Deposit SYNC for reward token allocation
     * @param _amount The amount of SYNC to deposit
     */
    function deposit(uint256 _amount) external override nonReentrant {
        UserInfo storage user = userInfo[_msgSender()];

        uint256 _fee = _amount * depositFeePercent / DEPOSIT_FEE_PERCENT_PRECISION;
        uint256 _amountMinusFee = _amount - _fee;

        uint256 _previousAmount = user.amount;
        uint256 _newAmount = user.amount + _amountMinusFee;
        user.amount = _newAmount;

        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            IERC20 _token = rewardTokens[i];
            updateReward(_token);

            uint256 _previousRewardDebt = user.rewardDebt[_token];
            user.rewardDebt[_token] = _newAmount * accRewardPerShare[_token] / ACC_REWARD_PER_SHARE_PRECISION;

            if (_previousAmount != 0) {
                uint256 _pending = (_previousAmount * accRewardPerShare[_token] / ACC_REWARD_PER_SHARE_PRECISION) - _previousRewardDebt;
                if (_pending != 0) {
                    _safeTransferReward(_token, _msgSender(), _pending);
                    emit ClaimReward(_msgSender(), address(_token), _pending);
                }
            }
        }

        depositBalance += _amountMinusFee;
        if (_fee != 0) {
            token.safeTransferFrom(_msgSender(), feeCollector, _fee);
        }
        if (_amountMinusFee != 0) {
            token.safeTransferFrom(_msgSender(), address(this), _amountMinusFee);
        }
        emit Deposit(_msgSender(), _amountMinusFee, _fee);
    }

    /**
     * @notice Withdraw SYNC and harvest the rewards
     * @param _amount The amount of SYNC to withdraw
     */
    function withdraw(uint256 _amount) external override nonReentrant {
        UserInfo storage user = userInfo[_msgSender()];
        uint256 _previousAmount = user.amount;
        require(_amount <= _previousAmount, "SyncSwapStaking: withdraw amount exceeds balance");
        uint256 _newAmount = user.amount - _amount;
        user.amount = _newAmount;

        uint256 _len = rewardTokens.length;
        if (_previousAmount != 0) {
            for (uint256 i; i < _len; i++) {
                IERC20 _token = rewardTokens[i];
                updateReward(_token);

                uint256 _pending = (_previousAmount * accRewardPerShare[_token] / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt[_token];
                user.rewardDebt[_token] = _newAmount * accRewardPerShare[_token] / ACC_REWARD_PER_SHARE_PRECISION;

                if (_pending != 0) {
                    _safeTransferReward(_token, _msgSender(), _pending);
                    emit ClaimReward(_msgSender(), address(_token), _pending);
                }
            }
        }

        depositBalance -= _amount;
        token.safeTransfer(_msgSender(), _amount);
        emit Withdraw(_msgSender(), _amount);
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY
     */
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[_msgSender()];

        uint256 _amount = user.amount;
        user.amount = 0;
        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            IERC20 _token = rewardTokens[i];
            user.rewardDebt[_token] = 0;
        }
        depositBalance -= _amount;
        token.safeTransfer(_msgSender(), _amount);
        emit EmergencyWithdraw(_msgSender(), _amount);
    }
}