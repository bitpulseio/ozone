// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Remix-oriented example contract.
 *
 * This file exists for convenience when using Remix with GitHub imports.
 * It is NOT part of the canonical compilation path for this repo:
 * - Hardhat sources: `contracts/`
 * - Foundry src: `contracts/`
 */

import "@openzeppelin/contracts@5.0.1/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@5.0.1/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@5.0.1/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts@5.0.1/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts@5.0.1/access/Ownable2Step.sol";
import "@openzeppelin/contracts@5.0.1/access/Ownable.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken is IERC20 {}

contract AVIVault is ERC4626, ReentrancyGuard, Ownable2Step {
    IAavePool public immutable aavePool;
    IAToken public immutable aToken;

    bool public depositsDisabled;
    uint256 public tvlCap;

    event DepositsDisabled(bool disabled);
    event CapUpdated(uint256 newCap);

    error DepositsDisabledErr();
    error CapExceeded();
    error ZeroAddress();

    constructor(IERC20 underlying, address _aavePool, address _aToken, string memory assetSymbol)
        ERC20(string.concat("Bitpulse ", assetSymbol, " Vault"), string.concat("bp", assetSymbol))
        ERC4626(underlying)
        Ownable(msg.sender)
    {
        if (_aavePool == address(0) || _aToken == address(0)) revert ZeroAddress();
        aavePool = IAavePool(_aavePool);
        aToken = IAToken(_aToken);
    }

    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (depositsDisabled) return 0;
        if (tvlCap == 0) return type(uint256).max;
        uint256 current = totalAssets();
        if (current >= tvlCap) return 0;
        return tvlCap - current;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0 && totalAssets() + assets > tvlCap) revert CapExceeded();
        super._deposit(caller, receiver, assets, shares);
        _approveAave(assets);
        aavePool.supply(address(asset()), assets, address(this), 0);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        aavePool.withdraw(address(asset()), assets, address(this));
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function setDepositsDisabled(bool disabled) external onlyOwner {
        depositsDisabled = disabled;
        emit DepositsDisabled(disabled);
    }

    function setCap(uint256 newCap) external onlyOwner {
        tvlCap = newCap;
        emit CapUpdated(newCap);
    }

    function _approveAave(uint256 amount) internal {
        IERC20 underlying = IERC20(asset());
        uint256 currentAllowance = underlying.allowance(address(this), address(aavePool));
        if (currentAllowance < amount) {
            if (currentAllowance > 0) underlying.approve(address(aavePool), 0);
            underlying.approve(address(aavePool), type(uint256).max);
        }
    }
}

