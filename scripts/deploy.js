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
  
  // Indirizzo ufficiale Chainlink Functions Router per Base Sepolia
  const routerAddress = hre.ethers.getAddress("0xf9b8fc078197181c8813e98f73034d172124f0aa");
  
  // Passiamo entrambi i parametri richiesti dal costruttore
  const songAsset = await SongAsset.deploy(deployer.address, routerAddress);
  //const songAsset = await SongAsset.deploy(deployer.address);

await songAsset.waitForDeployment();
console.log(
`SongAsset contract deployed to: ${songAsset.target}`
);
}
main().catch((error) => {
console.error(error);
process.exitCode = 1;
});
