// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * MapleVault (ERC-4626) — Minimal pass-through wrapper for Maple Finance
 * - Asset: any ERC20 supported by Maple Finance pool (e.g., USDC)
 * - Shares: ERC20 receipt token (Bitpulse-branded claim token, e.g., bpUSDC)
 * - totalAssets() includes:
 *   - idle underlying sitting in the vault, plus
 *   - underlying value of Maple pool shares (converted to exit assets)
 * - Deposits: via SyrupRouter
 * - Withdrawals: may be asynchronous (queued redemptions) depending on Maple pool behavior
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
    function deposit(uint256 amount) external returns (uint256);
    function deposit(address asset, uint256 amount) external returns (uint256);

    function balanceOf(address account) external view returns (uint256);
    function convertToExitAssets(uint256 shares) external view returns (uint256);
    function convertToExitShares(uint256 assets) external view returns (uint256);

    /// @notice On Sepolia pool `0x2d8D...`, the signature is `requestRedeem(uint256,address)` (selector `0x107703ab`).
    function requestRedeem(uint256 shares, address owner) external returns (uint256);
}

interface IPoolPermissionManager {
    function isAuthorized(address account, address pool) external view returns (bool);
    function authorized(address account, address pool) external view returns (bool);
}

interface ISyrupRouter {
    function deposit(uint256 amount, bytes32 depositData) external returns (uint256 shares);
    function permissionManager() external view returns (address);
    function PERMISSION_MANAGER() external view returns (address);
}

interface ISyrupToken is IERC20 {
    // Syrup token is ERC20-compatible; balanceOf reflects accrued interest.
}

/// @title MapleVault
/// @notice ERC-4626 vault that pass-throughs deposits to Maple Finance and holds Maple pool shares.
contract MapleVault is ERC4626, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // --- Immutable configuration ---
    IMaplePool public immutable maplePool;
    ISyrupRouter public immutable syrupRouter;
    ISyrupToken public immutable syrupToken;
    address public immutable feesWallet;
    uint256 public immutable feePercentage; // bps

    // --- Vault controls ---
    bool public depositsDisabled;
    uint256 public tvlCap; // 0 = no cap
    uint256 public totalPrincipal;
    address public permissionManager;

    // --- Pending withdrawals tracking ---
    struct PendingWithdrawal {
        address owner;
        uint256 assets;
        uint256 shares;
        uint256 fee;
        bool completed;
    }

    mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals;

    function _getWithdrawalKey(address receiver, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(receiver, owner));
    }

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
    error WithdrawalPending();

    constructor(
        IERC20 underlying,
        address _maplePool,
        address _syrupRouter,
        address _syrupToken,
        address _feesWallet,
        uint256 _feePercentage,
        string memory assetSymbol
    )
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

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 poolShares = maplePool.balanceOf(address(this));
        uint256 inPool = poolShares == 0 ? 0 : maplePool.convertToExitAssets(poolShares);
        return idle + inPool;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (depositsDisabled) return 0;
        if (tvlCap == 0) return type(uint256).max;

        uint256 assetsNow = totalAssets();
        if (assetsNow >= tvlCap) return 0;
        return tvlCap - assetsNow;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return super.convertToShares(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return super.convertToAssets(shares);
    }

    function _requestMapleWithdrawal(uint256 assets) internal {
        uint256 poolShares = maplePool.balanceOf(address(this));
        uint256 sharesToRedeem = maplePool.convertToExitShares(assets);
        if (poolShares < sharesToRedeem) revert("Insufficient shares in pool");
        maplePool.requestRedeem(sharesToRedeem, address(this));
    }

    function _withdraw(address, address receiver, address owner, uint256 assets, uint256 shares) internal override nonReentrant {
        bytes32 withdrawalKey = _getWithdrawalKey(receiver, owner);
        PendingWithdrawal storage pending = pendingWithdrawals[withdrawalKey];

        if (pending.assets > 0) {
            if (pending.completed) revert NoPendingWithdrawal();

            uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
            if (assetBalance >= pending.assets) {
                pending.completed = true;

                _burn(owner, pending.shares);

                uint256 _pendingFee = pending.fee;
                if (_pendingFee > 0) {
                    IERC20(asset()).safeTransfer(feesWallet, _pendingFee);
                    emit FeesCollected(feesWallet, _pendingFee);
                }

                uint256 userAmount = pending.assets - _pendingFee;
                IERC20(asset()).safeTransfer(receiver, userAmount);

                emit WithdrawalCompleted(owner, receiver, pending.assets, pending.shares);
                emit Withdraw(msg.sender, receiver, owner, userAmount, pending.shares);

                delete pendingWithdrawals[withdrawalKey];
                return;
            }

            revert WithdrawalPending();
        }

        uint256 feeAmount = 0;
        uint256 totalShares = totalSupply();
        uint256 totalPrincipalValue = totalPrincipal;

        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));
        if (idleBalance >= assets) {
            if (totalShares > 0 && totalPrincipalValue > 0) {
                uint256 assetsBeforeWithdraw = totalAssets();
                if (assetsBeforeWithdraw > totalPrincipalValue) {
                    uint256 totalYield = assetsBeforeWithdraw - totalPrincipalValue;
                    uint256 userYieldShare = (shares * totalYield) / totalShares;
                    feeAmount = (userYieldShare * feePercentage) / 10000;
                    uint256 principalPortion = assets - userYieldShare;
                    totalPrincipal = totalPrincipalValue >= principalPortion ? totalPrincipalValue - principalPortion : 0;
                } else {
                    totalPrincipal = totalPrincipalValue >= assets ? totalPrincipalValue - assets : 0;
                }
            } else {
                totalPrincipal = totalPrincipalValue >= assets ? totalPrincipalValue - assets : 0;
            }

            _burn(owner, shares);

            if (feeAmount > 0) {
                IERC20(asset()).safeTransfer(feesWallet, feeAmount);
                emit FeesCollected(feesWallet, feeAmount);
            }

            uint256 userAmount = assets - feeAmount;
            IERC20(asset()).safeTransfer(receiver, userAmount);
            emit Withdraw(msg.sender, receiver, owner, userAmount, shares);
            return;
        }

        if (totalShares > 0 && totalPrincipalValue > 0) {
            uint256 assetsBeforeWithdraw = totalAssets();
            if (assetsBeforeWithdraw > totalPrincipalValue) {
                uint256 totalYield = assetsBeforeWithdraw - totalPrincipalValue;
                uint256 userYieldShare = (shares * totalYield) / totalShares;
                feeAmount = (userYieldShare * feePercentage) / 10000;
                uint256 principalPortion = assets - userYieldShare;
                totalPrincipal = totalPrincipalValue >= principalPortion ? totalPrincipalValue - principalPortion : 0;
            } else {
                totalPrincipal = totalPrincipalValue >= assets ? totalPrincipalValue - assets : 0;
            }
        } else {
            totalPrincipal = totalPrincipalValue >= assets ? totalPrincipalValue - assets : 0;
        }

        _requestMapleWithdrawal(assets);

        uint256 assetBalanceAfter = IERC20(asset()).balanceOf(address(this));
        if (assetBalanceAfter >= assets) {
            _burn(owner, shares);
            if (feeAmount > 0) {
                IERC20(asset()).safeTransfer(feesWallet, feeAmount);
                emit FeesCollected(feesWallet, feeAmount);
            }
            uint256 userAmount = assets - feeAmount;
            IERC20(asset()).safeTransfer(receiver, userAmount);
            emit Withdraw(msg.sender, receiver, owner, userAmount, shares);
            return;
        }

        pendingWithdrawals[withdrawalKey] = PendingWithdrawal({
            owner: owner,
            assets: assets,
            shares: shares,
            fee: feeAmount,
            completed: false
        });

        emit WithdrawalRequested(owner, receiver, assets, shares);
    }

    function getPendingWithdrawal(address receiver, address owner) external view returns (PendingWithdrawal memory pending) {
        bytes32 withdrawalKey = _getWithdrawalKey(receiver, owner);
        return pendingWithdrawals[withdrawalKey];
    }

    // =========================================================================
    //                            Admin Controls
    // =========================================================================

    function setDepositsDisabled(bool disabled) external onlyOwner {
        depositsDisabled = disabled;
        emit DepositsDisabled(disabled);
    }

    function setCap(uint256 newCap) external onlyOwner {
        tvlCap = newCap;
        emit CapUpdated(newCap);
    }

    function setPermissionManager(address _permissionManager) external onlyOwner {
        if (_permissionManager == address(0)) revert ZeroAddress();
        permissionManager = _permissionManager;
        emit PermissionManagerUpdated(_permissionManager);
    }

    function isAuthorized() public view returns (bool) {
        address pm = permissionManager;
        if (pm == address(0)) {
            try ISyrupRouter(address(syrupRouter)).permissionManager() returns (address _pm) {
                pm = _pm;
            } catch {
                try ISyrupRouter(address(syrupRouter)).PERMISSION_MANAGER() returns (address _pm) {
                    pm = _pm;
                } catch {
                    return false;
                }
            }
        }

        if (pm == address(0)) return false;

        try IPoolPermissionManager(pm).isAuthorized(address(this), address(maplePool)) returns (bool authorized) {
            return authorized;
        } catch {
            try IPoolPermissionManager(pm).authorized(address(this), address(maplePool)) returns (bool authorized) {
                return authorized;
            } catch {
                return false;
            }
        }
    }

    // =========================================================================
    //                        Internal Guardrails & Overrides
    // =========================================================================

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0) {
            uint256 nextAssets = totalAssets() + assets;
            if (nextAssets > tvlCap) revert CapExceeded();
        }

        IERC20(asset()).safeTransferFrom(caller, address(this), assets);

        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);

        totalPrincipal += assets;

        _safeApproveMax(address(asset()), address(syrupRouter), assets);
        syrupRouter.deposit(assets, DEPOSIT_DATA);
    }

    function _safeApproveMax(address token, address spender, uint256 amount) internal {
        uint256 current = IERC20(token).allowance(address(this), spender);
        if (current < amount) {
            if (current != 0) IERC20(token).approve(spender, 0);
            IERC20(token).approve(spender, amount);
        }
    }
}

