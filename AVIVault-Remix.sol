// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AVIVault - AAVE Vault Interface
 * @notice Minimal ERC-4626 vault that wraps AAVE v3 lending pools
 * @dev Remix-compatible version with GitHub imports
 * 
 * Features:
 * - ERC-4626 compliant vault interface
 * - Direct AAVE v3 integration (supply/withdraw)
 * - Branded claim tokens (bpUSDC, bpUSDT, etc.)
 * - Admin controls: TVL cap, deposit circuit breaker
 * - Always-open withdrawals (no custody risk)
 */

import "@openzeppelin/contracts@5.0.1/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@5.0.1/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@5.0.1/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts@5.0.1/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts@5.0.1/access/Ownable2Step.sol";
import "@openzeppelin/contracts@5.0.1/access/Ownable.sol";

// Minimal AAVE v3 interfaces
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken is IERC20 {
    // aToken balance includes accrued interest
}

contract AVIVault is ERC4626, ReentrancyGuard, Ownable2Step {
    
    // ============ Immutable Config ============
    
    IAavePool public immutable aavePool;
    IAToken public immutable aToken;
    
    // ============ State Variables ============
    
    bool public depositsDisabled;    // Circuit breaker (deposits only)
    uint256 public tvlCap;           // Max totalAssets (0 = unlimited)
    
    // ============ Events ============
    
    event DepositsDisabled(bool disabled);
    event CapUpdated(uint256 newCap);
    
    // ============ Errors ============
    
    error DepositsDisabledErr();
    error CapExceeded();
    error ZeroAddress();
    
    // ============ Constructor ============
    
    /**
     * @param underlying The ERC20 asset (USDC, USDT, WBTC, etc.)
     * @param _aavePool AAVE v3 Pool contract address
     * @param _aToken Corresponding aToken address (aUSDC, aUSDT, etc.)
     * @param assetSymbol Symbol for branding (e.g., "USDC")
     */
    constructor(
        IERC20 underlying,
        address _aavePool,
        address _aToken,
        string memory assetSymbol
    )
        ERC20(
            string.concat("Bitpulse ", assetSymbol, " Vault"),
            string.concat("bp", assetSymbol)
        )
        ERC4626(underlying)
        Ownable(msg.sender)
    {
        if (_aavePool == address(0) || _aToken == address(0)) revert ZeroAddress();
        aavePool = IAavePool(_aavePool);
        aToken = IAToken(_aToken);
    }
    
    // ============ ERC-4626 Core ============
    
    /**
     * @notice Total assets = aToken balance (includes AAVE interest)
     */
    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }
    
    /**
     * @notice Max deposit respects circuit breaker and TVL cap
     */
    function maxDeposit(address) public view override returns (uint256) {
        if (depositsDisabled) return 0;
        if (tvlCap == 0) return type(uint256).max;
        
        uint256 current = totalAssets();
        if (current >= tvlCap) return 0;
        return tvlCap - current;
    }
    
    // ============ Internal Hooks ============
    
    /**
     * @dev After deposit: supply to AAVE
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        // Check guardrails
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0 && totalAssets() + assets > tvlCap) revert CapExceeded();
        
        // Standard ERC4626 deposit (transfers assets to vault, mints shares)
        super._deposit(caller, receiver, assets, shares);
        
        // Supply to AAVE
        _approveAave(assets);
        aavePool.supply(address(asset()), assets, address(this), 0);
    }
    
    /**
     * @dev Before withdraw: pull from AAVE
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        // Withdraw from AAVE first
        aavePool.withdraw(address(asset()), assets, address(this));
        
        // Standard ERC4626 withdraw (burns shares, transfers assets)
        super._withdraw(caller, receiver, owner, assets, shares);
    }
    
    // ============ Admin Controls ============
    
    /**
     * @notice Toggle deposit circuit breaker (withdrawals always open)
     */
    function setDepositsDisabled(bool disabled) external onlyOwner {
        depositsDisabled = disabled;
        emit DepositsDisabled(disabled);
    }
    
    /**
     * @notice Set TVL cap (0 = unlimited)
     */
    function setCap(uint256 newCap) external onlyOwner {
        tvlCap = newCap;
        emit CapUpdated(newCap);
    }
    
    // ============ Helpers ============
    
    function _approveAave(uint256 amount) internal {
        IERC20 underlying = IERC20(asset());
        uint256 currentAllowance = underlying.allowance(address(this), address(aavePool));
        
        if (currentAllowance < amount) {
            if (currentAllowance > 0) {
                underlying.approve(address(aavePool), 0);
            }
            underlying.approve(address(aavePool), type(uint256).max);
        }
    }
}

