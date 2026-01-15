// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

interface IWrappedTokenGateway {
    function depositETH(address pool, address onBehalfOf, uint16 referralCode) external payable;
    function withdrawETH(address pool, uint256 amount, address onBehalfOf) external;
}

interface IAToken is IERC20 {}

/// @title ETHVault
/// @notice ERC-4626 vault for native ETH deposits to Aave v3
contract ETHVault is ERC4626, ReentrancyGuard, Ownable2Step {
    IAavePool public immutable aavePool;
    IAToken public immutable aToken;
    IWrappedTokenGateway public immutable wrappedTokenGateway;
    address public immutable feesWallet;
    uint256 public immutable feePercentage;

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
    error ETHTransferFailed();

    constructor(
        address _aavePool,
        address _aToken,
        address _wrappedTokenGateway,
        address _feesWallet,
        uint256 _feePercentage,
        string memory assetSymbol
    )
        ERC20(string.concat("Bitpulse ", assetSymbol, " Claim (AVI)"), string.concat("bp", assetSymbol))
        ERC4626(IERC20(address(0)))
        Ownable(msg.sender)
    {
        if (_aavePool == address(0) || _aToken == address(0) || _wrappedTokenGateway == address(0)) revert ZeroAddress();
        if (_feesWallet == address(0)) revert ZeroAddress();
        if (_feePercentage > 10000) revert InvalidFeePercentage();

        aavePool = IAavePool(_aavePool);
        aToken = IAToken(_aToken);
        wrappedTokenGateway = IWrappedTokenGateway(_wrappedTokenGateway);
        feesWallet = _feesWallet;
        feePercentage = _feePercentage;
    }

    receive() external payable {}

    function asset() public pure override returns (address) {
        return address(0);
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

    function depositETH(address receiver) public payable returns (uint256) {
        uint256 assets = msg.value;
        uint256 shares = convertToShares(assets);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (depositsDisabled) revert DepositsDisabledErr();
        if (tvlCap != 0) {
            uint256 nextAssets = totalAssets() + assets;
            if (nextAssets > tvlCap) revert CapExceeded();
        }

        wrappedTokenGateway.depositETH{value: assets}(address(aavePool), address(this), 0);
        totalPrincipal += assets;

        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override nonReentrant {
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

        aToken.approve(address(wrappedTokenGateway), assets);
        wrappedTokenGateway.withdrawETH(address(aavePool), assets, address(this));

        if (fee > 0) {
            (bool feeSuccess, ) = payable(feesWallet).call{value: fee}("");
            if (!feeSuccess) revert ETHTransferFailed();
            emit FeesCollected(feesWallet, fee);
        }

        uint256 userAmount = assets - fee;
        (bool success, ) = receiver.call{value: userAmount}("");
        if (!success) revert ETHTransferFailed();

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
}

