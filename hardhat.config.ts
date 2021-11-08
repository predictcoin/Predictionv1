import { HardhatUserConfig } from "hardhat/config";
import "@nomiclabs/hardhat-waffle";
import "@openzeppelin/hardhat-upgrades";
import { config } from "dotenv";
import "@atixlabs/hardhat-time-n-mine";
config();
config({ path: `.env.${process.env.NODE_ENV}` });
const mnemonic = process.env.MNEMONIC;

const hardhatConfig: HardhatUserConfig = {
  solidity: {
    version: "0.8.7",
    settings: {
      optimizer: {
        enabled: true,
        runs: 99,
      },
    },
  },
  networks: {
    hardhat: {
      forking: {
        url: "https://data-seed-prebsc-1-s1.binance.org:8545/",
      },
    },
    bscTestnet: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545/",
      chainId: 97,
      accounts: {
        mnemonic,
        path: "m/44'/60'/0'/0",
        initialIndex: 0,
        count: 10,
      },
      timeout: 200000,
    },
    bscMainnet: {
      url: "https://bsc-dataseed1.binance.org",
      chainId: 56,
      accounts: {
        mnemonic,
        path: "m/44'/60'/0'/0",
        initialIndex: 0,
        count: 10,
      },
      timeout: 200000,
    },
  },
  mocha: {
    timeout: 200000,
  },
};

export default hardhatConfig;
