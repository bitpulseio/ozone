// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * MapleVault (ERC-4626) — Minimal pass-through wrapper for Maple Finance
 * - Asset: any ERC20 supported by Maple Finance pool (e.g., USDC)
 * - Shares: ERC20 receipt token (Bitpulse-branded claim token, e.g., bpUSDC)
 * - totalAssets() = syrupToken.balanceOf(address(this))  (includes Maple interest)
 * - After deposit → deposit() to Maple pool
 * - Before withdraw → withdraw() from Maple pool
 * - MVP: no oracle reads, no reward valuation, withdrawals always open
 *
 * Security notes:
 *  - ReentrancyGuard on internal deposit/withdraw hooks and _deposit gate
 *  - Checks-Effects-Interactions ordering
 *  - Narrow circuit breaker disables deposits (withdrawals always enabled)
 */

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

// ---------------------------
// Minimal Maple Finance interfaces
// ---------------------------
// Note: The Maple pool is accessed through an upgradeable proxy.
// The proxy address should be provided, and calls will be delegated to the implementation.
interface IMaplePool {
    /// @dev Maple Finance deposit. Deposits underlying tokens and mints syrup tokens.
    /// Some implementations require tokens to be transferred first, others use transferFrom.
    /// @param amount Amount of underlying tokens to deposit
    /// @return Amount of syrup tokens received (may vary by implementation)
    function deposit(uint256 amount) external returns (uint256);
    
    /// @dev Alternative deposit signature with asset parameter (if supported)
    /// @param asset The asset address to deposit
    /// @param amount Amount of underlying tokens to deposit
    /// @return Amount of syrup tokens received
    function deposit(address asset, uint256 amount) external returns (uint256);

    /// @dev Get lender's balance (shares) in the pool
    /// @param account The lender address
    /// @return The number of shares held by the account
    function balanceOf(address account) external view returns (uint256);

    /// @dev Convert shares to exit assets (underlying tokens that can be withdrawn)
    /// @param shares The number of shares to convert
    /// @return The amount of underlying assets that can be withdrawn for these shares
    function convertToExitAssets(uint256 shares) external view returns (uint256);

    /// @dev Convert asset amount to shares needed for withdrawal
    /// @param assets The amount of underlying assets to withdraw
    /// @return The number of shares needed to withdraw these assets
    function convertToExitShares(uint256 assets) external view returns (uint256);

    /// @dev Request redemption of shares from the pool (queued / asynchronous).
    /// @param shares The number of pool shares to redeem
    /// @param owner  The owner for the withdrawal request (typically msg.sender / the vault)
    /// @return The request ID
    /// @notice On Sepolia pool `0x2d8D...`, the signature is `requestRedeem(uint256,address)` (selector `0x107703ab`).
    function requestRedeem(uint256 shares, address owner) external returns (uint256);
}

/// @dev PoolPermissionManager interface for checking authorization
interface IPoolPermissionManager {
    /// @dev Check if an account is authorized for a pool
    /// @param account The account address to check
    /// @param pool The pool address
    /// @return true if authorized, false otherwise
    function isAuthorized(address account, address pool) external view returns (bool);
    
    /// @dev Alternative authorization check (mapping-based)
    /// @param account The account address
    /// @param pool The pool address
    /// @return true if authorized, false otherwise
    function authorized(address account, address pool) external view returns (bool);
}

/// @dev SyrupRouter interface for depositing via Maple Finance router
/// This router handles deposits for whitelisted contracts
interface ISyrupRouter {
    /// @dev Deposit tokens via router
    /// @param amount Amount of underlying tokens to deposit
    /// @param depositData Deposit data (e.g., "0:BITPULSE" as bytes32)
    /// @return shares Amount of syrup tokens received
    function deposit(uint256 amount, bytes32 depositData) external returns (uint256 shares);
    
    /// @dev Get the permission manager address
    /// @return The permission manager address
    function permissionManager() external view returns (address);
    
    /// @dev Alternative getter for permission manager
    /// @return The permission manager address
    function PERMISSION_MANAGER() external view returns (address);
}

interface ISyrupToken is IERC20 {
    // Syrup token is ERC20-compatible; balanceOf reflects accrued interest.
}

/// @title MapleVault
/// @notice ERC-4626 vault that pass-throughs deposits to Maple Finance and holds syrup tokens.
contract MapleVault is ERC4626, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    // --- Immutable configuration ---
    IMaplePool public immutable maplePool;
    ISyrupRouter public immutable syrupRouter; // SyrupRouter for authorized deposits
    ISyrupToken public immutable syrupToken;  // Syrup token corresponding to `asset()`
    address   public immutable feesWallet;   // Wallet to receive fees
    uint256   public immutable feePercentage; // Fee percentage in basis points (e.g., 100 = 1%)

    // --- Vault controls ---
    bool     public depositsDisabled;       // circuit breaker (deposits only)
    uint256  public tvlCap;                 // 0 = no cap; else max totalAssets() allowed
    uint256  public totalPrincipal;        // Total principal deposited (excluding yield)
    address  public permissionManager;      // Cached permission manager address (optional, for gas savings)
    
    // --- Pending withdrawals tracking ---
    struct PendingWithdrawal {
        address owner;      // Original owner of the shares
        uint256 assets;
        uint256 shares;
        uint256 fee;
        bool completed;
    }
    // Mapping from unique withdrawal key (keccak256(receiver, owner)) to pending withdrawal
    // Key by (owner, receiver) only to ensure we can find pending withdrawals even when
    // shares change due to exchange rate fluctuations during async Maple processing
    mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals;
    
    // Helper function to generate unique withdrawal key
    // Key by (owner, receiver) only - enforces at most one pending withdrawal per pair
    // This allows finding pending withdrawals even when shares change between calls
    function _getWithdrawalKey(address receiver, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(receiver, owner));
    }
    
    // --- Constants ---
    // Deposit data "0:bitpulse" encoded as bytes32 (padded with zeros)
    bytes32 public constant DEPOSIT_DATA = bytes32(bytes("0:bitpulse"));

    // --- Events ---
    event DepositsDisabled(bool disabled);
    event CapUpdated(uint256 newCap);
    event FeesCollected(address indexed feesWallet, uint256 amount);
    event PermissionManagerUpdated(address indexed permissionManager);
    event WithdrawalRequested(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event WithdrawalCompleted(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    // --- Errors ---
    error DepositsDisabledErr();
    error CapExceeded();
    error ZeroAddress();
    error InvalidFeePercentage();
    error NoPendingWithdrawal();
    error AssetsNotYetReceived();
    error InsufficientAssetsReceived();
    error WithdrawalPending();

    /**
     * @param underlying ERC20 asset accepted by Maple pool (e.g., USDC)
     * @param _maplePool  Maple Finance Pool upgradeable proxy address (calls are delegated to implementation)
     * @param _syrupRouter SyrupRouter address for authorized deposits (e.g., 0x5387Ab37f93Af968920af6c0Faa6dbc52973b020 on Sepolia)
     * @param _syrupToken The syrup token address corresponding to `underlying`
     * @param _feesWallet Address to receive fees
     * @param _feePercentage Fee percentage in basis points (e.g., 100 = 1%, max 10000 = 100%)
     * @param assetSymbol Symbol suffix for share token branding (e.g., "USDC")
     */
    constructor(
        IERC20 underlying,
        address _maplePool,
        address _syrupRouter,
        address _syrupToken,
        address _feesWallet,
        uint256 _feePercentage,
        string memory assetSymbol // e.g., "USDC" — pass from a factory/deployer
    )
        // Bitpulse-branded per-vault claim token (your "Bitpulse Token" for this asset)
        ERC20(
            string.concat("Ozone ", assetSymbol, " Claim (Maple)"),
            string.concat("oz", assetSymbol, "-Maple")
        )
        ERC4626(underlying)
        Ownable(msg.sender)
    {
        if (_maplePool == address(0) || _syrupRouter == address(0) || _syrupToken == address(0)) revert ZeroAddress();
        if (_feesWallet == address(0)) revert ZeroAddress();
        if (_feePercentage > 10000) revert InvalidFeePercentage();
        
        maplePool = IMaplePool(_maplePool);
        syrupRouter = ISyrupRouter(_syrupRouter);
        syrupToken = ISyrupToken(_syrupToken);
        feesWallet = _feesWallet;
        feePercentage = _feePercentage;
    }

    // =========================================================================
    //                              Core 4626
    // =========================================================================

    /// @dev NAV in underlying `asset()` units.
    /// Includes:
    /// - idle underlying sitting in this vault (e.g., after Maple completes a redeem but before we forward to user)
    /// - underlying value of Maple position (pool shares converted to exit assets)
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 poolShares = maplePool.balanceOf(address(this));
        uint256 inPool = poolShares == 0 ? 0 : maplePool.convertToExitAssets(poolShares);
        return idle + inPool;
    }

    /// @dev Soft guardrails on deposit flow via maxDeposit().
    function maxDeposit(address) public view override returns (uint256) {
        if (depositsDisabled) return 0;
        if (tvlCap == 0) return type(uint256).max;

        uint256 assetsNow = totalAssets();
        if (assetsNow >= tvlCap) return 0;
        return tvlCap - assetsNow;
    }

    /// @dev Standard ERC-4626 conversions (first depositor 1:1).
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return super.convertToShares(assets);
    }
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return super.convertToAssets(shares);
    }

    /**
     * @dev Request withdrawal from Maple pool (asynchronous)
     * Follows Maple Finance withdrawal pattern:
     * 1. Retrieve lender's balance (shares) from pool
     * 2. Calculate shares to redeem for requested assets
     * 3. Execute withdrawal request via requestRedeem
     * Optimized to minimize gas by combining checks where possible.
     */
    function _requestMapleWithdrawal(uint256 assets) internal {
        // Step 1: Retrieve lender's balance (shares) from the pool
        uint256 poolShares = maplePool.balanceOf(address(this));
        
        // Step 2: Calculate shares to redeem for the requested asset amount
        uint256 sharesToRedeem = maplePool.convertToExitShares(assets);
        
        // Ensure we have enough shares in the pool (revert early to save gas)
        if (poolShares < sharesToRedeem) {
            revert("Insufficient shares in pool");
        }
        
        // Step 3: Execute withdrawal request via requestRedeem
        // The pool will handle the redemption asynchronously and transfer underlying assets to this contract later
        // Note: requestRedeem transfers shares to WithdrawalManager and assets will be sent to msg.sender (this contract) when processed
        // Sepolia Maple pool expects (shares, owner)
        maplePool.requestRedeem(sharesToRedeem, address(this));
    }

    /**
     * @dev Override _withdraw to check for pending withdrawals or initiate new withdrawal
     * - First check if idle balance is sufficient - if so, pay out directly
     * - If pending withdrawal exists for (owner, receiver): check if complete, transfer funds if ready, or revert if pending
     * - If no pending withdrawal: initiate new withdrawal from Maple pool
     */
    function _withdraw(address, address receiver, address owner, uint256 assets, uint256 shares) internal override nonReentrant {
        // Generate unique key for this withdrawal (owner, receiver only)
        bytes32 withdrawalKey = _getWithdrawalKey(receiver, owner);
        PendingWithdrawal storage pending = pendingWithdrawals[withdrawalKey];
        
        // Check if there's a pending withdrawal (non-zero assets indicates it exists)
        if (pending.assets > 0) {
            // Check if already completed
            if (pending.completed) {
                revert NoPendingWithdrawal();
            }
            
            // Check if assets have been received from Maple pool
            uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
            
            if (assetBalance >= pending.assets) {
                // Withdrawal is complete - transfer funds
                // Mark as completed before transfers (checks-effects-interactions)
                pending.completed = true;
                
                // Burn the stored shares (not the current call's shares which may differ)
                _burn(owner, pending.shares);
                
                // Transfer fee to fees wallet if any (cache fee to avoid storage read)
                uint256 _pendingFee = pending.fee;
                if (_pendingFee > 0) {
                    IERC20(asset()).safeTransfer(feesWallet, _pendingFee);
                    emit FeesCollected(feesWallet, _pendingFee);
                }
                
                // Transfer remaining assets to receiver
                uint256 userAmount = pending.assets - _pendingFee;
                IERC20(asset()).safeTransfer(receiver, userAmount);
                
                emit WithdrawalCompleted(owner, receiver, pending.assets, pending.shares);
                emit Withdraw(msg.sender, receiver, owner, userAmount, pending.shares);
                
                // Clear the pending withdrawal record so future withdrawals can proceed
                delete pendingWithdrawals[withdrawalKey];
                
                return;
            } else {
                // Assets not yet received - withdrawal still pending
                revert WithdrawalPending();
            }
        }
        
        // No pending withdrawal found - declare variables for fee calculation (used in both paths)
        uint256 feeAmount = 0;
        uint256 totalShares = totalSupply();
        uint256 totalPrincipalValue = totalPrincipal;
        
        // Check if we have sufficient idle balance first
        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));
        if (idleBalance >= assets) {
            // We have enough idle assets - pay out directly without requesting from Maple
            // Calculate fees on earned yield
            // Simplified fee calculation - only if there's yield and shares exist
            if (totalShares > 0 && totalPrincipalValue > 0) {
                uint256 assetsBeforeWithdraw = totalAssets();
                
                // Only calculate fee if there's actual yield
                if (assetsBeforeWithdraw > totalPrincipalValue) {
                    uint256 totalYield = assetsBeforeWithdraw - totalPrincipalValue;
                    uint256 userYieldShare = (shares * totalYield) / totalShares;
                    feeAmount = (userYieldShare * feePercentage) / 10000;
                    
                    // Update totalPrincipal
                    uint256 principalPortion = assets - userYieldShare;
                    totalPrincipal = totalPrincipalValue >= principalPortion ? totalPrincipalValue - principalPortion : 0;
                } else {
                    // No yield, just update totalPrincipal
                    totalPrincipal = totalPrincipalValue >= assets ? totalPrincipalValue - assets : 0;
                }
            } else {
                // First withdrawal or no shares, update totalPrincipal
                totalPrincipal = totalPrincipalValue >= assets ? totalPrincipalValue - assets : 0;
            }
            
            // Burn shares immediately since we're paying out directly
            _burn(owner, shares);
            
            // Transfer fee to fees wallet if any
            if (feeAmount > 0) {
                IERC20(asset()).safeTransfer(feesWallet, feeAmount);
                emit FeesCollected(feesWallet, feeAmount);
            }
            
            // Transfer remaining assets to receiver
            uint256 userAmount = assets - feeAmount;
            IERC20(asset()).safeTransfer(receiver, userAmount);
            
            emit Withdraw(msg.sender, receiver, owner, userAmount, shares);
            return;
        }
        
        // Not enough idle balance - need to request from Maple pool
        // Calculate fees on earned yield BEFORE requesting withdrawal from Maple
        // (so the fee/principal math uses the pre-withdraw NAV).
        
        // Simplified fee calculation - only if there's yield and shares exist
        if (totalShares > 0 && totalPrincipalValue > 0) {
            uint256 assetsBeforeWithdraw = totalAssets();
            
            // Only calculate fee if there's actual yield
            if (assetsBeforeWithdraw > totalPrincipalValue) {
                uint256 totalYield = assetsBeforeWithdraw - totalPrincipalValue;
                uint256 userYieldShare = (shares * totalYield) / totalShares;
                feeAmount = (userYieldShare * feePercentage) / 10000;
                
                // Update totalPrincipal
                uint256 principalPortion = assets - userYieldShare;
                totalPrincipal = totalPrincipalValue >= principalPortion ? totalPrincipalValue - principalPortion : 0;
            } else {
                // No yield, just update totalPrincipal
                totalPrincipal = totalPrincipalValue >= assets ? totalPrincipalValue - assets : 0;
            }
        } else {
            // First withdrawal or no shares, update totalPrincipal
            totalPrincipal = totalPrincipalValue >= assets ? totalPrincipalValue - assets : 0;
        }

        // Request withdrawal from Maple pool (asynchronous)
        // If this reverts, all state updates above revert too.
        _requestMapleWithdrawal(assets);
        
        // Check if assets arrived immediately
        // In production, Maple processes asynchronously, so this will typically be false
        uint256 assetBalanceAfter = IERC20(asset()).balanceOf(address(this));
        if (assetBalanceAfter >= assets) {
            // Assets arrived immediately - complete withdrawal now instead of creating pending
            _burn(owner, shares);
            
            // Transfer fee to fees wallet if any
            if (feeAmount > 0) {
                IERC20(asset()).safeTransfer(feesWallet, feeAmount);
                emit FeesCollected(feesWallet, feeAmount);
            }
            
            // Transfer remaining assets to receiver
            uint256 userAmount = assets - feeAmount;
            IERC20(asset()).safeTransfer(receiver, userAmount);
            
            emit Withdraw(msg.sender, receiver, owner, userAmount, shares);
            return;
        }
        
        // Assets not yet received - store pending withdrawal
        // Shares will be burned only after Maple pool completes the withdrawal
        pendingWithdrawals[withdrawalKey] = PendingWithdrawal({
            owner: owner,
            assets: assets,
            shares: shares,
            fee: feeAmount,
            completed: false
        });
        
        emit WithdrawalRequested(owner, receiver, assets, shares);
    }

    /**
     * @dev Get pending withdrawal for specific owner and receiver
     * @param receiver The receiver address
     * @param owner The owner address
     * @return pending The pending withdrawal struct
     */
    function getPendingWithdrawal(address receiver, address owner) external view returns (PendingWithdrawal memory pending) {
        bytes32 withdrawalKey = _getWithdrawalKey(receiver, owner);
        return pendingWithdrawals[withdrawalKey];
    }

    // =========================================================================
    //                            Admin Controls
    // =========================================================================

    /// @notice Toggle deposits (narrow circuit breaker). Withdraws are always allowed.
    function setDepositsDisabled(bool disabled) external onlyOwner {
        depositsDisabled = disabled;
        emit DepositsDisabled(disabled);
    }

    /// @notice Set/update TVL cap in underlying units. 0 disables cap.
    function setCap(uint256 newCap) external onlyOwner {
        tvlCap = newCap;
        emit CapUpdated(newCap);
    }

    /// @notice Set permission manager address (optional, for gas savings)
    /// @dev This can be set to cache the permission manager address
    /// @param _permissionManager The permission manager address
    function setPermissionManager(address _permissionManager) external onlyOwner {
        if (_permissionManager == address(0)) revert ZeroAddress();
        permissionManager = _permissionManager;
        emit PermissionManagerUpdated(_permissionManager);
    }

    /// @notice Check if the vault is authorized for the pool (Step 1 of deposit guide)
    /// @dev Determines lender authorization on-chain via PoolPermissionManager
    /// @return true if authorized, false otherwise
    function isAuthorized() public view returns (bool) {
        address pm = permissionManager;
        
        // Try to get permission manager from router if not cached
        if (pm == address(0)) {
            try ISyrupRouter(address(syrupRouter)).permissionManager() returns (address _pm) {
                pm = _pm;
            } catch {
                try ISyrupRouter(address(syrupRouter)).PERMISSION_MANAGER() returns (address _pm) {
                    pm = _pm;
                } catch {
                    return false; // Can't determine, assume not authorized
                }
            }
        }
        
        if (pm == address(0)) return false;
        
        // Check authorization via permission manager
        try IPoolPermissionManager(pm).isAuthorized(address(this), address(maplePool)) returns (bool authorized) {
            return authorized;
        } catch {
            try IPoolPermissionManager(pm).authorized(address(this), address(maplePool)) returns (bool authorized) {
                return authorized;
            } catch {
                return false; // Can't determine, assume not authorized
            }
        }
    }

    // =========================================================================
    //                        Internal Guardrails & Overrides
    // =========================================================================

    /// @dev Enforce cap and deposit switch on actual deposit/mint entry points.
    /// @notice Manually handles deposit logic to work with USDC proxy pattern.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0) {
            uint256 nextAssets = totalAssets() + assets;
            if (nextAssets > tvlCap) revert CapExceeded();
        }
        
        // Manually handle ERC4626 deposit logic
        // We use safeTransferFrom directly and manually handle the ERC4626 logic
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        
        // Manually handle ERC4626 deposit logic (mint shares, emit event)
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
        
        // Track principal deposited
        totalPrincipal += assets;
        
        // Deposit via router (contract must be whitelisted by Maple Finance first)
        // Approve router to pull tokens
        _safeApproveMax(address(asset()), address(syrupRouter), assets);
        
        // Call deposit on the router with deposit data "0:BITPULSE"
        syrupRouter.deposit(assets, DEPOSIT_DATA);
    }

    /// @dev Helper for safe approvals (handles tokens that require zeroing allowance first).
    function _safeApproveMax(address token, address spender, uint256 amount) internal {
        uint256 current = IERC20(token).allowance(address(this), spender);
        if (current < amount) {
            if (current != 0) {
                IERC20(token).approve(spender, 0);
            }
            IERC20(token).approve(spender, amount);
        }
    }

}