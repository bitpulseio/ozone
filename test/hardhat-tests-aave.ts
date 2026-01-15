import { expect } from "chai";
import { ethers } from "hardhat";
// import { AVIVault } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("AVIVault", function () {
  let aviVault: any;
  let mockUSDC: any;
  let mockAavePool: any;
  let mockAToken: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

  const INITIAL_SUPPLY = ethers.parseEther("1000000"); // 1M USDC
  const DEPOSIT_AMOUNT = ethers.parseEther("1000"); // 1K USDC

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20Factory.deploy("USD Coin", "USDC", INITIAL_SUPPLY);

    // Deploy mock Aave Pool
    const MockAavePoolFactory = await ethers.getContractFactory("MockAavePool");
    mockAavePool = await MockAavePoolFactory.deploy();

    // Deploy mock aToken
    const MockATokenFactory = await ethers.getContractFactory("MockAToken");
    mockAToken = await MockATokenFactory.deploy("Aave USDC", "aUSDC");

    // Deploy AVIVault
    const AVIVaultFactory = await ethers.getContractFactory("AVIVault");
    aviVault = await AVIVaultFactory.deploy(
      await mockUSDC.getAddress(),
      await mockAavePool.getAddress(),
      await mockAToken.getAddress(),
      "USDC"
    );

    // Set up mock relationships
    await mockAavePool.setAToken(await mockAToken.getAddress());
    await mockAToken.setAavePool(await mockAavePool.getAddress());

    // Give users some USDC
    await mockUSDC.transfer(user1.address, ethers.parseEther("10000"));
    await mockUSDC.transfer(user2.address, ethers.parseEther("10000"));
  });

  describe("Deployment", function () {
    it("Should set the correct owner", async function () {
      expect(await aviVault.owner()).to.equal(owner.address);
    });

    it("Should set the correct asset", async function () {
      expect(await aviVault.asset()).to.equal(await mockUSDC.getAddress());
    });

    it("Should set the correct aToken", async function () {
      expect(await aviVault.aToken()).to.equal(await mockAToken.getAddress());
    });

    it("Should set the correct aavePool", async function () {
      expect(await aviVault.aavePool()).to.equal(await mockAavePool.getAddress());
    });

    it("Should have correct token name and symbol", async function () {
      expect(await aviVault.name()).to.equal("Bitpulse USDC Claim (AVI)");
      expect(await aviVault.symbol()).to.equal("bpUSDC");
    });

    it("Should start with deposits enabled", async function () {
      expect(await aviVault.depositsDisabled()).to.be.false;
    });

    it("Should start with no TVL cap", async function () {
      expect(await aviVault.tvlCap()).to.equal(0);
    });
  });

  describe("Deposits", function () {
    beforeEach(async function () {
      // Approve vault to spend user's USDC
      await mockUSDC.connect(user1).approve(await aviVault.getAddress(), DEPOSIT_AMOUNT);
    });

    it("Should allow deposits when deposits are enabled", async function () {
      await expect(aviVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address))
        .to.emit(aviVault, "Deposit")
        .withArgs(user1.address, user1.address, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

      expect(await aviVault.balanceOf(user1.address)).to.equal(DEPOSIT_AMOUNT);
      expect(await aviVault.totalAssets()).to.equal(DEPOSIT_AMOUNT);
    });

    it("Should not allow deposits when deposits are disabled", async function () {
      await aviVault.setDepositsDisabled(true);
      
      await expect(aviVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address))
        .to.be.revertedWithCustomError(aviVault, "ERC4626ExceededMaxDeposit");
    });

    it("Should not allow deposits when TVL cap is exceeded", async function () {
      await aviVault.setCap(DEPOSIT_AMOUNT);
      
      // First deposit should work
      await aviVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      
      // Second deposit should fail
      await mockUSDC.connect(user2).approve(await aviVault.getAddress(), DEPOSIT_AMOUNT);
      await expect(aviVault.connect(user2).deposit(DEPOSIT_AMOUNT, user2.address))
        .to.be.revertedWithCustomError(aviVault, "ERC4626ExceededMaxDeposit");
    });

    it("Should mint shares 1:1 for first depositor", async function () {
      await aviVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      expect(await aviVault.balanceOf(user1.address)).to.equal(DEPOSIT_AMOUNT);
    });
  });

  describe("Withdrawals", function () {
    beforeEach(async function () {
      // Approve and deposit
      await mockUSDC.connect(user1).approve(await aviVault.getAddress(), DEPOSIT_AMOUNT);
      await aviVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
    });

    it("Should allow withdrawals even when deposits are disabled", async function () {
      await aviVault.setDepositsDisabled(true);
      
      await expect(aviVault.connect(user1).withdraw(DEPOSIT_AMOUNT, user1.address, user1.address))
        .to.emit(aviVault, "Withdraw")
        .withArgs(user1.address, user1.address, user1.address, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    });

    it("Should allow partial withdrawals", async function () {
      const withdrawAmount = DEPOSIT_AMOUNT / 2n;
      
      await aviVault.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);
      
      expect(await aviVault.balanceOf(user1.address)).to.equal(DEPOSIT_AMOUNT - withdrawAmount);
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to disable deposits", async function () {
      await expect(aviVault.setDepositsDisabled(true))
        .to.emit(aviVault, "DepositsDisabled")
        .withArgs(true);
      
      expect(await aviVault.depositsDisabled()).to.be.true;
    });

    it("Should allow owner to set TVL cap", async function () {
      const cap = ethers.parseEther("50000");
      
      await expect(aviVault.setCap(cap))
        .to.emit(aviVault, "CapUpdated")
        .withArgs(cap);
      
      expect(await aviVault.tvlCap()).to.equal(cap);
    });

    it("Should not allow non-owner to call admin functions", async function () {
      await expect(aviVault.connect(user1).setDepositsDisabled(true))
        .to.be.revertedWithCustomError(aviVault, "OwnableUnauthorizedAccount");
      
      await expect(aviVault.connect(user1).setCap(ethers.parseEther("1000")))
        .to.be.revertedWithCustomError(aviVault, "OwnableUnauthorizedAccount");
    });
  });

  describe("ERC4626 Compliance", function () {
    it("Should correctly convert assets to shares", async function () {
      const assets = ethers.parseEther("1000");
      const shares = await aviVault.convertToShares(assets);
      expect(shares).to.equal(assets); // 1:1 for first depositor
    });

    it("Should correctly convert shares to assets", async function () {
      const shares = ethers.parseEther("1000");
      const assets = await aviVault.convertToAssets(shares);
      expect(assets).to.equal(shares); // 1:1 for first depositor
    });

    it("Should return correct max deposit when deposits enabled", async function () {
      const maxDeposit = await aviVault.maxDeposit(user1.address);
      expect(maxDeposit).to.equal(ethers.MaxUint256);
    });

    it("Should return 0 max deposit when deposits disabled", async function () {
      await aviVault.setDepositsDisabled(true);
      const maxDeposit = await aviVault.maxDeposit(user1.address);
      expect(maxDeposit).to.equal(0);
    });
  });

  describe("Integration with Aave", function () {
    it("Should supply to Aave after deposit", async function () {
      await mockUSDC.connect(user1).approve(await aviVault.getAddress(), DEPOSIT_AMOUNT);
      await aviVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      
      // Check that Aave pool received the supply call
      const supplyCalls = await mockAavePool.getSupplyCalls();
      expect(supplyCalls.length).to.equal(1);
      expect(supplyCalls[0].asset).to.equal(await mockUSDC.getAddress());
      expect(supplyCalls[0].amount).to.equal(DEPOSIT_AMOUNT);
    });

    it("Should withdraw from Aave before withdrawal", async function () {
      await mockUSDC.connect(user1).approve(await aviVault.getAddress(), DEPOSIT_AMOUNT);
      await aviVault.connect(user1).deposit(DEPOSIT_AMOUNT, user1.address);
      
      await aviVault.connect(user1).withdraw(DEPOSIT_AMOUNT, user1.address, user1.address);
      
      // Check that Aave pool received the withdraw call
      const withdrawCalls = await mockAavePool.getWithdrawCalls();
      expect(withdrawCalls.length).to.equal(1);
      expect(withdrawCalls[0].asset).to.equal(await mockUSDC.getAddress());
      expect(withdrawCalls[0].amount).to.equal(DEPOSIT_AMOUNT);
    });
  });
});
