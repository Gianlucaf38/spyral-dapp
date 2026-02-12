const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SongAsset", function () {
    let songAsset;
    let owner;
    let addr1;
    beforeEach(async function () {
        [owner, addr1] = await ethers.getSigners();
        const SongAsset = await ethers.getContractFactory("SongAsset");
        songAsset = await SongAsset.deploy();
        await songAsset.waitForDeployment();
    });
    it("Should mint a new song", async function () {
        await songAsset.mintSong(owner.address);
        // Aggiungi asserzioni per verificare che il mint sia avvenuto correttamente
    });
    it("Should advance state", async function () {
        await songAsset.mintSong(owner.address);
        await songAsset.advanceState(1); // Assumendo tokenId = 1
        // Verifica che lo stato sia cambiato
    });
    // Aggiungi altri test per le funzionalità chiave
});