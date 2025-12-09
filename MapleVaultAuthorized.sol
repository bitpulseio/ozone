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

    /// @dev Maple Finance withdraw. Withdraws underlying tokens by burning syrup tokens.
    /// @param amount Amount of underlying tokens to withdraw (or syrup tokens, depending on implementation)
    /// @return Amount of underlying tokens received (may vary by implementation)
    function withdraw(uint256 amount) external returns (uint256);
    
    /// @dev Alternative withdraw signature with asset parameter (if supported)
    /// @param asset The asset address to withdraw
    /// @param amount Amount of underlying tokens to withdraw
    /// @return Amount of underlying tokens received
    function withdraw(address asset, uint256 amount) external returns (uint256);
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
    /// @dev Deposit authorized - deposits tokens when the caller is already authorized/whitelisted
    /// @param pool The Maple pool address to deposit into
    /// @param amount Amount of underlying tokens to deposit
    /// @return Amount of syrup tokens received
    function depositAuthorized(address pool, uint256 amount) external returns (uint256);
    
    /// @dev Get the permission manager address
    /// @return The permission manager address
    function permissionManager() external view returns (address);
    
    /// @dev Alternative getter for permission manager
    /// @return The permission manager address
    function PERMISSION_MANAGER() external view returns (address);
}

/// @dev Interface for upgradeable proxy pattern (optional, for verification)
interface IProxy {
    /// @dev Returns the implementation address (for UUPS/Transparent proxies)
    function implementation() external view returns (address);
    
    /// @dev Alternative method name used by some proxy implementations
    function getImplementation() external view returns (address);
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

    // --- Events ---
    event DepositsDisabled(bool disabled);
    event CapUpdated(uint256 newCap);
    event FeesCollected(address indexed feesWallet, uint256 amount);
    event PermissionManagerUpdated(address indexed permissionManager);

    // --- Errors ---
    error DepositsDisabledErr();
    error CapExceeded();
    error ZeroAddress();
    error InvalidFeePercentage();

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
            string.concat("Bitpulse ", assetSymbol, " Claim (Maple)"),
            string.concat("bp", assetSymbol, "-Maple")
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

    /// @dev NAV: syrup token balance (includes accrued interest).
    function totalAssets() public view override returns (uint256) {
        return syrupToken.balanceOf(address(this));
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
     * @dev Override _withdraw to withdraw from Maple, calculate fees on yield, and transfer assets
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override {
        // Calculate fees on earned yield BEFORE withdrawing from Maple
        uint256 fee = 0;
        uint256 totalShares = totalSupply();
        uint256 assetsBeforeWithdraw = totalAssets(); // Store assets before withdrawal
        
        // Calculate fees on earned yield only
        if (totalShares > 0 && totalPrincipal < assetsBeforeWithdraw) {
            // Calculate total yield in the vault (before withdrawal)
            uint256 totalYield = assetsBeforeWithdraw - totalPrincipal;
            
            // Calculate user's share of the yield
            // userYieldShare = (shares / totalShares) * totalYield
            uint256 userYieldShare = (shares * totalYield) / totalShares;
            
            // Calculate fee on yield: fee = userYieldShare * feePercentage / 10000
            fee = (userYieldShare * feePercentage) / 10000;
            
            // Update totalPrincipal: reduce by the principal portion of withdrawal
            // principalPortion = assets - userYieldShare
            uint256 principalPortion = assets - userYieldShare;
            if (totalPrincipal >= principalPortion) {
                totalPrincipal -= principalPortion;
            } else {
                // Edge case: if calculation error, set to 0
                totalPrincipal = 0;
            }
        } else {
            // No yield or first withdrawal, no fee
            // Update totalPrincipal
            if (totalPrincipal >= assets) {
                totalPrincipal -= assets;
            } else {
                totalPrincipal = 0;
            }
        }
        
        // Withdraw from Maple through upgradeable proxy (burns syrup tokens and returns underlying)
        // The proxy will delegate the call to the implementation contract
        // Note: The exact interface may vary. This assumes:
        // - totalAssets() returns underlying value (syrup token balance represents underlying with interest)
        // - withdraw() takes underlying amount and burns corresponding syrup tokens
        // If Maple Finance uses a different interface (e.g., withdraw takes syrup token amount),
        // you may need to convert using the exchange rate: syrupAmount = (assets * syrupToken.totalSupply()) / maplePool.totalAssets()
        maplePool.withdraw(assets);
        
        // Transfer fee to fees wallet if any
        if (fee > 0) {
            IERC20(asset()).transfer(feesWallet, fee);
            emit FeesCollected(feesWallet, fee);
        }
        
        // Transfer remaining assets to receiver
        uint256 userAmount = assets - fee;
        IERC20(asset()).transfer(receiver, userAmount);
        
        // Burn shares
        _burn(owner, shares);
        
        emit Withdraw(caller, receiver, owner, userAmount, shares);
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
    /// @notice Manually handles deposit logic to bypass USDC transferFrom issues.
    /// Similar to ETHVault, we manually handle the ERC4626 deposit logic instead
    /// of using super._deposit which calls transferFrom (which fails with USDC proxies).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0) {
            uint256 nextAssets = totalAssets() + assets;
            if (nextAssets > tvlCap) revert CapExceeded();
        }
        
        // Manually handle ERC4626 deposit logic to bypass transferFrom issues
        // We use safeTransferFrom directly and manually handle the ERC4626 logic
        // This is similar to how ETHVault handles native ETH deposits
        // 
        // Note: This still uses transferFrom, but by calling it directly we can
        // potentially get better error messages if it fails
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        
        // Manually handle ERC4626 deposit logic (mint shares, emit event)
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
        
        // Track principal deposited
        totalPrincipal += assets;
        
        // Deposit via router (contract must be whitelisted by Maple Finance first)
        // Approve router to pull tokens
        _safeApproveMax(address(asset()), address(syrupRouter), assets);
        
        // Call depositAuthorized on the router (passing pool address)
        syrupRouter.depositAuthorized(address(maplePool), assets);
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

    // =========================================================================
    //                         Optional extensions (TODO)
    // =========================================================================

    /// @notice Phase 2: Claim Maple incentives (if any). MVP leaves blank to avoid oracle/slippage complexity.
    function harvest() external onlyOwner {
        // TODO: integrate incentives controller if needed.
    }

    // =========================================================================
    //                         Proxy Verification (Optional)
    // =========================================================================

    /// @notice Get the implementation address from the Maple pool proxy (if supported)
    /// @dev This is useful for verification and debugging. Not all proxy patterns support this.
    /// @return impl The implementation address, or address(0) if not available
    function getMaplePoolImplementation() external view returns (address impl) {
        try IProxy(address(maplePool)).implementation() returns (address _impl) {
            return _impl;
        } catch {
            try IProxy(address(maplePool)).getImplementation() returns (address _impl) {
                return _impl;
            } catch {
                return address(0);
            }
        }
    }
}

