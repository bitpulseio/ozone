// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal PoolV2-like mock:
/// - shares token is this ERC20
/// - requestRedeem burns shares from caller and transfers underlying to receiver immediately (synchronous mock)
/// - convertToExitAssets / convertToExitShares use a configurable exchange rate
contract MockPoolV2 is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;

    // exchange rate in underlying per 1 share, scaled by 1e18
    uint256 public rateWad;

    constructor(IERC20 underlying_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        underlying = underlying_;
        rateWad = 1e18;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function setRateWad(uint256 newRateWad) external {
        rateWad = newRateWad;
    }

    function convertToExitAssets(uint256 shares) external view returns (uint256 assets) {
        // assets = shares * rate
        return (shares * rateWad) / 1e18;
    }

    function convertToExitShares(uint256 assets) external view returns (uint256 shares) {
        // shares = assets / rate (rounding down)
        return (assets * 1e18) / rateWad;
    }

    function mintShares(address to, uint256 shares) external {
        _mint(to, shares);
    }

    function requestRedeem(uint256 shares, address receiver) external returns (uint256 assets) {
        _burn(msg.sender, shares);
        assets = (shares * rateWad) / 1e18;
        underlying.safeTransfer(receiver, assets);
    }
}


