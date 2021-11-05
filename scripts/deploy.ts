import { ethers, upgrades } from "hardhat";

async function main() {
  const { BNB, BTC, ETH, DOGE, CAKE } = process.env;
  const tokens = [
    BNB?.split(" ")[0],
    ETH?.split(" ")[0],
    BTC?.split(" ")[0],
    CAKE?.split(" ")[0],
    DOGE?.split(" ")[0],
  ];
  const oracles = [
    BNB?.split(" ")[1],
    ETH?.split(" ")[1],
    BTC?.split(" ")[1],
    CAKE?.split(" ")[1],
    DOGE?.split(" ")[1],
  ];

  const [signer] = await ethers.getSigners();
  // We get the contract to deploy
  const Prediction = await ethers.getContractFactory("Prediction");

  const prediction = await upgrades.deployProxy(
    Prediction,
    [
      signer.address,
      signer.address,
      1800,
      300,
      900,
      ethers.utils.parseUnits("10"),
      100,
      10,
    ],
    { kind: "uups" }
  );

  prediction.addTokens(tokens, oracles);

  console.log(
    `Prediction deployed to:${prediction.address}`,
    `implementation deployed to:${await ethers.provider.getStorageAt(
      prediction.address,
      "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
    )}`
  );
}

main().catch((error) => {
  console.error(error);
});
