// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal SyrupRouter mock with depositAuthorized(pool, amount).
/// Pulls underlying from caller and tells pool to mint shares to caller 1:1.
interface IMockPoolMint {
    function mintShares(address to, uint256 shares) external;
}

contract MockSyrupRouter {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;

    constructor(IERC20 underlying_) {
        underlying = underlying_;
    }

    function depositAuthorized(address pool, uint256 amount) external returns (uint256) {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        IMockPoolMint(pool).mintShares(msg.sender, amount);
        return amount;
    }

    function permissionManager() external pure returns (address) {
        return address(0);
    }

    function PERMISSION_MANAGER() external pure returns (address) {
        return address(0);
    }
}


