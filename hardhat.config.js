require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
solidity: "0.8.20",
networks: {
baseSepolia: {
url: process.env.BASE_SEPOLIA_RPC_URL || "",
accounts: [process.env.PRIVATE_KEY],
},
},
};
