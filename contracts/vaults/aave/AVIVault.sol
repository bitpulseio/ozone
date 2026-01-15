// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * AVIVault (ERC-4626) — Minimal pass-through wrapper for Aave v3
 * - Asset: any ERC20 supported by Aave v3 (e.g., USDC)
 * - Shares: ERC20 receipt token (Bitpulse-branded claim token, e.g., bpUSDC)
 * - totalAssets() = aToken.balanceOf(address(this)) (includes Aave interest)
 * - After deposit → supply() to Aave
 * - Before withdraw → withdraw() from Aave
 * - MVP: no oracle reads, no reward valuation, withdrawals always open
 */

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken is IERC20 {}

contract AVIVault is ERC4626, ReentrancyGuard, Ownable2Step {
    IAavePool public immutable aavePool;
    IAToken public immutable aToken;
    address public immutable feesWallet;
    uint256 public immutable feePercentage; // bps

    bool public depositsDisabled;
    uint256 public tvlCap;
    uint256 public totalPrincipal;

    event DepositsDisabled(bool disabled);
    event CapUpdated(uint256 newCap);
    event FeesCollected(address indexed feesWallet, uint256 amount);

    error DepositsDisabledErr();
    error CapExceeded();
    error ZeroAddress();
    error InvalidFeePercentage();

    constructor(
        IERC20 underlying,
        address _aavePool,
        address _aToken,
        address _feesWallet,
        uint256 _feePercentage,
        string memory assetSymbol
    )
        ERC20(string.concat("Bitpulse ", assetSymbol, " Claim (AVI)"), string.concat("bp", assetSymbol))
        ERC4626(underlying)
        Ownable(msg.sender)
    {
        if (_aavePool == address(0) || _aToken == address(0)) revert ZeroAddress();
        if (_feesWallet == address(0)) revert ZeroAddress();
        if (_feePercentage > 10000) revert InvalidFeePercentage();

        aavePool = IAavePool(_aavePool);
        aToken = IAToken(_aToken);
        feesWallet = _feesWallet;
        feePercentage = _feePercentage;
    }

    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (depositsDisabled) return 0;
        if (tvlCap == 0) return type(uint256).max;
        uint256 assetsNow = totalAssets();
        if (assetsNow >= tvlCap) return 0;
        return tvlCap - assetsNow;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override {
        uint256 fee = 0;
        uint256 totalShares = totalSupply();
        uint256 assetsBeforeWithdraw = totalAssets();

        if (totalShares > 0 && totalPrincipal < assetsBeforeWithdraw) {
            uint256 totalYield = assetsBeforeWithdraw - totalPrincipal;
            uint256 userYieldShare = (shares * totalYield) / totalShares;
            fee = (userYieldShare * feePercentage) / 10000;

            uint256 principalPortion = assets - userYieldShare;
            if (totalPrincipal >= principalPortion) totalPrincipal -= principalPortion;
            else totalPrincipal = 0;
        } else {
            if (totalPrincipal >= assets) totalPrincipal -= assets;
            else totalPrincipal = 0;
        }

        aavePool.withdraw(address(asset()), assets, address(this));

        if (fee > 0) {
            IERC20(asset()).transfer(feesWallet, fee);
            emit FeesCollected(feesWallet, fee);
        }

        uint256 userAmount = assets - fee;
        IERC20(asset()).transfer(receiver, userAmount);

        _burn(owner, shares);
        emit Withdraw(caller, receiver, owner, userAmount, shares);
    }

    function setDepositsDisabled(bool disabled) external onlyOwner {
        depositsDisabled = disabled;
        emit DepositsDisabled(disabled);
    }

    function setCap(uint256 newCap) external onlyOwner {
        tvlCap = newCap;
        emit CapUpdated(newCap);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0) {
            uint256 nextAssets = totalAssets() + assets;
            if (nextAssets > tvlCap) revert CapExceeded();
        }
        super._deposit(caller, receiver, assets, shares);

        totalPrincipal += assets;

        _safeApproveMax(address(asset()), address(aavePool), assets);
        aavePool.supply(address(asset()), assets, address(this), 0);
    }

    function _safeApproveMax(address token, address spender, uint256 amount) internal {
        uint256 current = IERC20(token).allowance(address(this), spender);
        if (current < amount) {
            if (current != 0) IERC20(token).approve(spender, 0);
            IERC20(token).approve(spender, type(uint256).max);
        }
    }
}

