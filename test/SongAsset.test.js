const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
describe("Spyral SongAsset (Full Suite)", function () {
  
  // Costanti utili
  const AUDIO_HASH = ethers.keccak256(ethers.toUtf8Bytes("spyral-audio-test"));
  const INITIAL_URI = "https://spyral-dapp-production.up.railway/metadata/";
  const TOKEN_ID = 1; // Il contatore parte da 1 nello smart contract fornito

  // Enums (devono corrispondere allo Smart Contract)
  const STATE = {
    Upload: 0,
    Collaborate: 1,
    Register: 2,
    Publish: 3,
    Revenue: 4
  };

  const REQUEST_TYPE = {
    CHECK_PUBLICATION: 0,
    UPDATE_STREAMS: 1
  };

  // Fixture per il setup (ottimizza la velocità dei test)
  async function deployFixture() {
    const [owner, user, collaborator, rando] = await ethers.getSigners();

    // 1. Deploy Mock Router
    const MockRouter = await ethers.getContractFactory("MockRouter");
    const router = await MockRouter.deploy();
    await router.waitForDeployment();

    // 2. Deploy SongAsset Mock (versione testabile)
    const SongAssetMock = await ethers.getContractFactory("SongAssetMock");
    const contract = await SongAssetMock.deploy(owner.address, router.target);
    await contract.waitForDeployment();

    return { contract, router, owner, user, collaborator, rando };
  }

  // Helper per estrarre RequestID dagli eventi
  async function getRequestIdFromTx(tx) {
    const receipt = await tx.wait();
    const event = receipt.logs.find(log => log.fragment && log.fragment.name === "OracleRequestSent");
    return event.args.requestId;
  }

  describe("1. Deployment & Minting", function () {
    it("Should set the right owner and initial counters", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      expect(await contract.owner()).to.equal(owner.address);
    });

    it("Should mint with ID 1 and correct initial state", async function () {
      const { contract, user } = await loadFixture(deployFixture);

      await contract.mintSong(user.address, AUDIO_HASH);

      const songData = await contract.getSongData(TOKEN_ID);
      
      expect(await contract.ownerOf(TOKEN_ID)).to.equal(user.address);
      expect(songData.currentState).to.equal(STATE.Upload);
      expect(songData.audioHash).to.equal(AUDIO_HASH);
      expect(songData.streamCount).to.equal(0);
    });
  });

  describe("2. Manual State Transitions (Upload -> Register)", function () {
    it("Should allow advancing from Upload to Collaborate", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      await contract.mintSong(owner.address, AUDIO_HASH);

      await expect(contract.advanceState(TOKEN_ID))
        .to.emit(contract, "StateChanged")
        .withArgs(TOKEN_ID, STATE.Upload, STATE.Collaborate, anyValue);
    });

    it("Should allow advancing from Collaborate to Register", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      await contract.mintSong(owner.address, AUDIO_HASH);
      await contract.advanceState(TOKEN_ID); // -> Collaborate

      await expect(contract.advanceState(TOKEN_ID))
        .to.emit(contract, "StateChanged")
        .withArgs(TOKEN_ID, STATE.Collaborate, STATE.Register, anyValue);
    });

    it("Should REVERT if trying to advance manually past Register", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      await contract.mintSong(owner.address, AUDIO_HASH);
      await contract.advanceState(TOKEN_ID); // -> Collaborate
      await contract.advanceState(TOKEN_ID); // -> Register

      // Da Register a Publish serve l'Oracolo!
      await expect(contract.advanceState(TOKEN_ID))
        .to.be.revertedWith("Stop: Use Oracle to Publish");
    });
  });

  describe("3. Collaborator Management", function () {
    it("Should allow adding a collaborator and update splits correctly", async function () {
      const { contract, owner, collaborator } = await loadFixture(deployFixture);
      await contract.mintSong(owner.address, AUDIO_HASH);
      
      // Deve essere in fase Collaborate
      await contract.advanceState(TOKEN_ID); 

      // Aggiunge collaborator al 20%
      await contract.addCollaborator(TOKEN_ID, collaborator.address, 20);

      const collabs = await contract.getCollaborators(TOKEN_ID);
      
      // Owner (index 0) scende a 80
      expect(collabs[0].splitPercentage).to.equal(80);
      expect(collabs[0].wallet).to.equal(owner.address);

      // Collaborator (index 1) ha 20
      expect(collabs[1].splitPercentage).to.equal(20);
      expect(collabs[1].wallet).to.equal(collaborator.address);
    });

    it("Should revert if adding collaborator in wrong phase", async function () {
      const { contract, owner, collaborator } = await loadFixture(deployFixture);
      await contract.mintSong(owner.address, AUDIO_HASH);
      // Fase Upload (troppo presto)
      
      await expect(
        contract.addCollaborator(TOKEN_ID, collaborator.address, 20)
      ).to.be.revertedWith("Spyral: Not in Collaborate phase");
    });

    it("Should revert if non-owner tries to add collaborator", async function () {
      const { contract, owner, collaborator, rando } = await loadFixture(deployFixture);
      await contract.mintSong(owner.address, AUDIO_HASH);
      await contract.advanceState(TOKEN_ID);

     await expect(
  	contract.connect(rando).addCollaborator(TOKEN_ID, collaborator.address, 20)
	).to.be.revertedWithCustomError(contract, "ERC721InsufficientApproval");
  });
  
  });

  describe("4. Oracle Integration (Register -> Publish -> Revenue)", function () {
    
    // Helper per portare lo stato a Register
    async function setupToRegister(contract, owner) {
      await contract.mintSong(owner.address, AUDIO_HASH);
      await contract.advanceState(TOKEN_ID); // -> Collaborate
      await contract.advanceState(TOKEN_ID); // -> Register
    }

    it("Should set Spotify ID correctly", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      await setupToRegister(contract, owner);

      await expect(contract.setSpotifyId(TOKEN_ID, "spotify:track:test"))
        .to.emit(contract, "SpotifyIdSet")
        .withArgs(TOKEN_ID, "spotify:track:test");
    });

    it("Should use Oracle to move from Register to Publish", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      await setupToRegister(contract, owner);
      await contract.setSpotifyId(TOKEN_ID, "TEST_ID");

      // 1. Richiesta Oracle (Check Publication)
      const tx = await contract.requestOracleCheck(
        TOKEN_ID, 
        REQUEST_TYPE.CHECK_PUBLICATION, 
        "return Functions.encodeUint256(1);"
      );
      
      const requestId = await getRequestIdFromTx(tx);

      // 2. Simulazione Risposta (MockFulfill) - 1 = Pubblicato
      const encodedResponse = ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [1]);
      await contract.mockFulfill(requestId, encodedResponse);

      // 3. Verifica Stato
      const data = await contract.getSongData(TOKEN_ID);
      expect(data.currentState).to.equal(STATE.Publish);
      expect(data.publishedAt).to.be.gt(0); // Timestamp impostato
    });

    it("Should update streams but NOT change state if threshold < 1000", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      // ... setup fino a Publish ...
      await setupToRegister(contract, owner);
      await contract.setSpotifyId(TOKEN_ID, "TEST");
      const tx1 = await contract.requestOracleCheck(TOKEN_ID, 0, "source");
      const reqId1 = await getRequestIdFromTx(tx1);
      await contract.mockFulfill(reqId1, ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [1]));

      // Ora siamo in Publish. Aggiorniamo Streams a 500
      const tx2 = await contract.requestOracleCheck(TOKEN_ID, REQUEST_TYPE.UPDATE_STREAMS, "source");
      const reqId2 = await getRequestIdFromTx(tx2);
      
      const encodedStreams = ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [500]);
      await contract.mockFulfill(reqId2, encodedStreams);

      const data = await contract.getSongData(TOKEN_ID);
      expect(data.streamCount).to.equal(500);
      expect(data.currentState).to.equal(STATE.Publish); // Ancora in Publish
    });

    it("Should move to Revenue when streams >= 1000", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      // ... setup veloce fino a Publish ...
      await setupToRegister(contract, owner);
      await contract.setSpotifyId(TOKEN_ID, "TEST");
      const tx1 = await contract.requestOracleCheck(TOKEN_ID, 0, "source");
      const reqId1 = await getRequestIdFromTx(tx1);
      await contract.mockFulfill(reqId1, ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [1]));

      // Aggiorniamo Streams a 1500 (Sopra soglia)
      const tx2 = await contract.requestOracleCheck(TOKEN_ID, REQUEST_TYPE.UPDATE_STREAMS, "source");
      const reqId2 = await getRequestIdFromTx(tx2);
      
      const encodedStreams = ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [1500]);
      
      await expect(contract.mockFulfill(reqId2, encodedStreams))
        .to.emit(contract, "MonetizationUnlocked")
        .withArgs(TOKEN_ID, 1500)
        .to.emit(contract, "StateChanged")
        .withArgs(TOKEN_ID, STATE.Publish, STATE.Revenue, anyValue);
      
      const data = await contract.getSongData(TOKEN_ID);
      expect(data.currentState).to.equal(STATE.Revenue);
    });
  });

  describe("5. Financials (Revenue & Royalties)", function () {
    
    async function setupToRevenue(contract, owner, collaborator) {
      // Setup completo: Mint -> Collab -> Register -> Publish -> Revenue
      await contract.mintSong(owner.address, AUDIO_HASH);
      await contract.advanceState(TOKEN_ID); 
      // Aggiungiamo collaboratore (Owner 80%, Collab 20%)
      await contract.addCollaborator(TOKEN_ID, collaborator.address, 20);
      await contract.advanceState(TOKEN_ID);
      await contract.setSpotifyId(TOKEN_ID, "TEST");
      
      // Publish
      let tx = await contract.requestOracleCheck(TOKEN_ID, 0, "src");
      let rid = await getRequestIdFromTx(tx);
      await contract.mockFulfill(rid, ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [1]));

      // Revenue (Streams > 1000)
      tx = await contract.requestOracleCheck(TOKEN_ID, 1, "src");
      rid = await getRequestIdFromTx(tx);
      await contract.mockFulfill(rid, ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [2000]));
    }

    it("Should accept deposits ONLY in Revenue phase", async function () {
      const { contract, owner, collaborator } = await loadFixture(deployFixture);
      await setupToRevenue(contract, owner, collaborator);

      // Deposito 1 ETH
      await expect(contract.depositRevenue(TOKEN_ID, { value: ethers.parseEther("1.0") }))
        .to.emit(contract, "RevenueReceived")
        .withArgs(TOKEN_ID, ethers.parseEther("1.0"));

      const data = await contract.getSongData(TOKEN_ID);
      expect(data.totalRevenue).to.equal(ethers.parseEther("1.0"));
    });

    it("Should revert deposit if not in Revenue phase", async function () {
      const { contract, owner } = await loadFixture(deployFixture);
      await contract.mintSong(owner.address, AUDIO_HASH);
      // Siamo in Upload

      await expect(
        contract.depositRevenue(TOKEN_ID, { value: ethers.parseEther("1.0") })
      ).to.be.revertedWith("Spyral: Song threshold not reached yet");
    });

    it("Should distribute royalties correctly", async function () {
      const { contract, owner, collaborator } = await loadFixture(deployFixture);
      await setupToRevenue(contract, owner, collaborator);

      // Deposita 10 ETH
      const depositAmount = ethers.parseEther("10.0");
      await contract.depositRevenue(TOKEN_ID, { value: depositAmount });

      // Controlla bilanci prima della distribuzione
      const initialOwnerBal = await ethers.provider.getBalance(owner.address);
      const initialCollabBal = await ethers.provider.getBalance(collaborator.address);

      // Distribuisci
      // Usiamo una transaction separata per non confondere il gas cost col balance
      await contract.distributeRoyalties(TOKEN_ID);

      // Owner dovrebbe ricevere 80% (8 ETH)
      // Collaborator dovrebbe ricevere 20% (2 ETH)
      
      // Nota: Owner paga il gas, quindi il balance sarà (Initial + 8 ETH - Gas).
      // Collaborator non paga gas, quindi il balance sarà esattamente (Initial + 2 ETH).
      
      const finalCollabBal = await ethers.provider.getBalance(collaborator.address);
      
      expect(finalCollabBal).to.equal(initialCollabBal + ethers.parseEther("2.0"));
    });
  });

  describe("6. Token URI", function () {
    it("Should return the correct API URL", async function () {
      const { contract, user } = await loadFixture(deployFixture);
      await contract.mintSong(user.address, AUDIO_HASH);
      
      // Il contratto usa string.concat(_baseTokenURI, tokenId)
      // Base default: "https://api.spyral.com/metadata/"
      
      expect(await contract.tokenURI(TOKEN_ID)).to.equal(INITIAL_URI + "1");
    });
  });

});
