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

    /// @dev Precision for fee rate.
    uint256 public constant PRECISION = 1e18;

    /// @dev Address of associated factory.
    address public immutable factory;

    /// @dev Token to swap for (e.g. the protocol token).
    address public immutable swapFor;

    struct Distribution {
        address to;
        uint256 share;
    }

    /// @dev Configurations for protocol fee distribution.
    Distribution[] public distributions;

    /// @dev Default price impact tolerance for swaps.
    uint256 public swapMaxPriceImpact = 1e17; // 10%

    /// @dev Common base token for swap (input<>commonBase<>swapFor).
    address public swapCommonBase;

    /// @dev Path for swap (overriding `swapCommonBase`).
    mapping(address => address[]) public swapPathOverrides;

    /// @dev Allowed executors when restriction is enabled.
    mapping(address => bool) public allowedExecutors;

    /// @dev Whether execution is restricted.
    bool public executorRestricted = true;

    constructor(address _factory, address _swapFor) {
        require(_factory != address(0), "Invalid factory");
        require(_swapFor != address(0), "Invalid swap for");
        factory = _factory;
        swapFor = _swapFor;
    }

    /*//////////////////////////////////////////////////////////////
        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function distributionsLength() external view returns (uint256) {
        return distributions.length;
    }

    function getDistributions() external view returns (Distribution[] memory) {
        return distributions;
    }

    /*//////////////////////////////////////////////////////////////
        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setDistributions(address[] calldata _recipients, uint256[] calldata _shares) external onlyOwner {
        require(_recipients.length == _shares.length, "Inconsistent parameters");

        // Delete previous distributions.
        delete distributions;

        uint256 _totalShare = 0;
        for (uint256 i = 0; i < _recipients.length; ) {
            uint256 _share = _shares[i];

            distributions.push(Distribution({
                to: _recipients[i],
                share: _share
            }));
            _totalShare += _share;

            unchecked {
                ++i;
            }
        }

        require(_totalShare == PRECISION, "Total share must equals to the precision");
    }

    function rescueERC20(address _token, address _to, uint256 _amount) external onlyOwner {
        _token.safeTransfer(_to, _amount);
    }

    function setSwapMaxPriceImpact(uint256 _swapMaxPriceImpact) external onlyOwner {
        require(_swapMaxPriceImpact <= PRECISION, "Invalid price impact");
        swapMaxPriceImpact = _swapMaxPriceImpact;
    }

    function setSwapCommonBase(address _swapCommonBase) external onlyOwner {
        require(_swapCommonBase != address(0), "Invalid token");
        swapCommonBase = _swapCommonBase;
    }

    function setSwapPathOverrides(address _token, address[] memory _swapPathOverrides) external onlyOwner {
        if (_swapPathOverrides.length != 0) {
            require(_swapPathOverrides[0] == _token && _swapPathOverrides[_swapPathOverrides.length - 1] == swapFor, "Invalid path");
            for (uint256 i = 0; i < _swapPathOverrides.length; ) {
                require(_swapPathOverrides[i] != address(0), "Invalid token in path");
                unchecked {
                    ++i;
                }
            }
        }
        swapPathOverrides[_token] = _swapPathOverrides;
    }

    function setExecutorRestricted(bool _executorRestricted) external onlyOwner {
        executorRestricted = _executorRestricted;
    }

    function setExecutorAllowance(address _account, bool _isAllowed) external onlyOwner {
        allowedExecutors[_account] = _isAllowed;
    }

    /*//////////////////////////////////////////////////////////////
        USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    modifier onlyExecutors() {
        require(!executorRestricted || allowedExecutors[msg.sender] || msg.sender == owner(), "Not executor");
        _;
    }

    function swapAndDistributeWithTokens(address[] calldata _tokens0, address[] calldata _tokens1) external override nonReentrant onlyExecutors returns (uint256) {
        require(_tokens0.length == _tokens1.length, "Inconsistent token length");

        ISyncSwapFactory _factory = ISyncSwapFactory(factory);
        address[] memory _pairs = new address[](_tokens0.length);

        for (uint256 i = 0; i < _tokens0.length; ) {
            address _pair = _factory.getPair(_tokens0[i], _tokens1[i]);
            require(_pair != address(0), "Pair not exists");

            _pairs[i] = _pair;

            unchecked {
                ++i;
            }
        }

        return _swapAndDistribute(address(_factory), _pairs);
    }

    function swapAndDistribute(address[] calldata _pairs) external override nonReentrant onlyExecutors returns (uint256) {
        return _swapAndDistribute(factory, _pairs);
    }

    function _burnPair(address _factory, address _pairAddress) internal {
        require(ISyncSwapFactory(_factory).isPair(_pairAddress), "Invalid pair");

        ISyncSwapPair _pair = ISyncSwapPair(_pairAddress);
        uint256 _pairBalance = _pair.balanceOf(address(this));
        if (_pairBalance != 0) {
            _pair.transfer(_pairAddress, _pairBalance);
            _pair.burn(address(this));
        }
    }

    function _burnPairs(address _factory, address[] memory _pairAddresses) internal {
        for (uint256 i = 0; i < _pairAddresses.length; ) {
            _burnPair(_factory, _pairAddresses[i]);

            unchecked {
                ++i;
            }
        }
    }

    function _swapAndDistribute(address _factory, address[] memory _pairs) internal returns (uint256 amountOut) {
        require(_pairs.length != 0, "No pair to swap");

        address _swapCommonBase = swapCommonBase;
        require(_swapCommonBase != address(0), "No swap common base");

        address _swapFor = swapFor;
        require(_swapFor != address(0), "No swap for");

        // This MUST be defined here as we can withdraw `swapFor` tokens.
        uint256 _swapForBalanceBefore = IERC20(_swapFor).balanceOf(address(this));

        // Burn all pairs to withdraw pool tokens.
        _burnPairs(_factory, _pairs);

        // Swap from pool tokens to common base (default) or `swapFor` (with path overrides).
        uint256 _maxPriceImpact = swapMaxPriceImpact;
    
        for (uint256 i = 0; i < _pairs.length; ) {
            ISyncSwapPair _pair = ISyncSwapPair(_pairs[i]);
            (address _token0, address _token1) = (_pair.token0(), _pair.token1());

            _trySwapPoolToken(_factory, _token0, _swapCommonBase, _swapFor, _maxPriceImpact, address(this));
            _trySwapPoolToken(_factory, _token1, _swapCommonBase, _swapFor, _maxPriceImpact, address(this));

            unchecked {
                ++i;
            }
        }

        // Swap from common base to `swapFor`.
        uint256 _commonBaseBalance =  IERC20(_swapCommonBase).balanceOf(address(this));
        if (_commonBaseBalance != 0) {
            _trySwapDirect(_factory, _swapCommonBase, _swapFor, _commonBaseBalance, _maxPriceImpact, address(this));
        }

        // Send tokens to recipients.
        amountOut = IERC20(_swapFor).balanceOf(address(this)) - _swapForBalanceBefore;
        if (amountOut != 0) {
            _distribute(_swapFor, amountOut);
        }

        return amountOut;
    }

    /**
     * @dev Distribute given amount of the token to recipients.
     */
    function _distribute(address _token, uint256 _amount) internal {
        uint256 _length = distributions.length;
        require(_length != 0, "No distribution");

        for (uint256 i = 0; i < _length; ) {
            Distribution memory _distribution = distributions[i];
            uint256 _amountFor = _amount * _distribution.share / PRECISION;

            if (_amountFor != 0) {
                _token.safeTransfer(_distribution.to, _amountFor);
            }

            unchecked {
                ++i;
            }
        }

        emit Distribute(_amount);
    }

    function _trySwapPoolToken(address _factory, address _token, address _swapCommonBase, address _swapFor, uint256 _maxPriceImpact, address _to) internal {
        // Skips when unnecessary.
        if (_token == _swapCommonBase || _token == _swapFor) {
            return;
        }

        // Skips if no balance to swap.
        uint256 _balance = IERC20(_token).balanceOf(address(this));
        if (_balance == 0) {
            return;
        }

        // Skips if token is a pair.
        if (ISyncSwapFactory(_factory).isPair(_token)) {
            return;
        }

        address[] memory _swapPathOverrides = swapPathOverrides[_token];
        if (_swapPathOverrides.length == 0) {
            // No path overrides, swap to common base
            _trySwapDirect(_factory, _token, _swapCommonBase, _balance, _maxPriceImpact, _to);
        } else {
            // Use path overrides
            _swapExactTokensForTokens(_factory, _balance, _swapPathOverrides, _maxPriceImpact, _to);
        }
    }

    function _trySwapDirect(address _factory, address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _maxPriceImpact, address _to) internal {
        if (_amountIn == 0 || _tokenIn == _tokenOut) {
            return;
        }

        uint256 _amountOut = _getAmountOut(_factory, _tokenIn, _tokenOut, _amountIn, _maxPriceImpact);
        if (_amountOut == 0) {
            return;
        }

        address _pair = ISyncSwapFactory(_factory).getPair(_tokenIn, _tokenOut);
        if (_pair == address(0)) {
            return;
        }

        _tokenIn.safeTransfer(_pair, _amountIn);
        _invokeSwap(_pair, _amountOut, _tokenIn, _tokenOut, _to);
    }

    // Belows are copied from router and modified to support chained swaps with price impact limits.
    function _getAmountOut(address _factory, address _tokenIn, address _tokenOut, uint _amountIn, uint256 _maxPriceImpact) internal view returns (uint256) {
        (uint112 _reserveIn, uint112 _reserveOut, uint16 _swapFee) = SyncSwapLibrary.getReserves(_factory, _tokenIn, _tokenOut);
        if (_reserveIn == 0) {
            return 0;
        }

        bool _canSwap = _maxPriceImpact == type(uint256).max || (_amountIn * PRECISION / _reserveIn) <= _maxPriceImpact;
        if (!_canSwap) {
            return 0;
        }

        return SyncSwapLibrary.getAmountOut(_amountIn, _reserveIn, _reserveOut, _swapFee);
    }

    function _getAmountsOutUnchecked(address _factory, uint _amountIn, address[] memory _path, uint256 _maxPriceImpact) internal view returns (uint256[] memory _amounts) {
        _amounts = new uint256[](_path.length);
        _amounts[0] = _amountIn;

        for (uint i; i < _path.length - 1; ) {
            uint256 _amount = _getAmountOut(_factory, _path[i], _path[i + 1], _amountIn, _maxPriceImpact);
            if (_amount == 0) {
                // Invalidate whole path if any of amounts is zero.
                return new uint256[](0);
            }

            _amounts[i + 1] = _amount;

            unchecked {
                ++i;
            }
        }
    }

    function _swapExactTokensForTokens(address _factory, uint256 _amountIn, address[] memory _path, uint256 _maxPriceImpact, address _to) internal {
        uint256[] memory _amounts = _getAmountsOutUnchecked(_factory, _amountIn, _path, _maxPriceImpact);
        if (_amounts.length == 0) {
            // Path is invalid as one of amounts is zero.
            return;
        }

        address _initialPair = SyncSwapLibrary.pairFor(_factory, _path[0], _path[1]);
        _path[0].safeTransfer(_initialPair, _amounts[0]);

        _swapCached(_factory, _initialPair, _amounts, _path, _to);
    }

    function _swapCached(address _factory, address _initialPair, uint[] memory _amounts, address[] memory _path, address _to) internal {
        address _nextPair = _initialPair;

        for (uint256 i = 0; i < _path.length - 1; ) {
            address _input = _path[i];
            address _output = _path[i + 1];
            uint256 _amountOut = _amounts[i + 1];

            if (i < _path.length - 2) {
                address _pair = _nextPair;
                _nextPair = SyncSwapLibrary.pairFor(_factory, _output, _path[i + 2]);
                _invokeSwap(_pair, _amountOut, _input, _output, _nextPair);
            } else {
                _invokeSwap(_nextPair, _amountOut, _input, _output, _to);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _invokeSwap(address _pair, uint _amountOut, address _tokenIn, address _tokenOut, address _to) internal {
        if (_tokenIn < _tokenOut) {
            ISyncSwapPair(_pair).swapFor1(_amountOut, _to);
        } else {
            ISyncSwapPair(_pair).swapFor0(_amountOut, _to);
        }
    }
}
