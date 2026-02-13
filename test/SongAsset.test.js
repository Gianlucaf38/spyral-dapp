const { expect } = require("chai");
const { ethers } = require("hardhat");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("SongAsset", function () {
  let songAsset;
  let owner;
  let addr1;

  const AUDIO_HASH = ethers.keccak256(
    ethers.toUtf8Bytes("test-audio-file")
  );

  beforeEach(async function () {
    [owner, addr1] = await ethers.getSigners();
    const SongAsset = await ethers.getContractFactory("SongAsset");
    songAsset = await SongAsset.deploy(owner.address);
    await songAsset.waitForDeployment();
  });

  it("Should mint a new song", async function () {
    await songAsset.mintSong(addr1.address, AUDIO_HASH);

    expect(await songAsset.ownerOf(0)).to.equal(addr1.address);
  });

  it("Should revert if non-owner tries to mint", async function () {
    await expect(
      songAsset.connect(addr1).mintSong(addr1.address, AUDIO_HASH)
    ).to.be.reverted;
  });

  it("Should advance state", async function () {
    await songAsset.mintSong(owner.address, AUDIO_HASH);

    await expect(songAsset.advanceState(0))
      .to.emit(songAsset, "StateChanged")
      .withArgs(
        0,
        0, // Upload
        1, // Collaborate
        anyValue
      );
  });
  
  describe("Collaborator Management", function () {
    
    // Helper per portare la canzone allo stato Collaborate
    async function mintAndAdvanceToCollaborate() {
      await songAsset.mintSong(owner.address, AUDIO_HASH);
      // Stato iniziale: Upload. 
      // Cooldown per Upload è 0, quindi possiamo avanzare subito.
      await songAsset.advanceState(0); 
      // Ora siamo in Collaborate
    }

    it("Should allow owner to add a collaborator in Collaborate phase", async function () {
      await mintAndAdvanceToCollaborate();

      // Proviamo ad aggiungere un collaboratore (addr1 con 20%)
      // Se la transazione non va in revert, il test passa
      await expect(
        songAsset.addCollaborator(0, addr1.address, 20)
      ).to.not.be.reverted;
    });

    it("Should revert if trying to add collaborator in Upload phase (Too Early)", async function () {
      // Mintiamo ma NON avanziamo di stato (siamo in Upload)
      await songAsset.mintSong(owner.address, AUDIO_HASH);

      await expect(
        songAsset.addCollaborator(0, addr1.address, 20)
      ).to.be.revertedWith("Spyral: Cannot edit after Collaborate phase");
    });

    it("Should revert if trying to add collaborator in Register phase (Too Late)", async function () {
      await mintAndAdvanceToCollaborate(); // Siamo in Collaborate

      // Dobbiamo avanzare a Register. 
      // MA il contratto richiede un cooldown di 1 giorno per uscire da Collaborate.
      // Usiamo l'helper di Hardhat per viaggiare nel futuro di 1 giorno + 1 secondo
      await time.increase(86400 + 1); 

      await songAsset.advanceState(0); // Ora siamo in Register

      await expect(
        songAsset.addCollaborator(0, addr1.address, 20)
      ).to.be.revertedWith("Spyral: Cannot edit after Collaborate phase");
    });

    it("Should revert if a non-owner tries to add a collaborator", async function () {
      await mintAndAdvanceToCollaborate();

      // addr1 prova ad aggiungere se stesso come collaboratore
      await expect(
        songAsset.connect(addr1).addCollaborator(0, addr1.address, 20)
      ).to.be.revertedWith("Spyral: Only the strict owner can add collaborators");
    });

    it("Should revert with invalid percentages", async function () {
      await mintAndAdvanceToCollaborate();

      // Test 0%
      await expect(
        songAsset.addCollaborator(0, addr1.address, 0)
      ).to.be.revertedWith("Invalid percentage");

      // Test 101%
      await expect(
        songAsset.addCollaborator(0, addr1.address, 101)
      ).to.be.revertedWith("Invalid percentage");
    });
  });
  
  describe("Lifecycle State Transitions (Time & Logic)", function () {

    // Helper: Minta una canzone e ritorna l'ID (sempre 0 se puliamo il test)
    async function mintSong() {
      await songAsset.mintSong(owner.address, AUDIO_HASH);
      return 0; // TokenID
    }

    it("1. Upload -> Collaborate: Should pass immediately (0 wait)", async function () {
      const tokenId = await mintSong();
      
      // Upload -> Collaborate (Wait 0)
      await expect(songAsset.advanceState(tokenId))
        .to.emit(songAsset, "StateChanged")
        .withArgs(tokenId, 0, 1, anyValue); // 0=Upload, 1=Collaborate
    });

    it("2. Collaborate -> Register: Should fail if called too early (< 1 day)", async function () {
      const tokenId = await mintSong();
      await songAsset.advanceState(tokenId); // Ora siamo in Collaborate

      // Proviamo subito ad avanzare
      await expect(songAsset.advanceState(tokenId))
        .to.be.revertedWith("Errore: Non e' ancora trascorso il tempo necessario per questo stato");
    });

    it("2. Collaborate -> Register: Should pass after 1 day AND strict owner check", async function () {
      const tokenId = await mintSong();
      await songAsset.advanceState(tokenId); // Siamo in Collaborate

      // Viaggiamo nel futuro: 1 giorno + 1 secondo di buffer
      await time.increase(86400 + 1);

      // SECURITY CHECK: Proviamo con un utente 'Approved' (non Owner)
      // addr1 viene approvato
      await songAsset.approve(addr1.address, tokenId);
      // addr1 prova a chiudere la fase Collaborate -> DEVE FALLIRE
      await expect(
        songAsset.connect(addr1).advanceState(tokenId)
      ).to.be.revertedWith("Spyral: Only owner can close Collaboration phase");

      // SUCCESS CHECK: L'owner chiama -> DEVE PASSARE
      await expect(songAsset.advanceState(tokenId))
        .to.emit(songAsset, "StateChanged")
        .withArgs(tokenId, 1, 2, anyValue); // 1=Collaborate, 2=Register
    });

    it("3. Register -> Publish: Should fail if called too early (< 7 days)", async function () {
      const tokenId = await mintSong();
      await songAsset.advanceState(tokenId); // -> Collaborate
      await time.increase(86400 + 1); 
      await songAsset.advanceState(tokenId); // -> Register

      // Proviamo subito
      await expect(songAsset.advanceState(tokenId))
        .to.be.revertedWith("Errore: Non e' ancora trascorso il tempo necessario per questo stato");
    });

    it("3. Register -> Publish: Should pass after 7 days", async function () {
      const tokenId = await mintSong();
      // Setup veloce fino a Register
      await songAsset.advanceState(tokenId); // -> Collaborate
      await time.increase(86400 + 1);
      await songAsset.advanceState(tokenId); // -> Register

      // Viaggiamo nel futuro: 7 giorni (604800 sec)
      await time.increase(604800 + 1);

      await expect(songAsset.advanceState(tokenId))
        .to.emit(songAsset, "StateChanged")
        .withArgs(tokenId, 2, 3, anyValue); // 2=Register, 3=Publish
    });

    it("4. Publish -> Revenue: Should fail if called too early (< 2 days)", async function () {
      const tokenId = await mintSong();
      // Setup veloce fino a Publish
      await songAsset.advanceState(tokenId); 
      await time.increase(86400 + 1);
      await songAsset.advanceState(tokenId); 
      await time.increase(604800 + 1);
      await songAsset.advanceState(tokenId); // -> Publish

      // Proviamo subito
      await expect(songAsset.advanceState(tokenId))
        .to.be.revertedWith("Errore: Non e' ancora trascorso il tempo necessario per questo stato");
    });

    it("4. Publish -> Revenue: Should pass after 2 days", async function () {
      const tokenId = await mintSong();
      // Setup veloce fino a Publish...
      await songAsset.advanceState(tokenId); 
      await time.increase(86400 + 1);
      await songAsset.advanceState(tokenId); 
      await time.increase(604800 + 1);
      await songAsset.advanceState(tokenId); // -> Publish

      // Viaggiamo nel futuro: 2 giorni (172800 sec)
      await time.increase(172800 + 1);

      await expect(songAsset.advanceState(tokenId))
        .to.emit(songAsset, "StateChanged")
        .withArgs(tokenId, 3, 4, anyValue); // 3=Publish, 4=Revenue
    });

    it("5. Revenue -> End: Should revert if trying to advance past Revenue", async function () {
      const tokenId = await mintSong();
      // Portiamo tutto alla fine...
      await songAsset.advanceState(tokenId); 
      await time.increase(86400 + 1);
      await songAsset.advanceState(tokenId); 
      await time.increase(604800 + 1);
      await songAsset.advanceState(tokenId); 
      await time.increase(172800 + 1);
      await songAsset.advanceState(tokenId); // -> Revenue

      // Proviamo ad andare oltre
      await expect(songAsset.advanceState(tokenId))
        .to.be.revertedWith("Canzone gia nello stato finale");
    });

  });

});

