import { ethers, upgrades } from "hardhat";

async function main() {
  // We get the contract to deploy
  const Prediction = await ethers.getContractFactory("Prediction");
  const predictionAddress = process.env.PREDICTION_CONTRACT_ADDRESS;
  await upgrades.upgradeProxy(predictionAddress || "", Prediction, {
    kind: "uups",
  });

  console.log(
    `Farm implementation deployed to:${await ethers.provider.getStorageAt(
      predictionAddress || "",
      "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
    )}`
  );
}

main().catch((error) => {
  console.error(error);
});
