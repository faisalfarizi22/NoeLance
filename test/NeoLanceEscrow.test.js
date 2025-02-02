const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NeoLanceEscrow", function () {
  let escrow, stablecoin, owner, client, freelancer, other;
  const disputeFee = ethers.parseUnits("10", 18);
  const depositAmount = ethers.parseUnits("1000", 18);
  const deadline = 3600; // 1 jam

  beforeEach(async function () {
    [owner, client, freelancer, other] = await ethers.getSigners();

    // Deploy Dummy Stablecoin untuk testing
    const Stablecoin = await ethers.getContractFactory("DummyERC20");
    stablecoin = await Stablecoin.deploy(
      "Dummy Stablecoin", 
      "DST", 
      18, 
      ethers.parseUnits("1000000", 18)
    );
    await stablecoin.waitForDeployment();

    // Transfer stablecoin ke client
    await stablecoin.transfer(client.address, ethers.parseUnits("10000", 18));

    // Deploy kontrak escrow dengan parameter yang benar
    const NeoLanceEscrow = await ethers.getContractFactory("NeoLanceEscrow");
    escrow = await NeoLanceEscrow.deploy(stablecoin.target);
    await escrow.waitForDeployment();

    console.log("Contract deployed at:", escrow.target);
  });

  describe("Deposit Escrow", function () {
    it("should deposit escrow successfully", async function () {
      await stablecoin.connect(client).approve(escrow.target, depositAmount); // Gunakan .target
      const tx = await escrow.connect(client).depositEscrow(freelancer.address, depositAmount, deadline);
      await tx.wait();

      expect(await escrow.escrowCount()).to.equal(1);
      const escrowData = await escrow.escrows(1);
      expect(escrowData.client).to.equal(client.address);
      expect(escrowData.freelancer).to.equal(freelancer.address);
      expect(escrowData.amount).to.equal(depositAmount);
    });
  });

  describe("Milestone and Refund", function () {
    beforeEach(async function () {
      await stablecoin.connect(client).approve(escrow.target, depositAmount); // Gunakan .target
      await escrow.connect(client).depositEscrow(freelancer.address, depositAmount, deadline);
    });

    it("should release milestone correctly", async function () {
      const milestone = ethers.parseUnits("200", 18);
      const tx = await escrow.connect(client).releaseMilestone(1, milestone);
      await tx.wait();

      const escrowData = await escrow.escrows(1);
      expect(escrowData.releasedAmount).to.equal(milestone);
    });

    it("should allow partial refund after deadline and disable escrow", async function () {
      // Menaikkan waktu ke setelah deadline
      await ethers.provider.send("evm_increaseTime", [deadline + 1]);
      await ethers.provider.send("evm_mine", []);

      const refundAmount = ethers.parseUnits("500", 18);
      const tx = await escrow.connect(client).partialRefund(1, refundAmount);
      await tx.wait();

      const escrowData = await escrow.escrows(1);
      expect(escrowData.isActive).to.equal(false);
    });
  });

  describe("Approve Work", function () {
    beforeEach(async function () {
      // Deposit escrow dan lakukan alur hingga freelancer mengirim pekerjaan
      await stablecoin.connect(client).approve(escrow.target, depositAmount); // Gunakan .target
      await escrow.connect(client).depositEscrow(freelancer.address, depositAmount, deadline);
      await escrow.connect(client).signContract(1);
      await escrow.connect(freelancer).submitWork(1);
    });

    it("should approve work and release remaining funds to freelancer", async function () {
      // Catat saldo freelancer sebelum approve
      const initialBalance = await stablecoin.balanceOf(freelancer.address);
      
      const tx = await escrow.connect(client).approveWork(1);
      await tx.wait();

      const escrowData = await escrow.escrows(1);
      expect(escrowData.isActive).to.equal(false);

      const remaining = depositAmount; // Karena tidak ada milestone dirilis
      const finalBalance = await stablecoin.balanceOf(freelancer.address);
      expect(finalBalance - initialBalance).to.equal(remaining); // Gunakan operator -
    });
  });

  describe("Withdraw", function () {
    beforeEach(async function () {
      await stablecoin.connect(client).approve(escrow.target, depositAmount); // Gunakan .target
      await escrow.connect(client).depositEscrow(freelancer.address, depositAmount, deadline);
    });

    it("should allow client to withdraw funds after deadline if no work submitted", async function () {
      // Tingkatkan waktu ke setelah deadline
      await ethers.provider.send("evm_increaseTime", [deadline + 1]);
      await ethers.provider.send("evm_mine", []);

      // Catat saldo client sebelum withdraw
      const initialBalance = await stablecoin.balanceOf(client.address);

      const tx = await escrow.connect(client).withdraw(1);
      await tx.wait();

      const escrowData = await escrow.escrows(1);
      expect(escrowData.isActive).to.equal(false);

      const finalBalance = await stablecoin.balanceOf(client.address);
      expect(finalBalance).to.be.above(initialBalance);
    });
  });

  describe("Auto Release", function () {
    beforeEach(async function () {
      await stablecoin.connect(client).approve(escrow.target, depositAmount); // Gunakan .target
      await escrow.connect(client).depositEscrow(freelancer.address, depositAmount, deadline);
      // Freelancer mengirim pekerjaan
      await escrow.connect(client).signContract(1);
      await escrow.connect(freelancer).submitWork(1);
    });

    it("should auto release funds to freelancer after deadline", async function () {
      // Tingkatkan waktu ke setelah deadline
      await ethers.provider.send("evm_increaseTime", [deadline + 1]);
      await ethers.provider.send("evm_mine", []);

      // Catat saldo freelancer sebelum auto release
      const initialBalance = await stablecoin.balanceOf(freelancer.address);
      
      const tx = await escrow.connect(other).autoRelease(1);
      await tx.wait();

      const escrowData = await escrow.escrows(1);
      expect(escrowData.isActive).to.equal(false);

      const remaining = depositAmount; // Karena tidak ada milestone dirilis
      const finalBalance = await stablecoin.balanceOf(freelancer.address);
      expect(finalBalance - initialBalance).to.equal(remaining); // Gunakan operator -
    });
  });

  describe("Review & Extend Deadline", function () {
    beforeEach(async function () {
      await stablecoin.connect(client).approve(escrow.target, depositAmount); // Gunakan .target
      await escrow.connect(client).depositEscrow(freelancer.address, depositAmount, deadline);
      
    });

    it("should extend deadline", async function () {
      // Ambil deadline awal
      const escrowDataBefore = await escrow.escrows(1);
      const oldDeadline = escrowDataBefore.deadline;

      // Perpanjang deadline
      const additionalTime = 600n; // 10 menit
      const tx = await escrow.connect(client).extendDeadline(1, additionalTime);
      await tx.wait();

      const escrowDataAfter = await escrow.escrows(1);
      expect(escrowDataAfter.deadline).to.equal(oldDeadline + additionalTime);
    });
  });

  describe("Submit Review", function () {
    beforeEach(async function () {
        // Setup untuk review (termasuk approveWork)
        await stablecoin.connect(client).approve(escrow.target, depositAmount);
        await escrow.connect(client).depositEscrow(freelancer.address, depositAmount, deadline);
        await escrow.connect(client).signContract(1);
        await escrow.connect(freelancer).submitWork(1);
        await escrow.connect(client).approveWork(1);
    });

    it("should allow client to submit review and store in review history", async function () {
        const clientRating = 5;
        const freelancerRating = 4;
        const clientFeedback = "Great communication";
        const freelancerFeedback = "Delivered quality work";

        const tx = await escrow.connect(client).submitReview(1, clientRating, clientFeedback, freelancerRating, freelancerFeedback);
        await tx.wait();

        const reviews = await escrow.getReviewHistory(1);
        expect(reviews.length).to.equal(1);
        expect(reviews[0].clientRating).to.equal(clientRating);
        expect(reviews[0].freelancerRating).to.equal(freelancerRating);
    });

});

  describe("Dispute Voting", function () {
    beforeEach(async function () {
      await stablecoin.connect(client).approve(escrow.target, depositAmount); // Gunakan .target
      await escrow.connect(client).depositEscrow(freelancer.address, depositAmount, deadline);
      // Buka sengketa
      await stablecoin.connect(client).approve(escrow.target, disputeFee); // Gunakan .target
      await escrow.connect(client).openDispute(1);
    });

    it("should allow only one vote per address", async function () {
      await escrow.connect(client).voteOnDispute(1, true);
      await expect(escrow.connect(client).voteOnDispute(1, false))
        .to.be.revertedWith("Already voted");
    });

    it("should resolve dispute if minimum voter reached", async function () {
      // Menggunakan dua voter tambahan dari freelancer dan other untuk mencapai minimal voter (MIN_VOTER = 3)
      await escrow.connect(client).voteOnDispute(1, true);
      await escrow.connect(freelancer).voteOnDispute(1, true);
      await escrow.connect(other).voteOnDispute(1, false);
      
      // Total votes = 1 (client) + 1 (freelancer) + 1 (other) = 3
      const tx = await escrow.connect(owner).resolveDispute(1);
      await tx.wait();
      
      const escrowData = await escrow.escrows(1);
      expect(escrowData.isActive).to.equal(false);
    });
  });
});