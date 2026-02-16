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
        .to.be.revertedWith("Errore: Non e ancora trascorso il tempo necessario per questo stato");
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
        .to.be.revertedWith("Errore: Non e ancora trascorso il tempo necessario per questo stato");
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
        .to.be.revertedWith("Errore: Non e ancora trascorso il tempo necessario per questo stato");
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
  
  describe("Royalty Logic & Split Management", function () {
    
    // Helper per settare lo stato a Collaborate
    async function mintAndReadyToCollab() {
        await songAsset.mintSong(owner.address, AUDIO_HASH);
        await songAsset.advanceState(0); 
        return 0; // TokenId
    }

    it("Should initialize owner with 100% split upon minting", async function () {
        const tokenId = await mintAndReadyToCollab();
        
        const collaborators = await songAsset.getCollaborators(tokenId);
        
        expect(collaborators.length).to.equal(1);
        expect(collaborators[0].wallet).to.equal(owner.address);
        expect(collaborators[0].splitPercentage).to.equal(100);
    });

    it("Should deduct percentage from owner when adding a collaborator", async function () {
        const tokenId = await mintAndReadyToCollab();

        // Aggiungiamo addr1 con il 20%
        await songAsset.addCollaborator(tokenId, addr1.address, 20);

        const collaborators = await songAsset.getCollaborators(tokenId);

        // L'owner (indice 0) dovrebbe scendere a 80
        expect(collaborators[0].splitPercentage).to.equal(80);
        // Il nuovo (indice 1) dovrebbe essere a 20
        expect(collaborators[1].wallet).to.equal(addr1.address);
        expect(collaborators[1].splitPercentage).to.equal(20);
    });

    it("Should handle multiple collaborators correctly (Chain dilution)", async function () {
        const tokenId = await mintAndReadyToCollab();
        const [ownerSigner, collab1, collab2] = await ethers.getSigners();

        // 1. Aggiungiamo Collab1 al 20% (Owner scende a 80%)
        await songAsset.addCollaborator(tokenId, collab1.address, 20);
        
        // 2. Aggiungiamo Collab2 al 40% (Owner scende a 40%)
        await songAsset.addCollaborator(tokenId, collab2.address, 40);

        const collaborators = await songAsset.getCollaborators(tokenId);

        // Verifica Owner
        expect(collaborators[0].splitPercentage).to.equal(40); // 100 - 20 - 40
        // Verifica Collab1
        expect(collaborators[1].splitPercentage).to.equal(20);
        // Verifica Collab2
        expect(collaborators[2].splitPercentage).to.equal(40);
    });

    it("Should ensure total percentage always equals 100", async function () {
        const tokenId = await mintAndReadyToCollab();
        const [ownerSigner, c1, c2, c3] = await ethers.getSigners();

        await songAsset.addCollaborator(tokenId, c1.address, 10);
        await songAsset.addCollaborator(tokenId, c2.address, 25);
        await songAsset.addCollaborator(tokenId, c3.address, 15);

        const collaborators = await songAsset.getCollaborators(tokenId);
        
        let total = 0;
        for (let c of collaborators) {
            total += Number(c.splitPercentage);
        }

        expect(total).to.equal(100);
    });

    it("Should revert if owner does not have enough equity left", async function () {
        const tokenId = await mintAndReadyToCollab();

        // Owner ha 100%. Proviamo a dare 110% a qualcun altro.
        await expect(
            songAsset.addCollaborator(tokenId, addr1.address, 110) // > 100
        ).to.be.reverted; // Il check nel contratto o l'underflow matematico lo bloccherà

        // Caso limite: Owner ha 20%, proviamo a toglierne 30%
        await songAsset.addCollaborator(tokenId, addr1.address, 80); // Owner ora ha 20%
        
        await expect(
            songAsset.addCollaborator(tokenId, addr1.address, 30)
        ).to.be.revertedWith("L'owner non ha abbastanza quote disponibili");
    });
  });

  describe("TokenURI & Metadata Correctness", function () {
      
    it("Should return correct URI for each lifecycle state", async function () {
        // MINT (State: Upload)
        await songAsset.mintSong(owner.address, AUDIO_HASH);
        expect(await songAsset.tokenURI(0)).to.contain("upload.json");

        // ADVANCE -> Collaborate
        await songAsset.advanceState(0);
        expect(await songAsset.tokenURI(0)).to.contain("collaborate.json");

        // ADVANCE -> Register (Richiede 1 giorno di attesa)
        await time.increase(86400 + 10);
        await songAsset.advanceState(0);
        expect(await songAsset.tokenURI(0)).to.contain("register.json");

        // ADVANCE -> Publish (Richiede 7 giorni di attesa)
        await time.increase(604800 + 10);
        await songAsset.advanceState(0);
        expect(await songAsset.tokenURI(0)).to.contain("publish.json");

        // ADVANCE -> Revenue (Richiede 2 giorni di attesa)
        await time.increase(172800 + 10);
        await songAsset.advanceState(0);
        expect(await songAsset.tokenURI(0)).to.contain("revenue.json");
    });

    it("Should allow owner to update Base URI", async function () {
        const newBase = "ipfs://nuovo-cid-super-figo/";
        await songAsset.setBaseURI(newBase);
        
        // Minta una nuova canzone per testare
        await songAsset.mintSong(owner.address, AUDIO_HASH);
        
        const uri = await songAsset.tokenURI(0); // ID 0
        expect(uri).to.equal(newBase + "upload.json");
    });
  });

});

