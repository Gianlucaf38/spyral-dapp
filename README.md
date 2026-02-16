# University Project: Spyral Song Asset – Dynamic NFT Lifecycle Management

This project was developed for a university examination to demonstrate advanced concepts in **Smart Contract Development**, including state machines, access control, and dynamic metadata management on the **EVM-compatible Base Network**.

---

## 1. Project Overview

The **SongAsset** smart contract represents a musical track as a **Dynamic NFT (dNFT)**. Unlike traditional static NFTs, this asset evolves through a predefined **5-stage lifecycle**, updating its state and metadata on-chain to reflect the real-world progress of the song.

### The 5 Stages of the Lifecycle:

1. 
**Upload**: Initial registration of the song asset.


2. 
**Collaborate**: Management of creative partners and royalty splits.


3. 
**Register**: Legal and technical consolidation of the asset.


4. 
**Publish**: Official release and commercialization.


5. 
**Revenue**: Active phase for stream tracking and profit distribution.



---

## 2. Technical Architecture

The contract is built using the **Solidity 0.8.20** compiler and utilizes the **OpenZeppelin** library for industry-standard security.

### Core Components:

* 
**ERC-721 Standard**: Ensures ownership, transferability, and compatibility with NFT marketplaces.


* 
**Hybrid Metadata Model**: The contract utilizes a hybrid approach where critical data (stream counts, revenue, state) is stored on-chain, while the `tokenURI` points to a dynamic API to serve rich metadata efficiently.


* 
**State Machine Management**: Transitions between stages are restricted and governed by logic that ensures only authorized owners can advance the song's lifecycle.


* 
**Royalty Distribution**: A dedicated system manages collaborators and their respective split percentages (e.g., 25 for 25%), ensuring automated and transparent revenue sharing.


---

## 3. Deployment Guide (Base Sepolia)

The project is configured for deployment on the **Base Sepolia Testnet** using the **Hardhat** development environment.

1. 
**Environment Setup**: Install Node.js and dependencies (`@openzeppelin/contracts`, `dotenv`).


2. 
**Configuration**: Define the `BASE_SEPOLIA_RPC_URL` and `PRIVATE_KEY` in a `.env` file.


3. **Deployment**: Execute the deploy script via Hardhat:

`npx hardhat run scripts/deploy.js --network baseSepolia`.


4. 
**Verification**: Verify the contract on Basescan to allow public interaction via the explorer.



---

## 4. Project Conclusions

This implementation demonstrates a scalable solution for dynamic assets. By keeping critical state data on-chain while utilizing off-chain APIs for presentation, the **Spyral Song Asset** achieves a balance between decentralization, cost-efficiency, and flexibility.

**Author**: Gianluca Di Bella, Gianluca Fontanella, Nicola Grandioso

**Version**: 1.1 

**Network**: Base (EVM) 
