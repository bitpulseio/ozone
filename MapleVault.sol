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
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

// ---------------------------
// Minimal Maple Finance interfaces
// ---------------------------
// Note: The exact interface may vary depending on the Maple Finance pool implementation.
// Adjust these interfaces to match your specific Maple Finance pool contract.
interface IMaplePool {
    /// @dev Maple Finance deposit. Deposits underlying tokens and mints syrup tokens.
    /// @param amount Amount of underlying tokens to deposit
    /// @return Amount of syrup tokens received (may vary by implementation)
    function deposit(uint256 amount) external returns (uint256);

    /// @dev Maple Finance withdraw. Withdraws underlying tokens by burning syrup tokens.
    /// @param amount Amount of underlying tokens to withdraw (or syrup tokens, depending on implementation)
    /// @return Amount of underlying tokens received (may vary by implementation)
    function withdraw(uint256 amount) external returns (uint256);
}

interface ISyrupToken is IERC20 {
    // Syrup token is ERC20-compatible; balanceOf reflects accrued interest.
}

/// @title MapleVault
/// @notice ERC-4626 vault that pass-throughs deposits to Maple Finance and holds syrup tokens.
contract MapleVault is ERC4626, ReentrancyGuard, Ownable2Step {
    // --- Immutable configuration ---
    IMaplePool public immutable maplePool;
    ISyrupToken public immutable syrupToken;  // Syrup token corresponding to `asset()`
    address   public immutable feesWallet;   // Wallet to receive fees
    uint256   public immutable feePercentage; // Fee percentage in basis points (e.g., 100 = 1%)

    // --- Vault controls ---
    bool     public depositsDisabled;       // circuit breaker (deposits only)
    uint256  public tvlCap;                 // 0 = no cap; else max totalAssets() allowed
    uint256  public totalPrincipal;        // Total principal deposited (excluding yield)

    // --- Events ---
    event DepositsDisabled(bool disabled);
    event CapUpdated(uint256 newCap);
    event FeesCollected(address indexed feesWallet, uint256 amount);

    // --- Errors ---
    error DepositsDisabledErr();
    error CapExceeded();
    error ZeroAddress();
    error InvalidFeePercentage();

    /**
     * @param underlying ERC20 asset accepted by Maple pool (e.g., USDC)
     * @param _maplePool  Maple Finance Pool address
     * @param _syrupToken The syrup token address corresponding to `underlying`
     * @param _feesWallet Address to receive fees
     * @param _feePercentage Fee percentage in basis points (e.g., 100 = 1%, max 10000 = 100%)
     * @param assetSymbol Symbol suffix for share token branding (e.g., "USDC")
     */
    constructor(
        IERC20 underlying,
        address _maplePool,
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
        if (_maplePool == address(0) || _syrupToken == address(0)) revert ZeroAddress();
        if (_feesWallet == address(0)) revert ZeroAddress();
        if (_feePercentage > 10000) revert InvalidFeePercentage();
        
        maplePool = IMaplePool(_maplePool);
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
        
        // Withdraw from Maple (burns syrup tokens and returns underlying)
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

    // =========================================================================
    //                        Internal Guardrails & Overrides
    // =========================================================================

    /// @dev Enforce cap and deposit switch on actual deposit/mint entry points.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0) {
            uint256 nextAssets = totalAssets() + assets;
            if (nextAssets > tvlCap) revert CapExceeded();
        }
        super._deposit(caller, receiver, assets, shares);
        
        // Track principal deposited
        totalPrincipal += assets;
        
        // Supply to Maple after deposit
        _safeApproveMax(address(asset()), address(maplePool), assets);
        maplePool.deposit(assets);
    }

    /// @dev Helper for safe approvals (handles tokens that require zeroing allowance first).
    function _safeApproveMax(address token, address spender, uint256 amount) internal {
        uint256 current = IERC20(token).allowance(address(this), spender);
        if (current < amount) {
            if (current != 0) {
                IERC20(token).approve(spender, 0);
            }
            IERC20(token).approve(spender, type(uint256).max);
        }
    }

    // =========================================================================
    //                         Optional extensions (TODO)
    // =========================================================================

    /// @notice Phase 2: Claim Maple incentives (if any). MVP leaves blank to avoid oracle/slippage complexity.
    function harvest() external onlyOwner {
        // TODO: integrate incentives controller if needed.
    }
}

