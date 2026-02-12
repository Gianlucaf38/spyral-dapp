const hre = require("hardhat");
async function main() {
const SongAsset = await hre.ethers.getContractFactory("SongAsset");
const songAsset = await SongAsset.deploy();
await songAsset.waitForDeployment();
console.log(
`SongAsset contract deployed to: ${songAsset.target}`
);
}
main().catch((error) => {
console.error(error);
process.exitCode = 1;
});
