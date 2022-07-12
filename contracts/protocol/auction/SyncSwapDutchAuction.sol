// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import '../../libraries/security/ReentrancyGuard.sol';
import '../../libraries/access/Ownable.sol';
import '../../libraries/token/ERC20/utils/SafeERC20.sol';
import '../../interfaces/ERC20/IERC20.sol';

contract SyncSwapDutchAuction is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    address public immutable tokenForSale;
    uint256 public immutable totalAmountForSale;
    address public immutable tokenBid;

    uint256 public immutable startTime;
    uint256 public immutable endTime;
    uint256 public immutable reducePeriod;

    uint256 public immutable startPricePerShare;
    uint256 public immutable endPricePerShare;
    uint256 public immutable saleAmountPerShare;

    uint256 public amountMinBid;
    uint256 public totalAmountMinBid;
    bool public isClaimOpened;

    // States
    uint256 public totalAmountSold;
    uint256 public totalAmountBidPlaced;

    struct UserInfo {
        bool isClaimed;
        uint256 totalAmountBid;
        uint256 totalAmountSale;
        uint256 bidAmount;
    }

    struct Bid {
        uint256 amountBid;
        uint256 amountSale;
    }

    mapping(address => UserInfo) public userInfo;
    mapping(address => Bid[]) public userBids;

    constructor(
        address _tokenForSale,
        uint256 _totalAmountForSale,
        address _tokenBid,

        uint256 _amountMinBid,
        uint256 _totalAmountMinBid,

        uint256 _startTime,
        uint256 _endTime,
        uint256 _reducePeriod,

        uint256 _startPricePerShare,
        uint256 _endPricePerShare,
        uint256 _saleAmountPerShare
    ) {
        require(_tokenForSale != _tokenBid, "Identical tokens");
        require(IERC20(_tokenForSale).balanceOf(address(this)) != type(uint256).max, "Invalid sale token"); // sanity check
        tokenForSale = _tokenForSale;
        
        require(_totalAmountForSale > 0, "Invalid amount for sale");
        totalAmountForSale = _totalAmountForSale;

        require(IERC20(_tokenBid).balanceOf(address(this)) != type(uint256).max, "Invalid bid token"); // sanity check
        tokenBid = _tokenBid;

        amountMinBid = _amountMinBid;
        totalAmountMinBid = _totalAmountMinBid;

        require(_startTime > block.timestamp, "Invalid start time");
        require(_endTime > _startTime, "Invalid end time");
        startTime = _startTime;
        endTime = _endTime;
        reducePeriod = _reducePeriod;

        require(_startPricePerShare > 0, "Invalid start price");
        require(_endPricePerShare > 0, "Invalid end price");
        startPricePerShare = _startPricePerShare;
        endPricePerShare = _endPricePerShare;

        require(_saleAmountPerShare > 0, "Invalid amount per share");
        saleAmountPerShare = _saleAmountPerShare;
    }

    function setClaimOpened(bool _isClaimOpened) external onlyOwner {
        isClaimOpened = _isClaimOpened;
    }

    function setAmountMinBid(uint256 _amountMinBid) external onlyOwner {
        amountMinBid = _amountMinBid;
    }

    function setTotalAmountMinBid(uint256 _totalAmountMinBid) external onlyOwner {
        totalAmountMinBid = _totalAmountMinBid;
    }

    function transferERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid to");
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @dev Returns how many sale tokens remaining.
     */
    function remainingTokensForSale() external view returns (uint256) {
        return totalAmountForSale - totalAmountSold;
    }

    function getBidAmount(address account) external view returns (uint256) {
        return userInfo[account].bidAmount;
    }

    function getAllBids(address account) external view returns (Bid[] memory) {
        return userBids[account];
    }

    enum AuctionStatus {
        NOT_STARTED,
        ONGOING,
        SUCCEED_IN_ADVANCE,
        ENDED_AND_SUCCEED,
        ENDED_AND_NOT_SUCCEED
    }

    function getStatus() external view returns (AuctionStatus) {
        if (block.timestamp < startTime) {
            return AuctionStatus.NOT_STARTED;
        }

        if (totalAmountSold >= totalAmountForSale) {
            return AuctionStatus.SUCCEED_IN_ADVANCE;
        }

        if (block.timestamp > endTime) {
            if (totalAmountBidPlaced >= totalAmountMinBid) {
                return AuctionStatus.ENDED_AND_SUCCEED;
            } else {
                return AuctionStatus.ENDED_AND_NOT_SUCCEED;
            }
        } else {
            return AuctionStatus.ONGOING;
        }
    }

    /**
     * @dev Returns total amount of all cycles.
     */
    function totalCycles() public view returns (uint256) {
        uint256 _reducePeriod = reducePeriod;
        return _reducePeriod == 0 ? 1 : (endTime - startTime) / _reducePeriod;
    }

    /**
     * @dev Returns how many cycles has elapsed currently.
     */
    function elapsedCycles() public view returns (uint256) {
        uint256 _reducePeriod = reducePeriod;
        if (_reducePeriod == 0) {
            return 0;
        }
        uint256 _endTime = endTime;
        uint256 _lastTimeReduceApplicable = block.timestamp > _endTime ? _endTime : block.timestamp;
        uint256 _startTime = startTime;
        if (_lastTimeReduceApplicable <= _startTime) {
            // Not start yet.
            return 0;
        }
        uint256 _timeElapsed = _lastTimeReduceApplicable - _startTime;
        return _timeElapsed / _reducePeriod;
    }

    function currentCycle() external view returns (uint256) {
        uint256 _totalCycles = totalCycles();
        uint256 _elapsedCycles = elapsedCycles();
        return _elapsedCycles >= _totalCycles ? _elapsedCycles : _elapsedCycles + 1;
    }

    /**
     * @dev Returns reduction of price in every cycle.
     */
    function priceReductionPerCycle() public view returns (uint256) {
        uint256 _totalCycles = totalCycles();
        return _totalCycles == 0 ? 0 : (startPricePerShare - endPricePerShare) / _totalCycles;
    }

    /**
     * @dev Returns price of per share in the ucrrent cycle.
     */
    function currentPricePerShare() public view returns (uint256) {
        uint256 _elapsedCycles = elapsedCycles();
        uint256 _priceReduced;
        if (_elapsedCycles == 0) {
            _priceReduced = 0;
        } else {
            uint256 _totalCycles = totalCycles();
            uint256 _reduceCycles = _elapsedCycles == _totalCycles ? _elapsedCycles - 1 :_elapsedCycles;
            _priceReduced = priceReductionPerCycle() * _reduceCycles;
        }
        return startPricePerShare - _priceReduced;
    }

    function getPrice(uint256 _amountToBuy) public view returns (uint256) {
        return _amountToBuy * (currentPricePerShare() * 1e18 / saleAmountPerShare) / 1e18;
    }

    function getAmountToBuy(uint256 _amountBid) public view returns (uint256) {
        return _amountBid * saleAmountPerShare / currentPricePerShare();
    }

    function newBid(uint256 _amountBid, bool allowPartialFill) external nonReentrant {
        require(_amountBid >= amountMinBid, "Invalid amount");

        // Requires auction has started.
        require(block.timestamp >= startTime, "Not started");

        // Requires auction has not ended.
        require(block.timestamp < endTime, "Auction was over");

        uint256 _amountToBuy = getAmountToBuy(_amountBid);
        require(_amountToBuy > 0, "Amount to buy is too small");

        // Requires has enough sale tokens available.
        uint256 _leftover = totalAmountForSale - totalAmountSold;
        if (_leftover < _amountToBuy) {
            // Partially fills if possible.
            if (allowPartialFill) {
                require(_leftover > 0, "All tokens sold");
                _amountToBuy = _leftover;
                _amountBid = getPrice(_leftover);
            } else {
                revert("No enough tokens to fill");
            }
        }

        IERC20(tokenBid).safeTransferFrom(msg.sender, address(this), _amountBid);
        totalAmountBidPlaced += _amountBid;
        totalAmountSold += _amountToBuy;

        UserInfo storage user = userInfo[msg.sender];
        user.totalAmountBid += _amountBid;
        user.totalAmountSale += _amountToBuy;
        ++user.bidAmount;

        userBids[msg.sender].push(Bid({
            amountBid: _amountBid,
            amountSale: _amountToBuy
        }));
    }

    /**
     * @dev Returns whether auction has succeed and therefore sale tokens can be withdrawn.
     */
    function canClaim() public view returns (bool) {
        return (
            totalAmountSold >= totalAmountForSale || // All tokens has been sold before the auction end.
            (block.timestamp > endTime && totalAmountBidPlaced >= totalAmountMinBid) // Auction ended and greater than min bid requirement. 
        );
    }

    /**
     * @dev Claim sale tokens if auction has succeed.
     */
    function claim() external nonReentrant {
        require(canClaim(), "Cannot claim");
        require(isClaimOpened, "Claim not open");

        UserInfo memory _user = userInfo[msg.sender];
        require(!_user.isClaimed, "Already claimed");
        require(_user.totalAmountSale > 0, "No token to claim");

        userInfo[msg.sender].isClaimed = true;
        IERC20(tokenForSale).safeTransfer(msg.sender, _user.totalAmountSale);
    }

    /**
     * @dev Returns whether auction has failed and therefore bid tokens can be withdrawn.
     */
    function canWithdraw() public view returns (bool) {
        return (
            totalAmountSold < totalAmountForSale && // In case full bid < min bid // TODO check on set
            block.timestamp > endTime && totalAmountBidPlaced < totalAmountMinBid
        );
    }

    /**
     * @dev Withdraw bid tokens if auction has failed.
     */
    function withdraw() external nonReentrant {
        require(canWithdraw(), "Cannot withdraw");

        UserInfo memory _user = userInfo[msg.sender];
        require(!_user.isClaimed, "Already claimed");
        require(_user.totalAmountBid > 0, "No bid to withdraw");

        userInfo[msg.sender].isClaimed = true;
        IERC20(tokenBid).safeTransfer(msg.sender, _user.totalAmountBid);
    }
}