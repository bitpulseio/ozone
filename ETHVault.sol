// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

// ---------------------------
// Minimal Aave v3 interfaces
// ---------------------------
interface IAavePool {
    /// @dev Aave v3 supply
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @dev Aave v3 withdraw. Returns amount actually withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IWrappedTokenGateway {
    /// @dev Deposit ETH to Aave via WrappedTokenGateway
    function depositETH(address pool, address onBehalfOf, uint16 referralCode) external payable;
    
    /// @dev Withdraw ETH from Aave via WrappedTokenGateway
    function withdrawETH(address pool, uint256 amount, address onBehalfOf) external;
}

interface IAToken is IERC20 {
    // aToken is ERC20-compatible; balanceOf reflects accrued interest.
}

/// @title ETHVault
/// @notice ERC-4626 vault for native ETH deposits to Aave v3
/// @dev Uses a custom ETH asset wrapper for ERC4626 compliance
contract ETHVault is ERC4626, ReentrancyGuard, Ownable2Step {
    // --- Immutable configuration ---
    IAavePool public immutable aavePool;
    IAToken   public immutable aToken;      // aToken corresponding to WETH
    IWrappedTokenGateway public immutable wrappedTokenGateway; // Aave's WrappedTokenGateway

    // --- Vault controls ---
    bool     public depositsDisabled;       // circuit breaker (deposits only)
    uint256  public tvlCap;                 // 0 = no cap; else max totalAssets() allowed

    event DepositsDisabled(bool disabled);
    event CapUpdated(uint256 newCap);

    error DepositsDisabledErr();
    error CapExceeded();
    error ZeroAddress();
    error ETHTransferFailed();
    error AaveSupplyFailed();
    error AaveWithdrawFailed();
    error InvalidAToken();

    constructor(
        address _aavePool,
        address _aToken,
        address _wrappedTokenGateway,
        string memory assetSymbol
    )
        ERC20(
            string.concat("Bitpulse ", assetSymbol, " Claim (AVI)"),
            string.concat("bp", assetSymbol)
        )
        ERC4626(IERC20(address(0))) // Use address(0) for native ETH
        Ownable(msg.sender)
    {
        if (_aavePool == address(0)) revert ZeroAddress();
        if (_aToken == address(0)) revert ZeroAddress();
        if (_wrappedTokenGateway == address(0)) revert ZeroAddress();

        aavePool = IAavePool(_aavePool);
        aToken = IAToken(_aToken);
        wrappedTokenGateway = IWrappedTokenGateway(_wrappedTokenGateway);
    }

    // Receive native ETH
    receive() external payable {}

    // Override asset() to return address(0) for native ETH
    function asset() public pure override returns (address) {
        return address(0); // Native ETH
    }

    // --- ERC4626 Overrides ---

    function totalAssets() public view override returns (uint256) {
        // Total assets are the aTokens held by the vault
        return aToken.balanceOf(address(this));
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (depositsDisabled) return 0;
        if (tvlCap == 0) return type(uint256).max;

        uint256 assetsNow = totalAssets();
        if (assetsNow >= tvlCap) return 0;
        return tvlCap - assetsNow;
    }

    // --- Custom payable deposit function for ETH ---

    function depositETH(address receiver) public payable returns (uint256) {
        uint256 assets = msg.value;
        uint256 shares = convertToShares(assets);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    // --- Internal hooks for ERC4626 ---

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0) {
            uint256 nextAssets = totalAssets() + assets;
            if (nextAssets > tvlCap) revert CapExceeded();
        }

        // For native ETH deposits to Aave:
        // 1. Use Aave's WrappedTokenGateway to deposit ETH directly
        // 2. Manually handle the ERC4626 deposit logic

        // Deposit ETH to Aave via WrappedTokenGateway
        wrappedTokenGateway.depositETH{value: assets}(
            address(aavePool),
            address(this), // onBehalfOf - vault receives the aTokens
            0 // referralCode
        );

        // Manually handle ERC4626 deposit logic since we can't use transferFrom for native ETH
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override nonReentrant {
        // Approve WrappedTokenGateway to spend aEthWETH tokens
        aToken.approve(address(wrappedTokenGateway), assets);
        
        // Withdraw ETH from Aave via WrappedTokenGateway
        wrappedTokenGateway.withdrawETH(
            address(aavePool),
            assets,
            address(this) // onBehalfOf - vault withdraws
        );
        
        // Transfer ETH to receiver
        (bool success, ) = receiver.call{value: assets}("");
        if (!success) revert ETHTransferFailed();

        // Manually handle ERC4626 withdraw logic
        _burn(owner, shares);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    // --- Owner-only controls ---

    function setDepositsDisabled(bool disabled) external onlyOwner {
        depositsDisabled = disabled;
        emit DepositsDisabled(disabled);
    }

    function setCap(uint256 newCap) external onlyOwner {
        tvlCap = newCap;
        emit CapUpdated(newCap);
    }

    // --- Emergency functions ---

    function emergencyWithdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) revert ETHTransferFailed();
    }

    function emergencyWithdrawAToken() external onlyOwner {
        uint256 balance = aToken.balanceOf(address(this));
        aToken.transfer(owner(), balance);
    }
}