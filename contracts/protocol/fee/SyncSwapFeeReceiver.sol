// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import '../../interfaces/ERC20/IERC20.sol';
import '../../interfaces/protocol/ISyncSwapFeeReceiver.sol';
import '../../interfaces/protocol/core/ISyncSwapPair.sol';

import '../../libraries/access/Ownable.sol';
import '../../libraries/security/ReentrancyGuard.sol';
import '../../libraries/protocol/SyncSwapLibrary.sol';
import '../../libraries/token/ERC20/utils/TransferHelper.sol';

contract SyncSwapFeeReceiver is ISyncSwapFeeReceiver, Ownable, ReentrancyGuard {
    using TransferHelper for address;

    /// @dev Precision for fee rates and bounty rates
    uint256 public constant PRECISION = 1e18;

    /// @dev Address of associated factory
    address public immutable factory;

    // ----- Distribution -----

    struct Distribution {
        address to;
        uint256 share;
    }

    /// @dev Configurations for protocol fee distribution
    Distribution[] public distributions;

    // ----- Swap -----

    /// @dev Default price impact tolerance for swap
    uint256 public swapMaxPriceImpact = 1e17; // 10%

    /// @dev Destination token of swap conversion
    address public swapDestinationToken;

    /// @dev Path token to swap as inout<>path<>dest
    address public swapPathToken;

    /// @dev Token to bridge liquidity as input<>bridge<>path<>dest
    mapping(address => address) public swapBridgeTokenOverrides;

    /// @dev Ignored price impact for tokens
    mapping(address => bool) public swapPriceImpactOverrides;

    // ----- Executor -----

    /// @dev Bounty rate for executor on top of converted
    uint256 public executorBountyRate = 1e15; // 0.1%

    /// @dev Allowed executors when restriction is enabled
    mapping(address => bool) public allowedExecutors;

    /// @dev Whether conversion execution is restricted
    bool public executorRestricted = false;

    event Distribute(address indexed executor, uint256 convertedAmount, uint256 bountyAmount);

    constructor(address _factory) Ownable() {
        require(_factory != address(0), "SyncSwapFeeManager: invalid factory address");
        factory = _factory;
    }

    /*//////////////////////////////////////////////////////////////
        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setDistributions(address[] calldata recipients, uint256[] calldata shares) external onlyOwner {
        require(recipients.length == shares.length, "SyncSwapFeeManager: inconsistent length");
        delete distributions;

        uint256 totalShare = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 share = shares[i];
            distributions.push(Distribution({
                to: recipients[i],
                share: share
            }));
            totalShare += share;
        }
        require(totalShare == PRECISION, "SyncSwapFeeManager: total share must equal to precision");
    }

    function distributionsLength() external view returns (uint256) {
        return distributions.length;
    }

    function getDistributions() external view returns (Distribution[] memory) {
        return distributions;
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
    }

    // ----- Swap -----

    modifier ensureTokenValid(address token) {
        require(token != address(0), "SyncSwapFeeManager: invalid token address");
        require(IERC20(token).balanceOf(address(this)) != type(uint).max, "SyncSwapFeeManager: not a token");
        _;
    }

    function setSwapMaxPriceImpact(uint256 newMaxImpact) external onlyOwner {
        require(newMaxImpact <= PRECISION, "SyncSwapFeeManager: invalid price impact tolerance");
        swapMaxPriceImpact = newMaxImpact;
    }

    function setSwapPriceImpactOverrideFor(address token, bool shouldOverride) external onlyOwner ensureTokenValid(token) {
        swapPriceImpactOverrides[token] = shouldOverride;
    }

    function setSwapDestinationToken(address newDestinationToken) external onlyOwner ensureTokenValid(newDestinationToken) {
        require(newDestinationToken != swapPathToken, "SyncSwapFeeManager: path and dest cannot be identical");
        swapDestinationToken = newDestinationToken;
    }

    function setSwapPathToken(address newPathToken) external onlyOwner ensureTokenValid(newPathToken) {
        require(newPathToken != swapDestinationToken, "SyncSwapFeeManager: path and dest cannot be identical");
        swapPathToken = newPathToken;
    }

    function setSwapBridgeTokenOverrideFor(address token, address bridge) external onlyOwner ensureTokenValid(token) ensureTokenValid(bridge) {
        require(token != bridge, "SyncSwapFeeManager: identical token");
        swapBridgeTokenOverrides[token] = bridge;
    }

    function resetSwapBridgeTokenOverrideFor(address token) external onlyOwner ensureTokenValid(token) {
        delete swapBridgeTokenOverrides[token];
    }

    // ----- Executor -----

    function setExecutorBountyRate(uint256 newRate) external onlyOwner {
        require(newRate <= PRECISION, "SyncSwapFeeManager: invalid bounty rate");
        executorBountyRate = newRate;
    }

    function toggleExecutorRestriction() external onlyOwner {
        executorRestricted = !executorRestricted;
    }

    function setExecutorAllowance(address account, bool allowed) external onlyOwner {
        allowedExecutors[account] = allowed;
    }

    /*//////////////////////////////////////////////////////////////
        IMPLEMENTATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function convertTokensAndDistribute(address[] calldata tokens0, address[] calldata tokens1) external override nonReentrant returns (uint256 converted, uint256 bounty) {
        require(tokens0.length == tokens1.length, "SyncSwapFeeManager: inconsistent length");

        ISyncSwapFactory _factory = ISyncSwapFactory(factory);
        address[] memory pairs = new address[](tokens0.length);
        for (uint256 i; i < tokens0.length; i++) {
            address pair = _factory.getPair(tokens0[i], tokens1[i]);
            require(pair != address(0), "SyncSwapFeeManager: pair not exists");
            pairs[i] = pair;
        }

        return _convertAndDistribute(pairs);
    }

    function convertAndDistribute(address[] calldata pairs) external override nonReentrant returns (uint256 converted, uint256 bounty) {
        return _convertAndDistribute(pairs);
    }

    function _convertAndDistribute(address[] memory pairs) private returns (uint256 converted, uint256 bounty) {
        require(pairs.length != 0, "SyncSwapFeeManager: no pair to convert");
        require(!executorRestricted || allowedExecutors[msg.sender] || msg.sender == owner(), "SyncSwapFeeManager: no perms to convert");

        address _factory = factory;
        address tokenPath = swapPathToken;
        require(tokenPath != address(0), "SyncSwapFeeManager: path token not set");
        address tokenDest = swapDestinationToken;
        require(tokenDest != address(0), "SyncSwapFeeManager: dest token not set");

        // This MUST be defined here as we can withdraw dest tokens
        uint256 destBalanceBefore = IERC20(tokenDest).balanceOf(address(this));

        // Withdraw all liquidity
        for (uint256 i; i < pairs.length; i++) {
            ISyncSwapPair pair = ISyncSwapPair(pairs[i]);
            require(ISyncSwapFactory(_factory).isPair(address(pair)), "SyncSwapFeeManager: invalid pair");

            uint256 balance = pair.balanceOf(address(this));
            if (balance != 0) {
                pair.transfer(address(pair), balance);
                pair.burn(address(this));
            }
        }

        uint256 maxPriceImpact = swapMaxPriceImpact;

        // Swap from various tokens to path token
        for (uint256 i; i < pairs.length; i++) {
            ISyncSwapPair pair = ISyncSwapPair(pairs[i]);
            (address token0, address token1) = (pair.token0(), pair.token1());

            _tryConvertToken(_factory, token0, tokenPath, tokenDest, maxPriceImpact);
            _tryConvertToken(_factory, token1, tokenPath, tokenDest, maxPriceImpact);
        }

        // Swap from path token to dest token
        uint256 pathBalance = IERC20(tokenPath).balanceOf(address(this));
        if (pathBalance != 0) {
            _swapFor(_factory, tokenPath, tokenDest, pathBalance, maxPriceImpact);
        }

        // Compare to see how many dest tokens we received
        converted = IERC20(tokenDest).balanceOf(address(this)) - destBalanceBefore;
        if (converted == 0) {
            return (0, 0);
        }

        // Distribute received dest tokens
        bounty = converted * executorBountyRate / PRECISION;
        _distribute(tokenDest, converted - bounty);

        if (bounty != 0) {
            tokenDest.safeTransfer(msg.sender, bounty);
        }

        emit Distribute(msg.sender, converted, bounty);
    }

    function _distribute(address tokenDest, uint256 amount) private {
        if (amount != 0) {
            uint256 len = distributions.length;
            require(len != 0, "SyncSwapFeeManager: distributions are not set");

            for (uint256 i = 0; i < len; i++) {
                Distribution memory dist = distributions[i];
                uint256 amountFor = amount * dist.share / PRECISION;

                if (amountFor != 0) {
                    tokenDest.safeTransfer(dist.to, amountFor);
                }
            }
        }
    }

    function _tryConvertToken(address _factory, address tokenIn, address tokenPath, address tokenDest, uint256 _maxPriceImpact) private {
        if (tokenIn == tokenPath || tokenIn == tokenDest) {
            return;
        }
        uint256 balance = IERC20(tokenIn).balanceOf(address(this));
        if (balance == 0) {
            return;
        }

        address tokenBridge = swapBridgeTokenOverrides[tokenIn];

        // Swap for `tokenPath` if no bridge, or bridge is `tokenPath`
        if (tokenBridge == address(0) || tokenBridge == tokenPath) {
            _swapFor(_factory, tokenIn, tokenPath, balance, _maxPriceImpact);
            return;
        }

        // Swap for `tokenDest` if bridge is `tokenDest`, indicates explicitly direct swap
        if (tokenBridge == tokenDest) {
            _swapFor(_factory, tokenIn, tokenDest, balance, _maxPriceImpact);
            return;
        }

        // Two-step swap for bridge, and for `tokenPath`
        _swapFor(_factory, tokenIn, tokenBridge, balance, _maxPriceImpact);
        _swapFor(_factory, tokenBridge, tokenPath, IERC20(tokenBridge).balanceOf(address(this)), _maxPriceImpact);
    }

    // ---------- Swap ----------

    function _getAmountOut(address _factory, address tokenIn, address tokenOut, uint amountIn, uint256 maxPriceImpact) internal view returns (uint) {
        (uint112 reserveIn, uint112 reserveOut, uint16 swapFee) = SyncSwapLibrary.getReserves(_factory, tokenIn, tokenOut);
        require(reserveIn != 0 && reserveOut != 0, "SyncSwapFeeManager: pair reserve is zero");
        require(
            maxPriceImpact == type(uint256).max || amountIn * PRECISION / (reserveIn) <= maxPriceImpact,
            "SyncSwapFeeManager: price impact too high"
        );

        return SyncSwapLibrary.getAmountOut(amountIn, reserveIn, reserveOut, swapFee);
    }

    /// @dev Swap `tokenIn` in given amount for `tokenOut`
    function _swapFor(address _factory, address tokenIn, address tokenOut, uint256 amountIn, uint256 maxPriceImpact) private {
        require(amountIn != 0, "SyncSwapFeeManager: swap input amount is zero");
        require(tokenIn != tokenOut, "SyncSwapFeeManager: identical tokens to swap");

        // Quote for price
        uint256 _maxPriceImpact = swapPriceImpactOverrides[tokenIn] ? type(uint256).max : maxPriceImpact;
        uint256 amountOut = _getAmountOut(_factory, tokenIn, tokenOut, amountIn, _maxPriceImpact);
        require(amountOut != 0, "SyncSwapFeeManager: swap output amount is zero");

        // Perform swap
        address pair = ISyncSwapFactory(_factory).getPair(tokenIn, tokenOut);
        TransferHelper.safeTransfer(tokenIn, pair, amountIn);
        if (tokenIn < tokenOut) { // whether `tokenIn` is `token0`
            ISyncSwapPair(pair).swapFor1(amountOut, address(this));
        } else {
            ISyncSwapPair(pair).swapFor0(amountOut, address(this));
        }
    }
}
