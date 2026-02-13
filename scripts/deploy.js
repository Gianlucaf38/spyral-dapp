const hre = require("hardhat");
async function main() {

// 1. Ottieni il tuo wallet (il primo della lista 'accounts' in hardhat.config.js)
  const [deployer] = await hre.ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);
  
const SongAsset = await hre.ethers.getContractFactory("SongAsset");

// 2. PASSI L'ARGOMENTO QUI
  // Dentro .deploy() ci vanno gli argomenti del costruttore, in ordine.
  // Solidity: constructor(address initialOwner)
  // JS:       .deploy(deployer.address)
  const songAsset = await SongAsset.deploy(deployer.address);

await songAsset.waitForDeployment();
console.log(
`SongAsset contract deployed to: ${songAsset.target}`
);
}
main().catch((error) => {
console.error(error);
process.exitCode = 1;
});
