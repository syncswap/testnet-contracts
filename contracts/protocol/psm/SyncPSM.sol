// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import '../../interfaces/ERC20/IERC20.sol';
import '../../interfaces/ERC20/IERC20Metadata.sol';
import '../../interfaces/protocol/ISyncPSM.sol';
import '../../interfaces/protocol/IPSMVerifier.sol';

import '../../libraries/access/Ownable.sol';
import '../../libraries/security/ReentrancyGuard.sol';
import '../../libraries/token/ERC20/ERC20WithPermit.sol';
import "../../libraries/token/ERC20/utils/TransferHelper.sol";

contract SyncPSM is ISyncPSM, ERC20WithPermit, Ownable, ReentrancyGuard {

    /**
     * @dev The precision for swap fee rate.
     */
    uint256 public override FEE_PRECISION = 1e8;

    struct AssetInfo {
        bool exists;
        uint256 cap;
        uint256 reserve;
    }

    /**
     * @dev Deposit cap and reserve by listed assets.
     */
    mapping (address => AssetInfo) public assetInfo;

    /**
     * @dev All listed assets.
     */
    address[] public listedAssets;

    /**
     * @dev Supplied asset by users and can be consumed on withdrawal and swap.
     */
    mapping(address => mapping (address => uint256)) public userSupplies; // account -> asset -> amount

    /**
     * @dev Fee rate for swaps.
     *
     * Note this is under the `FEE_PRECISION` (1e8).
     */
    uint256 public override swapFeeRate = 5 * 1e4; // 0.05%

    /**
     * @dev Accrued and unclaimed fee by assets.
     */
    mapping(address => uint256) public accruedFees;

    /**
     * @dev Recipient of swap fee.
     *
     * Note `address(0)` will keep accumulated fees but transfers are disabled.
     */
    address public swapFeeRecipient = address(0);

    /**
     * @dev Whether deposits are paused.
     */
    bool public isDepositPaused = false;

    /**
     * @dev Whether swaps are paused.
     */
    bool public isSwapPaused = false;

    /**
     * @dev Whether emergency withdrawal is allowed.
     */
    bool public isEmergencyWithdrawEnabled = false;

    struct MinterInfo {
        bool isMinter;
        uint256 cap;
        uint256 supply;
    }

    /// @dev Mint cap and spent cap for minters
    mapping(address => MinterInfo) minterInfo;

    /**
     * @dev Addresses of all minters.
     */
    address[] public minters;

    /**
     * @dev Verifier to verify deposits and swaps.
     *
     * Note `address(0)` indicates no verifier.
     */
    address public verifier = address(0);

    event Deposit(address indexed sender, address indexed asset, uint256 assetAmount, address to);
    event Withdraw(address indexed sender, address indexed asset, uint256 nativeAmount, uint256 amountOut, address to);
    event Swap(address indexed sender, address indexed assetIn, address assetOut, uint256 amountIn, uint256 amountOut, address to);

    constructor() ERC20WithPermit() Ownable() {
        _initializeMetadata("Sync USD", "USDs");
    }

    /*//////////////////////////////////////////////////////////////
        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Lists an asset.
     */
    function addAsset(address _asset) external onlyOwner {
        require(_asset != address(0), "Invalid asset");
        require(IERC20(_asset).balanceOf(address(this)) != type(uint256).max, "Invalid asset"); // sanity check
        require(!assetInfo[_asset].exists, "Asset already exists");

        assetInfo[_asset].exists = true;
        listedAssets.push(_asset);
    }

    /**
     * @dev Delists an asset.
     *
     * Note only asset with zero reserve could be removed.
     */
    function removeAsset(address _asset) external onlyOwner {
        AssetInfo memory _info = assetInfo[_asset];
        require(_info.exists, "Asset is not listed");
        require(_info.reserve == 0, "Cannot remove asset with reserve");

        delete assetInfo[_asset];

        uint256 _assetsLength = listedAssets.length;
        for (uint256 i = 0; i < _assetsLength; ) {
            if (listedAssets[i] == _asset) {
                listedAssets[i] = listedAssets[_assetsLength - 1];
                listedAssets.pop();
                break;
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Sets deposit cap for an asset.
     */
    function setCap(address _asset, uint256 _newCap) external onlyOwner {
        AssetInfo memory _info = assetInfo[_asset];
        require(_info.exists, "Asset is not listed");
        require(_info.cap != _newCap, "No changes made");

        assetInfo[_asset].cap = _newCap;
    }

    /**
     * @dev Adds a minter.
     */
    function addMinter(address _minter) external onlyOwner {
        require(_minter != address(0) && _minter != address(this), "Invalid minter");
        require(!minterInfo[_minter].isMinter, "Minter already exists");

        minterInfo[_minter].isMinter = true;
        minters.push(_minter);
    }

    /**
     * @dev Removes a minter.
     *
     * Note only minter with zero supply could be removed.
     */
    function removeMinter(address _minter) external onlyOwner {
        MinterInfo memory _info = minterInfo[_minter];
        require(_info.isMinter, "Not a minter");
        require(_info.supply == 0, "Cannot remove minter with supply");

        delete minterInfo[_minter];

        uint256 _mintersLength = minters.length;
        for (uint256 i = 0; i < _mintersLength; ) {
            if (minters[i] == _minter) {
                minters[i] = minters[_mintersLength - 1];
                minters.pop();
                break;
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Sets supply cap for a minter.
     */
    function setMinterCap(address _minter, uint256 _newCap) external onlyOwner {
        MinterInfo memory _info = minterInfo[_minter];
        require(_info.isMinter, "Not a minter");
        require(_info.cap != _newCap, "No changes made");

        minterInfo[_minter].cap = _newCap;
    }

    /**
     * @dev Mint tokens for recipient, can only be called by minter.
     */
    function mint(address _to, uint256 _amount) external {
        require(_amount != 0, "Invalid amount to mint");

        MinterInfo memory _info = minterInfo[msg.sender];
        require(_info.supply + _amount <= _info.cap, "EXCEEDS_CAP"); // single check is sufficient

        unchecked {
            minterInfo[msg.sender].supply += _amount;
        }
        _mint(_to, _amount);
    }

    /**
     * @dev Burn tokens from caller, can only be called by minter.
     */
    function burn(uint256 _amount) external {
        require(_amount != 0, "Invalid amount to burn");
        require(minterInfo[msg.sender].isMinter, "Not a minter");

        minterInfo[msg.sender].supply -= _amount;
        _burn(msg.sender, _amount);
    }

    /**
     * @dev Sets verifier.
     */
    function setVerifier(address _verifier) external onlyOwner {
        verifier = _verifier;
    }

    /**
     * @dev Sets swap fee rate.
     */
    function setSwapFeeRate(uint256 _swapFeeRate) external onlyOwner {
        require(_swapFeeRate <= FEE_PRECISION, "Invalid swap fee rate");
        swapFeeRate = _swapFeeRate;
    }

    /**
     * @dev Sets fee recipient.
     */
    function setSwapFeeRecipient(address newRecipient) external onlyOwner {
        swapFeeRecipient = newRecipient;
    }

    /**
     * @dev Sets pausing status for deposits.
     */
    function setDepositPaused(bool _isDepositPaused) external onlyOwner {
        isDepositPaused = _isDepositPaused;
    }

    /**
     * @dev Sets pausing status for swaps.
     */
    function setSwapPaused(bool _isSwapPaused) external onlyOwner {
        isSwapPaused = _isSwapPaused;
    }

    /**
     * @dev Sets status of emergency withdrawal.
     */
    function setEmergencyWithdrawEnabled(bool _isEmergencyWithdrawEnabled) external onlyOwner {
        isEmergencyWithdrawEnabled = _isEmergencyWithdrawEnabled;
    }

    /**
     * @dev Rescues all possible amount for given token.
     */
    function rescueERC20(address _token) external onlyOwner {
        TransferHelper.safeTransfer(_token, msg.sender, rescuableERC20(_token));
    }

    /*//////////////////////////////////////////////////////////////
        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns cap for an asset.
     */
    function getCap(address _asset) external view returns (uint256) {
        return assetInfo[_asset].cap;
    }

    /**
     * @dev Returns reserve for an asset.
     */
    function getReserve(address _asset) external view returns (uint256) {
        return assetInfo[_asset].reserve;
    }

    /**
     * @dev Returns length of all minters.
     */
    function mintersLength() external view returns (uint256) {
        return minters.length;
    }

    /**
     * @dev Returns all minters.
     */
    function getMinters() external view returns (address[] memory) {
        return minters;
    }

    /**
     * @dev Returns rescuable amount for given token.
     */
    function rescuableERC20(address _token) public view returns (uint256 amount) {
        amount = IERC20(_token).balanceOf(address(this));

        // Remove reserves.
        AssetInfo memory _info = assetInfo[_token];
        amount -= _info.reserve;

        // Remove accrued fees.
        uint256 _accruedFeesFor = accruedFees[_token];
        amount -= _accruedFeesFor;
    }

    struct ReserveInfo {
        address asset;
        uint256 cap;
        uint256 reserve;
        uint256 supplied;
    }

    /**
     * @dev Returns swap fee, reserve and supply for all assets as of given account.
     */
    function getReserves(address _account) external view returns (uint256 swapFee, ReserveInfo[] memory reserves) {
        swapFee = swapFeeRate;
        reserves = new ReserveInfo[](listedAssets.length);

        for (uint i = 0; i < listedAssets.length; ) {
            address _asset = listedAssets[i];
            AssetInfo memory _info = assetInfo[_asset];

            reserves[i] = ReserveInfo({
                asset: _asset,
                cap: _info.cap,
                reserve: _info.reserve,
                supplied: userSupplies[_account][_asset]
            });

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Returns length of all listed assets.
     */
    function listedAssetsLength() external view returns (uint256) {
        return listedAssets.length;
    }

    /**
     * @dev Returns all listed assets.
     */
    function getListedAssets() external view returns (address[] memory) {
        return listedAssets;
    }

    function _calculateSwapFee(uint256 _amountOutDesired) internal view returns (uint256) {
        uint256 _swapFeeRate = swapFeeRate;
        return _swapFeeRate == 0 ? 0 : (_amountOutDesired * _swapFeeRate / FEE_PRECISION);
    }

    /**
     * @dev Returns fee for a withdrawal.
     */
    function getWithdrawFee(address _account, address _assetOut, uint256 _amountOutDesired) public view override returns (uint256) {
        uint256 _supply = userSupplies[_account][_assetOut];
        if (_supply != 0) {
            if (_supply >= _amountOutDesired) {
                // Consume part of supply and no need to charge fee.
                return 0;
            } else {
                // Consume all supply and charge remaining fee.
                return _calculateSwapFee(_amountOutDesired - _supply);
            }
        } else {
            // No supply to consume and charge the full fee.
            return _calculateSwapFee(_amountOutDesired);
        }
    }

    /**
     * @dev Returns expected output amount for a withdrawal.
     */
    function getWithdrawOut(address _account, address _assetOut, uint256 _amountOutDesired) public view override returns (uint256) {
        return _amountOutDesired - getWithdrawFee(_account, _assetOut, _amountOutDesired);
    }

    /**
     * @dev Returns fee in output asset for a swap.
     */
    function getSwapFee(uint256 _amountOut) public view override returns (uint256 fee) {
        return _calculateSwapFee(_amountOut);
    }

    /**
     * @dev Returns expected output amount for a swap.
     */
    function getSwapOut(address _assetIn, address _assetOut, uint256 _amountIn) external view override returns (uint256) {
        // Converts amount from input asset to output asset.
        uint256 amountOut = _toOutputAmount(_assetIn, _assetOut, _amountIn);

        // Applies swap fee.
        uint256 _fee = getSwapFee(amountOut);
        amountOut -= _fee;

        return amountOut;
    }

    /*//////////////////////////////////////////////////////////////
        USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns recipient of protocol fee.
     */
    function _feeRecipient() internal view returns (address) {
        address _swapFeeRecipient = swapFeeRecipient;
        require(_swapFeeRecipient != address(0), "No fee recipient");
        return _swapFeeRecipient;
    }

    /**
     * @dev Transfers accrued fee of an asset to recipient.
     */
    function _transferAccruedFeeFor(address _asset, address _to) internal {
        uint256 _fee = accruedFees[_asset];
        accruedFees[_asset] = 0;
        TransferHelper.safeTransfer(_asset, _to, _fee);
    }

    /**
     * @dev Permissionless transfer accrued fee for given asset.
     */
    function transferAccruedFeeFor(address _asset) external nonReentrant {
        _transferAccruedFeeFor(_asset, _feeRecipient());
    }

    /**
     * @dev Permissionless transfer all accrued fees.
     */
    function transferAllAccruedFees() external nonReentrant {
        address _to = _feeRecipient();
        uint256 _length = listedAssets.length;

        for (uint i = 0; i < _length; ) {
            _transferAccruedFeeFor(listedAssets[i], _to);

            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
        Deposit
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Converts decimals from given asset to native asset.
     */
    function _toNativeAmount(address _asset, uint256 _amountAsset) internal view returns (uint256) {
        return _amountAsset * 1e18 / (10 ** IERC20Metadata(_asset).decimals());
    }

    /**
     * @dev Converts decimals from native asset to given asset.
     */
    function _toAssetAmount(address _asset, uint256 _amountNative) internal view returns (uint256) {
        return _amountNative * (10 ** IERC20Metadata(_asset).decimals()) / 1e18;
    }

    /**
     * @dev Converts decimals from an asset to another asset.
     */
    function _toOutputAmount(address _assetA, address _assetB, uint256 _amountA) internal view returns (uint256) {
        return _amountA * (10 ** IERC20Metadata(_assetB).decimals()) / (10 ** IERC20Metadata(_assetA).decimals());
    }

    function _tryVerifyDeposit(address _asset, uint256 _amount) internal view returns (bool) {
        address _verifier = verifier;
        return _verifier == address(0) || IPSMVerifier(_verifier).verifyDeposit(msg.sender, _asset, _amount);
    }

    /**
     * @dev Deposits given asset and amount for on behalf of a recipient.
     */
    function deposit(address asset, uint256 assetAmount, address to) external override nonReentrant {
        // 1. Check: Input: Check input amount
        require(assetAmount != 0, "Amount must greater than zero");

        // ------------------------------

        // 2. Check: Condition: Check paused
        require(!isDepositPaused, "Deposit is paused");

        // 2-2. Check: Condition: Call external verifier (if exists) to verify
        require(_tryVerifyDeposit(asset, assetAmount), "Verification not passed");

        // 2-3. Check: Condition: Check cap
        AssetInfo memory _info = assetInfo[asset];
        require(_info.reserve + assetAmount <= _info.cap, "EXCEEDS_CAP");

        // ------------------------------

        // 3. Interaction: Receive input asset
        TransferHelper.safeTransferFrom(asset, msg.sender, address(this), assetAmount);
        
        // 3-1. Effects: Increase reserve and user supplies
        unchecked {
            assetInfo[asset].reserve += assetAmount;
        }
        userSupplies[to][asset] += assetAmount;

        // 3-2. Convert amount and mint native asset
        uint256 _nativeAmount = _toNativeAmount(asset, assetAmount);
        _mint(to, _nativeAmount);

        // ------------------------------

        // 4. Emit deposit event
        emit Deposit(msg.sender, asset, assetAmount, to);
    }

    /*//////////////////////////////////////////////////////////////
        Withdraw
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Accrues and returns the full swap fee.
     */
    function _calculateAndAccrueSwapFee(address _assetOut, uint256 _amountOutDesired) internal returns (uint256) {
        uint256 _fee = _calculateSwapFee(_amountOutDesired);
        if (_fee != 0) {
            accruedFees[_assetOut] += _fee;
        }
        return _fee;
    }

    /**
     * @dev Try accures and returns withdraw fee.
     */
    function _tryAccrueWithdrawFee(address _account, address _assetOut, uint256 _amountOutDesired) internal returns (uint256 _fee) {
        uint256 _supply = userSupplies[_account][_assetOut];
        if (_supply != 0) {
            if (_supply >= _amountOutDesired) {
                // Consume part of supply and no need to charge fee.
                userSupplies[_account][_assetOut] -= _amountOutDesired;
                _fee = 0;
            } else {
                // Consume all supply and charge remaining fee.
                userSupplies[_account][_assetOut] = 0;
                _fee = _calculateAndAccrueSwapFee(_assetOut, _amountOutDesired - _supply);
            }
        } else {
            // No supply to consume and charge the full fee.
            _fee = _calculateAndAccrueSwapFee(_assetOut, _amountOutDesired);
        }
    }

    function _withdrawAsset(address _assetOut, uint256 _amountOutDesired, address _to, bool _isSwap) internal returns (uint256 _amountOutAfterFee) {
        // Decreases reserve.
        assetInfo[_assetOut].reserve -= _amountOutDesired;

        // Accrues fee (possible) for output asset.
        uint256 _fee = (
            _isSwap ?
            _calculateAndAccrueSwapFee(_assetOut, _amountOutDesired) : // Full fee for swaps.
            _tryAccrueWithdrawFee(msg.sender, _assetOut, _amountOutDesired)
        );
        _amountOutAfterFee = _amountOutDesired - _fee;

        // Transfers output asset.
        require(_amountOutAfterFee != 0, "INSUFFICIENT_INPUT");
        TransferHelper.safeTransfer(_assetOut, _to, _amountOutAfterFee);
    }

    /**
     * @dev Withdraws given amount and asset.
     */
    function withdraw(address asset, uint256 nativeAmount, address to) external override nonReentrant returns (uint256 amountOut) {
        // 1. Check: Input: Check input amount
        require(nativeAmount != 0, "Amount must greater than zero");

        ////////////////////////////////////////////////////////////////

        // 2. Effects: Burn native asset
        _burn(msg.sender, nativeAmount);

        // 2-1. Convert from native amount to output amount
        amountOut = _toAssetAmount(asset, nativeAmount);

        // 2-3. Withdraw output asset
        amountOut = _withdrawAsset(asset, amountOut, to, false);

        ////////////////////////////////////////////////////////////////

        // 3. Emit withdraw event
        emit Withdraw(msg.sender, asset, nativeAmount, amountOut, to);
    }

    function emergencyWithdraw(address asset, uint256 nativeAmount) external nonReentrant returns (uint256 amountOut) {
        require(isEmergencyWithdrawEnabled, "Emergency withdraw is not enabled");
        require(nativeAmount != 0, "Amount must greater than zero");

        // Burn and transfer asset
        _burn(msg.sender, nativeAmount);
        amountOut = _toAssetAmount(asset, nativeAmount);
        require(amountOut != 0, "INSUFFICIENT_INPUT");

        // Ignore reserves and fees in the emergency case
        userSupplies[msg.sender][asset] = 0;

        TransferHelper.safeTransfer(asset, msg.sender, amountOut);

        emit Withdraw(msg.sender, asset, nativeAmount, amountOut, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
        Swap
    //////////////////////////////////////////////////////////////*/

    function _tryVerifySwap(address assetIn, address assetOut, uint256 amountIn) private view returns (bool) {
        address _verifier = verifier;
        return _verifier == address(0) || IPSMVerifier(_verifier).verifySwap(msg.sender, assetIn, assetOut, amountIn);
    }

    /**
     * @dev Swaps from input asset in given amount to the output asset.
     */
    function swap(address assetIn, address assetOut, uint256 amountIn, address to) external override nonReentrant returns (uint256 amountOut) {
        // 1-1. Check: Input: Check asset addresses
        require(assetIn != assetOut, "Identical assets");
        
        // 1-2. Check: Input: Check input amount
        require(amountIn != 0, "Amount must greater than zero");

        ////////////////////////////////////////////////////////////////

        // 2. Check: Condition: Check paused
        require(!isSwapPaused, "Swap is paused");

        // 2-1. Check: Condition: Call external verifier to verify (if exists)
        require(_tryVerifySwap(assetIn, assetOut, amountIn), "Verification not passed");

        // 2-2. Check: Condition: Check cap
        AssetInfo memory _infoIn = assetInfo[assetIn];
        require(_infoIn.reserve + amountIn <= _infoIn.cap, "EXCEEDS_CAP");

        ////////////////////////////////////////////////////////////////

        // 3. Interaction: Receive input asset
        TransferHelper.safeTransferFrom(assetIn, msg.sender, address(this), amountIn);

        // 3-1. Effects: Increase reserve for input asset
        unchecked {
            assetInfo[assetIn].reserve += amountIn;
        }

        ////////////////////////////////////////////////////////////////

        // 4. Convert from input amount to output amount
        amountOut = _toOutputAmount(assetIn, assetOut, amountIn);

        // 4-2. Withdraw output asset
        amountOut = _withdrawAsset(assetOut, amountOut, to, true);

        ////////////////////////////////////////////////////////////////

        // 5. Emit swap event
        emit Swap(msg.sender, assetIn, assetOut, amountIn, amountOut, to);
    }
}