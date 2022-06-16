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

    uint256 public override FEE_PRECISION = 1e8;

    struct Profile {
        uint256 cap;
        uint256 reserve;
    }

    /// @dev Deposit cap and reserve for assets
    mapping (address => Profile) public assetProfiles;

    /// @dev Assets that has a cap
    address[] public listedAssets;

    /// @dev User supplied assets, account => asset => amount
    mapping(address => mapping (address => uint256)) public userSupplies;

    /// @dev Fee rate for swap using reserves
    uint256 public override swapFeeRate = 5 * 1e4; // 0.05%

    /// @dev Accrued fee for assets
    mapping(address => uint256) public accruedFees;

    /// @dev Recipient for accrued fees
    address public swapFeeRecipient = address(0);

    bool public isDepositPaused;
    bool public isSwapPaused;
    bool public isEmergencyWithdrawEnabled;

    /// @dev Mint cap and spent cap for minters
    mapping(address => Profile) minterProfiles;

    /// @dev Minters that has a cap
    address[] public minters;

    /// @dev Verifier to verify on deposit and swap
    address public verifier;

    event Deposit(address indexed sender, uint256 timestamp, address indexed asset, uint256 assetAmount, address indexed to);
    event Withdraw(address indexed sender, uint256 timestamp, address indexed asset, uint256 nativeAmount, uint256 amountOut, address indexed to);
    event Swap(address indexed sender, uint256 timestamp, address indexed assetIn, address assetOut, uint256 amountIn, uint256 amountOut, address indexed to);

    constructor() ERC20WithPermit() Ownable() {
        _initializeMetadata("Sync USD", "USDs");
    }

    // ----------------------------------------
    //  Management Functions
    // ----------------------------------------

    function setVerifier(address newVerifier) external onlyOwner {
        verifier = newVerifier;
    }

    // ---------- Cap ----------

    /// @dev Set a new cap for given asset
    function setCap(address asset, uint256 newCap) external onlyOwner {
        require(asset != address(0) && asset != address(this), "Illegal asset address");
        require(IERC20(asset).balanceOf(address(this)) != type(uint256).max, "Invalid asset");

        uint256 _previousCap = assetProfiles[asset].cap;
        require(_previousCap != newCap, "Cap is not changed");

        assetProfiles[asset].cap = newCap;

        if (_previousCap == 0) {
            // Adds a new asset
            listedAssets.push(asset);
            return;
        }

        if (newCap == 0) {
            // Removes an exist asset / do not reset its reserve
            address[] memory _assets = listedAssets;
            for (uint i = 0; i < _assets.length; i++) {
                if (_assets[i] == asset) {
                    listedAssets[i] = _assets[_assets.length - 1];
                    listedAssets.pop();
                }
            }
        }
    }

    // ---------- Fee ----------

    /// @dev Set a new swap fee rate
    function setSwapFeeRate(uint256 newFeeRate) external onlyOwner {
        require(newFeeRate <= FEE_PRECISION, "Illegal fee rate");
        swapFeeRate = newFeeRate;
    }

    /// @dev Set a new fee recipient
    function setSwapFeeRecipient(address newRecipient) external onlyOwner {
        swapFeeRecipient = newRecipient;
    }

    function _transferAccruedFeesFor(address asset, address to) private {
        uint256 accruedFeesFor = accruedFees[asset];
        accruedFees[asset] = 0;
        TransferHelper.safeTransfer(asset, to, accruedFeesFor);
    }

    function _feeRecipient() private view returns (address) {
        return swapFeeRecipient != address(0) ? swapFeeRecipient : owner();
    }

    /// @dev Permissionless transfer accrued fees for given asset
    function transferAccruedFeesFor(address asset) external {
        address _to = _feeRecipient();
        _transferAccruedFeesFor(asset, _to);
    }

    /// @dev Permissionless transfer all accrued fees
    function transferAllAccruedFees() external {
        address _to = _feeRecipient();
        for (uint i = 0; i < listedAssets.length; i++) {
            _transferAccruedFeesFor(listedAssets[i], _to);
        }
    }

    // ---------- Pause ----------

    /// @dev Pause or unpause deposit
    function setDepositPaused(bool newStatus) external onlyOwner {
        isDepositPaused = newStatus;
    }

    /// @dev Pause or unpause swap
    function setSwapPaused(bool newStatus) external onlyOwner {
        isSwapPaused = newStatus;
    }

    /// @dev Enable or disable emergency withdrawal
    function setEmergencyWithdrawEnabled(bool newStatus) external onlyOwner {
        isEmergencyWithdrawEnabled = newStatus;
    }

    // ---------- Minter ----------

    /// @dev Set a new cap for given minter
    function setMinterCap(address minter, uint256 newCap) external onlyOwner {
        require(minter != address(0) && minter != address(this), "Illegal minter address");

        uint256 _previousCap = minterProfiles[minter].cap;
        require(_previousCap != newCap, "Cap is not changed");

        minterProfiles[minter].cap = newCap;

        if (_previousCap == 0) {
            // Adds a new minter
            minters.push(minter);
            return;
        }

        if (newCap == 0) {
            // Removes an exist minter / do not reset its reserve
            address[] memory _minters = minters;
            for (uint i = 0; i < _minters.length; i++) {
                if (_minters[i] == minter) {
                    minters[i] = _minters[_minters.length - 1];
                    minters.pop();
                }
            }
        }
    }

    /// @dev Mint tokens for recipient
    function mint(address to, uint256 amount) external {
        require(amount != 0, "Illegal amount to mint");

        Profile memory _profile = minterProfiles[msg.sender];
        require(_profile.reserve + amount <= _profile.cap, "EXCEEDS_CAP");

        minterProfiles[msg.sender].reserve += amount;
        _mint(to, amount);
    }

    /// @dev Burn tokens for caller minter
    function burn(uint256 amount) external {
        require(amount != 0, "Illegal amount to mint");

        minterProfiles[msg.sender].reserve -= amount;
        _burn(msg.sender, amount);
    }

    /// @dev Returns length of all minters
    function mintersLength() external view returns (uint256) {
        return minters.length;
    }

    // ---------- Rescue ----------

    /// @dev Return rescuable amount for given token
    function rescuableERC20(address token) public view returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        Profile memory _profile = assetProfiles[token];
        amount -= _profile.reserve;
        uint256 _accruedFeesFor = accruedFees[token];
        amount -= _accruedFeesFor;
    }

    /// @dev Rescue all rescuable amount for given token
    function rescueERC20(address token) external onlyOwner {
        uint256 amount = rescuableERC20(token);
        TransferHelper.safeTransfer(token, msg.sender, amount);
    }

    // ----------------------------------------
    //  View Functions
    // ----------------------------------------

    struct Reserve {
        address asset;
        uint256 cap;
        uint256 reserve;
        uint256 supplied;
    }

    /// @dev Return reserves and supplies of all assets for given account
    function getReserves(address account) external view returns (uint256 feeRate, Reserve[] memory reserves) {
        reserves = new Reserve[](listedAssets.length);

        for (uint i = 0; i < listedAssets.length; ) {
            address _asset = listedAssets[i];
            Profile memory _profile = assetProfiles[_asset];

            reserves[i] = Reserve({
                asset: _asset,
                cap: _profile.cap,
                reserve: _profile.reserve,
                supplied: userSupplies[account][_asset]
            });

            unchecked {
                ++i;
            }
        }

        feeRate = swapFeeRate;
    }

    function listedAssetsLength() external view returns (uint256) {
        return listedAssets.length;
    }

    // ----------------------------------------
    //  Deposit
    // ----------------------------------------

    function _tryVerifyDeposit(address asset, uint256 assetAmount) private view returns (bool) {
        address _verifier = verifier;
        return _verifier == address(0) || IPSMVerifier(_verifier).verifyDeposit(asset, assetAmount);
    }

    /// @dev Converts from asset amount to native amount in decimals
    function _toNativeAmount(address asset, uint256 assetAmount) private view returns (uint256) {
        return assetAmount * 1e18 / (10 ** IERC20Metadata(asset).decimals());
    }

    /// @dev Converts from native amount to asset amount in decimals
    function _toAssetAmount(address asset, uint256 nativeAmount) private view returns (uint256) {
        return nativeAmount * (10 ** IERC20Metadata(asset).decimals()) / 1e18;
    }

    /// @dev Converts from amount of input asset to amount of output asset in decimals
    function _toOutputAmount(address assetIn, address assetOut, uint256 amountIn) private view returns (uint256) {
        return amountIn * (10 ** IERC20Metadata(assetOut).decimals()) / (10 ** IERC20Metadata(assetIn).decimals());
    }

    /// @dev Deposit given asset and amount for recipient
    function deposit(address asset, uint256 assetAmount, address to) external override nonReentrant {
        // 1. Check: Input: Check recipient address
        require(to != address(0) && to != address(this), "Invalid recipient address");

        // 1-1. Check: Input: Check input amount
        require(assetAmount != 0, "Amount must greater than zero");

        // ------------------------------

        // 2. Check: Condition: Check paused
        require(!isDepositPaused, "Deposit is paused");

        // 2-2. Check: Condition: Call external verifier (if exists) to verify
        require(_tryVerifyDeposit(asset, assetAmount), "Verification not passed");

        // 2-3. Check: Condition: Check cap
        Profile memory _profile = assetProfiles[asset];
        require(_profile.reserve + assetAmount <= _profile.cap, "EXCEEDS_CAP");

        // ------------------------------

        // 3. Interaction: Receive input asset
        TransferHelper.safeTransferFrom(asset, msg.sender, address(this), assetAmount);
        
        // 3-1. Effects: Increase reserve and user supplies
        assetProfiles[asset].reserve += assetAmount;
        userSupplies[to][asset] += assetAmount;

        // 3-2. Convert amount and mint native asset
        uint256 nativeAmount = _toNativeAmount(asset, assetAmount);
        _mint(to, nativeAmount);

        // ------------------------------

        // 4. Emit deposit event
        emit Deposit(msg.sender, block.timestamp, asset, assetAmount, to);
    }

    // ----------------------------------------
    //  Withdraw
    // ----------------------------------------

    function _getSwapFee(uint256 amount) private view returns (uint256) {
        if (swapFeeRate == 0) {
            return 0;
        } else {
            return amount * swapFeeRate / FEE_PRECISION;
        }
    }

    function _chargeSwapFees(address asset, uint256 assetAmount) private returns (uint256 fee) {
        fee = _getSwapFee(assetAmount);
        if (fee != 0) {
            accruedFees[asset] += fee;
        }
    }

    function _tryChargeSwapFees(address account, address asset, uint256 assetAmount) private returns (uint256 fee) {
        uint256 supplied = userSupplies[account][asset];
        if (supplied != 0) {
            if (supplied >= assetAmount) {
                // Consume part of points, no need to charge fees
                userSupplies[account][asset] -= assetAmount;
                fee = 0;
            } else {
                // Consume all points and charge remaining fees
                userSupplies[account][asset] = 0;
                fee = _chargeSwapFees(asset, assetAmount - supplied);
            }
        } else {
            // Charge the full fees
            fee = _chargeSwapFees(asset, assetAmount);
        }
    }

    /// @dev Return expected output amount of a withdrawal
    function getWithdrawOut(address account, address asset, uint256 assetAmount) public view override returns (uint256) {
        uint256 supplied = userSupplies[account][asset];
        if (supplied != 0) {
            if (supplied >= assetAmount) {
                // Consume part of points, no need to charge fees
                return assetAmount;
            } else {
                // Consume all points and charge remaining fees
                uint256 fee = _getSwapFee(assetAmount - supplied);
                return assetAmount - fee;
            }
        } else {
            // Charge the full fees
            uint256 fee = _getSwapFee(assetAmount);
            return assetAmount - fee;
        }
    }

    function _withdrawAsset(address asset, uint256 assetAmount, address to) private returns (uint256 amountOut) {
        // Decrease asset reserve
        assetProfiles[asset].reserve -= assetAmount;

        // Charge swap fees (if exists) upon output amount
        uint256 fees = _tryChargeSwapFees(to, asset, assetAmount);
        amountOut = assetAmount - fees;

        // Transfer output asset
        require(amountOut != 0, "INSUFFICIENT_INPUT");
        TransferHelper.safeTransfer(asset, to, amountOut);
    }

    /// @dev Withdraw given amount and asset to recipient
    function withdraw(address asset, uint256 nativeAmount, address to) external override nonReentrant returns (uint256 amountOut) {
        // 1. Check: Input: Check recipient address
        require(to != address(0) && to != address(this), "Invalid recipient address");

        // 1-1. Check: Input: Check input amount
        require(nativeAmount != 0, "Amount must greater than zero");

        // ------------------------------

        // 2. Effects: Burn native asset
        _burn(msg.sender, nativeAmount);

        // 2-1. Convert from native amount to output amount
        amountOut = _toAssetAmount(asset, nativeAmount);

        // 2-3. Withdraw output asset
        amountOut = _withdrawAsset(asset, amountOut, to);
        
        // ------------------------------

        // 4. Emit withdraw event
        emit Withdraw(msg.sender, block.timestamp, asset, nativeAmount, amountOut, to);
    }

    function emergencyWithdraw(address asset, uint256 nativeAmount, address to) external nonReentrant returns (uint256 amountOut) {
        require(isEmergencyWithdrawEnabled, "Emergency withdraw is not enabled");
        require(to != address(0) && to != address(this), "Invalid recipient address");
        require(nativeAmount != 0, "Amount must greater than zero");

        // Burn and transfer asset
        _burn(msg.sender, nativeAmount);
        amountOut = _toAssetAmount(asset, nativeAmount);
        require(amountOut != 0, "INSUFFICIENT_INPUT");

        // Ignore reserves and fees in the emergency case
        userSupplies[msg.sender][asset] = 0;

        TransferHelper.safeTransfer(asset, to, amountOut);

        emit Withdraw(msg.sender, block.timestamp, asset, nativeAmount, amountOut, to);
    }

    // ----------------------------------------
    //  Swap
    // ----------------------------------------

    function _tryVerifySwap(address assetIn, address assetOut, uint256 amountIn) private view returns (bool) {
        address _verifier = verifier;
        return _verifier == address(0) || IPSMVerifier(_verifier).verifySwap(assetIn, assetOut, amountIn);
    }

    /// @dev Return expected output amount of a swap
    function getSwapOut(address account, address assetIn, address assetOut, uint256 amountIn) external view override returns (uint256 amountOut) {
        amountOut = _toOutputAmount(assetIn, assetOut, amountIn);
        return getWithdrawOut(account, assetOut, amountOut);
    }

    /// @dev Swap from input asset in given amount to output asset with recipient
    function swap(address assetIn, address assetOut, uint256 amountIn, address to) external override nonReentrant returns (uint256 amountOut) {
        // 1-1. Check: Input: Check asset addresses
        require(assetIn != assetOut, "Identical assets");
        
        // 1-2. Check: Input: Check recipient address
        require(to != address(0) && to != address(this), "Invalid recipient address");
        
        // 1-3. Check: Input: Check input amount
        require(amountIn != 0, "Amount must greater than zero");

        // ------------------------------

        // 2. Check: Condition: Check paused
        require(!isSwapPaused, "Swap is paused");

        // 2-1. Check: Condition: Call external verifier to verify (if exists)
        require(_tryVerifySwap(assetIn, assetOut, amountIn), "Verification not passed");

        // 2-2. Check: Condition: Check cap
        Profile memory _profileIn = assetProfiles[assetIn];
        require(_profileIn.reserve + amountIn <= _profileIn.cap, "EXCEEDS_CAP");

        // ------------------------------

        // 7. Interaction: Receive input asset
        TransferHelper.safeTransferFrom(assetIn, msg.sender, address(this), amountIn);

        // 7-1. Effects: Increase reserve for input asset
        assetProfiles[assetIn].reserve += amountIn;

        // ------------------------------

        // 8. Convert from input amount to output amount
        amountOut = _toOutputAmount(assetIn, assetOut, amountIn);

        // 8-2. Withdraw output asset
        amountOut = _withdrawAsset(assetOut, amountOut, to);

        // ------------------------------

        // 9. Emit swap event
        emit Swap(msg.sender, block.timestamp, assetIn, assetOut, amountIn, amountOut, to);
    }
}