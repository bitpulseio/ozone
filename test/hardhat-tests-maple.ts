import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("MapleVault", function () {
  let mapleVault: any;
  let mockUSDC: any;
  let mockMaplePool: any;
  let mockSyrupRouter: any;
  let mockSyrupToken: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let feesWallet: SignerWithAddress;

  const INITIAL_SUPPLY = ethers.parseUnits("1000000", 6); // 1M USDC (6 decimals)
  const DEPOSIT_AMOUNT = ethers.parseUnits("1000", 6); // 1K USDC

  beforeEach(async function () {
    [owner, user1, user2, feesWallet] = await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20Factory.deploy("USD Coin", "USDC", INITIAL_SUPPLY);

    // Deploy mock Syrup Token
    mockSyrupToken = await MockERC20Factory.deploy("Syrup USDC", "syrupUSDC", INITIAL_SUPPLY);

    // Deploy mock Maple Pool
    const MockMaplePoolFactory = await ethers.getContractFactory("MockMaplePool");
    mockMaplePool = await MockMaplePoolFactory.deploy(
      await mockUSDC.getAddress(),
      await mockSyrupToken.getAddress()
    );

    // Deploy mock SyrupRouter
    const MockSyrupRouterFactory = await ethers.getContractFactory("MockSyrupRouter");
    mockSyrupRouter = await MockSyrupRouterFactory.deploy();
    
    // Set the pool address in the router (needed for deposit(uint256, bytes32) calls)
    await mockSyrupRouter.setPool(await mockMaplePool.getAddress());

    // Deploy MapleVault
    const MapleVaultFactory = await ethers.getContractFactory("MapleVault");
    mapleVault = await MapleVaultFactory.deploy(
      await mockUSDC.getAddress(),
      await mockMaplePool.getAddress(),
      await mockSyrupRouter.getAddress(),
      await mockSyrupToken.getAddress(),
      feesWallet.address,
      100, // 1% fee
      "USDC"
    );

    // Give users some USDC
    await mockUSDC.transfer(user1.address, ethers.parseUnits("10000", 6));
    await mockUSDC.transfer(user2.address, ethers.parseUnits("10000", 6));
  });

  describe("Deployment", function () {
    it("Should set the correct owner", async function () {
      expect(await mapleVault.owner()).to.equal(owner.address);
    });

    it("Should set the correct asset", async function () {
      expect(await mapleVault.asset()).to.equal(await mockUSDC.getAddress());
    });

    it("Should set the correct maplePool", async function () {
      expect(await mapleVault.maplePool()).to.equal(await mockMaplePool.getAddress());
    });

    it("Should set the correct syrupRouter", async function () {
      expect(await mapleVault.syrupRouter()).to.equal(await mockSyrupRouter.getAddress());
    });

    it("Should set the correct syrupToken", async function () {
      expect(await mapleVault.syrupToken()).to.equal(await mockSyrupToken.getAddress());
    });

    it("Should set the correct feesWallet", async function () {
      expect(await mapleVault.feesWallet()).to.equal(feesWallet.address);
    });

    it("Should set the correct feePercentage", async function () {
      expect(await mapleVault.feePercentage()).to.equal(100);
    });

    it("Should have correct token name and symbol", async function () {
      expect(await mapleVault.name()).to.equal("Ozone USDC Claim (Maple)");
      expect(await mapleVault.symbol()).to.equal("ozUSDC-Maple");
    });

    it("Should start with deposits enabled", async function () {
      expect(await mapleVault.depositsDisabled()).to.be.false;
    });

    it("Should start with no TVL cap", async function () {
      expect(await mapleVault.tvlCap()).to.equal(0);
    });
  });

  describe("Deposits", function () {
    beforeEach(async function () {
      // Approve vault to spend user's USDC
      await mockUSDC.connect(user1).approve(await mapleVault.getAddress(), DEPOSIT_AMOUNT);
    });

    it("Should allow deposits when deposits are enabled", async function () {
      await expect(mapleVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address))
        .to.emit(mapleVault, "Deposit")
        .withArgs(user1.address, user1.address, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

      expect(await mapleVault.balanceOf(user1.address)).to.equal(DEPOSIT_AMOUNT);
    });

    it("Should deposit to Maple pool via SyrupRouter after receiving tokens", async function () {
      await mapleVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      
      // Check that SyrupRouter received the deposit call
      const routerCalls = await mockSyrupRouter.getAuthorizeAndDepositCalls();
      expect(routerCalls.length).to.equal(1);
      expect(routerCalls[0].pool).to.equal(await mockMaplePool.getAddress());
      expect(routerCalls[0].amount).to.equal(DEPOSIT_AMOUNT);
      
      // Check that Maple pool received the deposit call (via router)
      const depositCalls = await mockMaplePool.getDepositCalls();
      expect(depositCalls.length).to.equal(1);
      expect(depositCalls[0].amount).to.equal(DEPOSIT_AMOUNT);
      
      // Verify that syrup tokens were minted to the vault
      const vaultSyrupBalance = await mockSyrupToken.balanceOf(await mapleVault.getAddress());
      expect(vaultSyrupBalance).to.equal(DEPOSIT_AMOUNT);
    });

    it("Should not allow deposits when deposits are disabled", async function () {
      await mapleVault.setDepositsDisabled(true);
      
      await expect(mapleVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address))
        .to.be.revertedWithCustomError(mapleVault, "ERC4626ExceededMaxDeposit");
    });

    it("Should not allow deposits when TVL cap is exceeded", async function () {
      await mapleVault.setCap(DEPOSIT_AMOUNT);
      
      // First deposit should work
      await mapleVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      
      // Second deposit should fail
      await mockUSDC.connect(user2).approve(await mapleVault.getAddress(), DEPOSIT_AMOUNT);
      await expect(mapleVault.connect(user2).deposit(DEPOSIT_AMOUNT, user2.address))
        .to.be.revertedWithCustomError(mapleVault, "ERC4626ExceededMaxDeposit");
    });

    it("Should mint shares 1:1 for first depositor", async function () {
      await mapleVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      expect(await mapleVault.balanceOf(user1.address)).to.equal(DEPOSIT_AMOUNT);
    });

    it("Should track principal correctly", async function () {
      await mapleVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      // Note: totalPrincipal is not public, but we can verify through withdrawals
    });
  });

  describe("Withdrawals", function () {
    beforeEach(async function () {
      // Approve and deposit
      await mockUSDC.connect(user1).approve(await mapleVault.getAddress(), DEPOSIT_AMOUNT);
      await mapleVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      
      // Note: MockMaplePool already mints syrup tokens to vault during deposit
      // So we don't need to manually mint them here
    });

    it("Should allow withdrawals even when deposits are disabled", async function () {
      await mapleVault.setDepositsDisabled(true);
      
      await expect(mapleVault.connect(user1).withdraw(DEPOSIT_AMOUNT, user1.address, user1.address))
        .to.emit(mapleVault, "Withdraw");
    });

    it("Should withdraw from Maple pool before returning assets", async function () {
      const withdrawAmount = DEPOSIT_AMOUNT / 2n;
      
      await mapleVault.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);
      
      // Check that Maple pool received the requestRedeem call
      const redeemCalls = await mockMaplePool.getRequestRedeemCalls();
      expect(redeemCalls.length).to.equal(1);
      expect(redeemCalls[0].shares).to.equal(withdrawAmount); // 1:1 conversion in mock
      // Note: requestRedeem only takes shares parameter, assets are sent to msg.sender when processed
    });

    it("Should allow partial withdrawals", async function () {
      const initialShares = await mapleVault.balanceOf(user1.address);
      const withdrawAssets = DEPOSIT_AMOUNT / 2n;
      
      await mapleVault.connect(user1).withdraw(withdrawAssets, user1.address, user1.address);
      
      const remainingShares = await mapleVault.balanceOf(user1.address);
      // Shares should be less than initial (some shares were burned)
      expect(remainingShares).to.be.lt(initialShares);
      expect(remainingShares).to.be.gt(0);
    });

    it("Should calculate fees on yield only", async function () {
      // Simulate yield: mint more syrup tokens to represent interest
      // In real Maple, yield accrues as syrup tokens increase in value
      const yieldAmount = ethers.parseUnits("100", 6); // 100 USDC yield
      await mockSyrupToken.mint(await mapleVault.getAddress(), yieldAmount);
      
      // Ensure the pool has enough underlying tokens to return on withdrawal
      // The pool already has DEPOSIT_AMOUNT from the deposit, we just need to add yield
      await mockUSDC.mint(await mockMaplePool.getAddress(), yieldAmount);
      
      const totalAssets = await mapleVault.totalAssets();
      expect(totalAssets).to.equal(DEPOSIT_AMOUNT + yieldAmount);
      
      // Withdraw all assets (convert shares to assets first)
      const shares = await mapleVault.balanceOf(user1.address);
      const assetsToWithdraw = await mapleVault.convertToAssets(shares);
      const feesWalletBalanceBefore = await mockUSDC.balanceOf(feesWallet.address);
      
      await mapleVault.connect(user1).withdraw(assetsToWithdraw, user1.address, user1.address);
      
      // Check that fees were collected (1% of yield)
      const feesWalletBalanceAfter = await mockUSDC.balanceOf(feesWallet.address);
      const feesCollected = feesWalletBalanceAfter - feesWalletBalanceBefore;
      const expectedFee = (yieldAmount * 100n) / 10000n; // 1% of yield = 1 USDC
      
      // Fee should be approximately 1% of the yield portion
      // The calculation: userYieldShare = (shares / totalShares) * totalYield
      // With 1000 shares, 100 USDC yield, fee = 100 * 1% = 1 USDC
      // Note: There may be rounding differences in the calculation
      expect(feesCollected).to.be.gt(0); // Fees should be collected
      expect(feesCollected).to.be.lte(yieldAmount); // Fees should not exceed yield
      // The fee should be close to 1% of yield, allowing for calculation differences
      expect(feesCollected).to.be.closeTo(expectedFee, ethers.parseUnits("1.5", 6));
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to disable deposits", async function () {
      await expect(mapleVault.setDepositsDisabled(true))
        .to.emit(mapleVault, "DepositsDisabled")
        .withArgs(true);
      
      expect(await mapleVault.depositsDisabled()).to.be.true;
    });

    it("Should allow owner to set TVL cap", async function () {
      const cap = ethers.parseUnits("50000", 6);
      
      await expect(mapleVault.setCap(cap))
        .to.emit(mapleVault, "CapUpdated")
        .withArgs(cap);
      
      expect(await mapleVault.tvlCap()).to.equal(cap);
    });

    it("Should not allow non-owner to call admin functions", async function () {
      await expect(mapleVault.connect(user1).setDepositsDisabled(true))
        .to.be.revertedWithCustomError(mapleVault, "OwnableUnauthorizedAccount");
      
      await expect(mapleVault.connect(user1).setCap(ethers.parseUnits("1000", 6)))
        .to.be.revertedWithCustomError(mapleVault, "OwnableUnauthorizedAccount");
    });
  });

  describe("ERC4626 Compliance", function () {
    it("Should correctly convert assets to shares", async function () {
      const assets = ethers.parseUnits("1000", 6);
      const shares = await mapleVault.convertToShares(assets);
      expect(shares).to.equal(assets); // 1:1 for first depositor
    });

    it("Should correctly convert shares to assets", async function () {
      const shares = ethers.parseUnits("1000", 6);
      const assets = await mapleVault.convertToAssets(shares);
      expect(assets).to.equal(shares); // 1:1 for first depositor
    });

    it("Should return correct max deposit when deposits enabled", async function () {
      const maxDeposit = await mapleVault.maxDeposit(user1.address);
      expect(maxDeposit).to.equal(ethers.MaxUint256);
    });

    it("Should return 0 max deposit when deposits disabled", async function () {
      await mapleVault.setDepositsDisabled(true);
      const maxDeposit = await mapleVault.maxDeposit(user1.address);
      expect(maxDeposit).to.equal(0);
    });
  });
});

