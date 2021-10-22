import { expect } from "chai";
import { ethers, upgrades, network } from "hardhat";
import {
  Signer,
  Contract,
  BigNumber as _BigNumber,
  BigNumber,
  ContractFactory,
} from "ethers";
import { Prediction } from "../typechain";
import { timeStamp } from "console";

type _Prediction = Prediction | Contract;

let signers: Signer[], prediction: _Prediction;
let PrederA: Signer, PrederB: Signer;
const { BNB, BTC, ETH, DOGE, CAKE } = process.env;

const tokens = [
  BNB?.split(" ")[0],
  ETH?.split(" ")[0],
  BTC?.split(" ")[0],
  CAKE?.split(" ")[0],
  DOGE?.split(" ")[0],
] || [""];
const oracles = [
  BNB?.split(" ")[1],
  ETH?.split(" ")[1],
  BTC?.split(" ")[1],
  CAKE?.split(" ")[1],
  DOGE?.split(" ")[1],
] || [""];

describe("Farming Contract Tests", () => {
  beforeEach(async () => {
    signers = await ethers.getSigners();
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0xDC7eDEE4d0A8dc5F38CA1590c6e9Dd9c049D79a6"],
    });
    PrederA = await ethers.getSigner(
      "0xDC7eDEE4d0A8dc5F38CA1590c6e9Dd9c049D79a6"
    );

    const PredictionFactory = await ethers.getContractFactory(
      "Prediction",
      PrederA
    );
    prediction = await upgrades.deployProxy(
      PredictionFactory,
      [
        await PrederA.getAddress(),
        await PrederA.getAddress(),
        86400,
        300,
        ethers.utils.parseUnits("10"),
        100,
        10,
      ],
      { kind: "uups" }
    );
    // add tokens
    await prediction.addTokens(tokens, oracles);

    // approve prediction contract to spend pred tokens
    const pred = await ethers.getContractAt(
      "IERC20",
      "0xB2d7b35539A543bbE4c74965488fFE33c6721f0d",
      PrederA
    );
    await pred.approve(prediction.address, ethers.utils.parseEther("50"));
  });

  xit("initialisation should add tokens and oracles", async () => {
    // check tokens
    const _tokens = await prediction.getTokens();
    expect(_tokens.join()).equal(
      tokens.join(),
      "Tokens not added successfully"
    );
    // check oracles
    for (let i = 0; i < oracles.length; i++) {
      const _oracle = await prediction.oracles(tokens[i]);
      expect(_oracle).equal(oracles[i], "oracle not added correctly");
    }
  });

  xit("should remove token", async () => {
    await prediction.removeTokens(["0"]);
    const _tokens = await prediction.getTokens();
    expect(_tokens.includes(tokens[0])).to.equal(false, "token not removed");

    const oracle = await prediction.oracles(tokens[0]);
    expect(oracle).to.equal(ethers.constants.AddressZero);
  });

  xit("should set token oracle", async () => {
    await prediction.pause();
    await prediction.setOracles([tokens[0]], [oracles[1]]);
    const oracle = await prediction.oracles(tokens[0]);
    expect(oracle).equal(oracles[1]);
  });

  context("Start Round", async () => {
    let currentEpoch: BigNumber;
    beforeEach(async () => {
      await prediction.startRound();
      currentEpoch = await prediction.currentEpoch();
    });

    xit("should initialise round", async () => {
      const round = await prediction.getRound(currentEpoch);
      const blockNo = await ethers.provider.getBlockNumber();
      const block = await ethers.provider.getBlock(blockNo);

      expect(block.timestamp).equal(round.lockedTimestamp);
      expect(currentEpoch).equal(1, "current epoch not updated correctly");
      // type loop = {
      //   (price: string, index: number): boolean;
      // };
      // round.lockedPrices.forEach(
      //   (price, index: { price: string; index: number }) => {
      //     expect(price).to.not.equal(0);
      //     expect(round.lockedOracleIds[index]).to.not.equal(0);
      //     return true;
      //   }
      // );
    });

    describe("User predicts", () => {
      beforeEach(async () => {
        await prediction.predictBear(currentEpoch, tokens[0]);
      });
      xit("should update bet Info", async () => {
        const betInfo = await prediction.ledger(
          await prediction.currentEpoch(),
          await PrederA.getAddress()
        );

        expect(betInfo.position).to.equal(1);
        expect(betInfo.token).to.equal(tokens[0]);
        expect(betInfo.amount).to.equal(ethers.utils.parseUnits("10"));
        expect(betInfo.claimed).to.equal(false);
      });
      xit("should update Round Info", async () => {
        const round = await prediction.getRound(currentEpoch);
        expect(round.totalAmount).to.equal(ethers.utils.parseUnits("10"));
      });
      xit("should not let claim bet before round close", async () => {
        await expect(prediction.claim([currentEpoch])).to.be.revertedWith(
          "Not eligible for refund"
        );
      });
      xit("should let user claim bet after round close", async () => {
        await network.provider.send("evm_increaseTime", [86900]);
        await network.provider.send("evm_mine");
        await prediction.claim([currentEpoch]);
        const betInfo = await prediction.ledger(
          await prediction.currentEpoch(),
          await PrederA.getAddress()
        );
        expect(betInfo.claimed).to.equal(true);
      });
    });
  });

  context("Start and End Round", () => {
    let currentEpoch: BigNumber;
    beforeEach(async () => {
      await prediction.startRound();
      currentEpoch = await prediction.currentEpoch();
      await prediction.predictBull(currentEpoch, tokens[0]);
      await network.provider.send("evm_increaseTime", [86400]);
      await network.provider.send("evm_mine");
      await prediction.endRound();
    });

    xit("should update Round Info", async () => {
      const round = await prediction.getRound(currentEpoch);
      const blockNo = await ethers.provider.getBlockNumber();
      const block = await ethers.provider.getBlock(blockNo);

      expect(block.timestamp).equal(round.closeTimestamp);
      expect(round.oraclesCalled).to.equal(true);
    });

    xit("should not let user claim funds", async () => {
      await expect(prediction.claim([currentEpoch])).to.be.revertedWith(
        "Not eligible for refund"
      );
    });

    it("should make user either win or lose", async () => {
      await prediction.startRound();
      await prediction.predictBull(await prediction.currentEpoch(), tokens[0]);
      await network.provider.send("evm_increaseTime", [86400]);
      await network.provider.send("evm_mine");
      await prediction.endRound();

      const won = await prediction.wonLastRound(await PrederA.getAddress());
      const lost = await prediction.lostLastRound(await PrederA.getAddress());
      expect(won.toString()).to.not.equal(lost.toString());
    });
  });
});
