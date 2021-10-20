import { HardhatUserConfig } from "hardhat/config";
import "@nomiclabs/hardhat-waffle";
import "@openzeppelin/hardhat-upgrades";
import { config } from "dotenv";
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
      url: "https://bsc-mainnet.web3api.com/v1/Q3SYS628Q7NM9568343JHPK9HBNDRHUZ5K",
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
