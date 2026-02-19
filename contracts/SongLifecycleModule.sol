// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./SongStorage.sol";

/// @title Spyral Song Lifecycle Module
/// @notice Modulo: lifecycle manuale + collaborazione + registrazione SpotifyId.
abstract contract SongLifecycleModule is ERC721, SongStorage, Ownable {
    using Strings for uint256;

    /// @notice Crea un nuovo NFT musicale associato a un file audio.
    /// @dev Utilizza ID sequenziali per minimizzare i costi di scrittura e semplificare l'iterazione.
    /// @param to Indirizzo che riceverà l'NFT (primo collaboratore al 100%).
    /// @param _audioHash Hash del file calcolato off-chain per risparmiare gas.
    /// @return newItemId L'ID univoco del token appena generato.
    function mintSong(address to, bytes32 _audioHash) public onlyOwner returns (uint256) {
        uint256 newItemId = _nextTokenId;
        
        // @dev unchecked safe qui: uint256 non può andare in overflow con incrementi unitari
        unchecked { _nextTokenId++; } 

        _safeMint(to, newItemId);

        _songs[newItemId] = Song({
            currentState: LifecycleState.Upload,
            lastStateChange: uint64(block.timestamp),
            totalRevenue: 0,
            audioHash: _audioHash,
            publishedAt: 0, 
            streamCount: 0,
            spotifyId: ""
        });
        
        _collaborators[newItemId].push(Collaborator(payable(to), 100));

        return newItemId;
    }

    /// @notice Aggiunge un collaboratore e diluisce la quota del proprietario originale.
    /// @dev Può essere chiamato solo durante la fase 'Collaborate' e solo dal proprietario dell'NFT.
    /// @param tokenId ID della canzone.
    /// @param wallet Indirizzo del nuovo collaboratore.
    /// @param splitPercentage Percentuale da sottrarre all'owner e assegnare al collaboratore.
    function addCollaborator(uint256 tokenId, address payable wallet, uint8 splitPercentage) public {
        // Verifica fase
        require(_songs[tokenId].currentState == LifecycleState.Collaborate, "Spyral: Not in Collaborate phase");
        
        // Verifica autorizzazione standard v5
        address owner = ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        
        require(splitPercentage > 0 && splitPercentage <= 100, "Spyral: Invalid percentage");

        // Logica di ridistribuzione quote
        bool ownerFound = false;
        uint256 ownerIndex;
        uint256 len = _collaborators[tokenId].length;

        for (uint i = 0; i < len; i++) {
            if (_collaborators[tokenId][i].wallet == owner) {
                ownerIndex = i;
                ownerFound = true;
                break;
            }
        }

        require(ownerFound, "Spyral: Owner missing in collaborator list");
        require(_collaborators[tokenId][ownerIndex].splitPercentage >= splitPercentage, "Spyral: Insufficient shares");

        _collaborators[tokenId][ownerIndex].splitPercentage -= splitPercentage;
        _collaborators[tokenId].push(Collaborator(wallet, splitPercentage));
    }

    /// @notice Avanza lo stato della canzone alla fase successiva.
    /// @dev Gestisce i cooldown temporali tra uno stato e l'altro per sicurezza.
    /// @param tokenId ID della canzone da far avanzare.
    function advanceState(uint256 tokenId) public {
        address owner = ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        
        Song storage song = _songs[tokenId];
        LifecycleState currentState = song.currentState;
        
        // Blocchi di sicurezza: gli stati successivi sono gestiti dall'Oracolo
        require(currentState != LifecycleState.Register, "Stop: Use Oracle to Publish");
        require(currentState != LifecycleState.Publish, "Stop: Need 1000 streams to unlock Revenue");
        require(currentState != LifecycleState.Revenue, "Already in final state");

        // Avanzamento manuale consentito solo per le prime fasi
        if (currentState == LifecycleState.Upload) {
            song.currentState = LifecycleState.Collaborate;
        } else if (currentState == LifecycleState.Collaborate) {
            require(msg.sender == owner, "Spyral: Only owner can close phase");
            song.currentState = LifecycleState.Register;
        }

        LifecycleState oldState = currentState; // Salvo vecchio stato per evento
        song.lastStateChange = uint64(block.timestamp);
        emit StateChanged(tokenId, oldState, song.currentState, song.lastStateChange);
    }

    /// @notice Collega un ID Spotify a una canzone durante la fase di Register.
    /// @dev Può essere chiamata solo dal proprietario del token (o indirizzo autorizzato).
    ///      L'operazione è consentita esclusivamente nello stato `Register` per garantire
    ///      coerenza con il flusso di pubblicazione verificato tramite Oracle.
    ///      L'ID Spotify viene successivamente utilizzato dalla funzione
    ///      `requestOracleCheck` per verificare la pubblicazione del brano.
    /// @param tokenId L'ID univoco dell'NFT musicale.
    /// @param _spotifyId L'identificativo ufficiale della traccia su Spotify (es. 22 caratteri alfanumerici).
    function setSpotifyId(uint256 tokenId, string calldata _spotifyId) external {
        _requireOwned(tokenId);

        // Verifica autorizzazione (owner o approved)
        address owner = ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);

        // Consentito solo durante la fase Register
        require(
            _songs[tokenId].currentState == LifecycleState.Register,
            "Spyral: Not in Register phase"
        );

        require(bytes(_spotifyId).length > 0, "Spyral: Empty Spotify ID");

        _songs[tokenId].spotifyId = _spotifyId;

        emit SpotifyIdSet(tokenId, _spotifyId);
    }

    /// @notice Aggiorna il contatore stream (es. al raggiungimento di milestone 100k)
    /// @dev Solo l'owner (Spyral Backend) può chiamarla per evitare dati falsi, è una funzione di backup per God Mode dell'owner.
    function updateStreamMilestone(uint256 tokenId, uint128 newStreamCount) public onlyOwner {
        _requireOwned(tokenId);
        require(newStreamCount > _songs[tokenId].streamCount, "New count must be higher");
        
        _songs[tokenId].streamCount = newStreamCount;
        emit StreamCountUpdated(tokenId, newStreamCount);
    }

    /// @notice Aggiorna l'indirizzo base dei metadati (IPFS CID).
    function setBaseURI(string memory newBaseURI) public onlyOwner {
        _baseTokenURI = newBaseURI;
    }

    /// @notice Restituisce l'URI dei metadati dinamici in base allo stato attuale.
    /// @dev Sovrascrive la funzione ERC721 per puntare ad API server.
    /// @param tokenId ID della canzone.
    /// @return Stringa completa dell'URI.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory baseURI = _baseTokenURI;    
        return string.concat(baseURI, tokenId.toString());
    }

    /// @notice Restituisce la lista dei collaboratori per un dato token.
    function getCollaborators(uint256 tokenId) public view returns (Collaborator[] memory) {
        return _collaborators[tokenId];
    }

    /// @notice Restituisce i dati critici on-chain di una canzone specifica.
    /// @dev Utile per il frontend per ottenere stato, revenue e integrità audio in una sola chiamata senza passare dall'API.
    /// @param tokenId L'ID univoco del token NFT.
    /// @return currentState La fase attuale del ciclo di vita (es. Upload, Publish, Revenue).
    /// @return publishedAt Il timestamp (in secondi) di quando la canzone è stata pubblicata.
    /// @return streamCount Il numero di ascolti (aggiornato periodicamente tramite pietre miliari).
    /// @return totalRevenue Il totale dei guadagni (in wei) accumulati dalla canzone nella sua storia.
    /// @return audioHash L'hash crittografico del file audio originale per verifica di integrità.
    function getSongData(uint256 tokenId) public view returns (
        LifecycleState currentState,
        uint64 publishedAt,
        uint128 streamCount,
        uint128 totalRevenue,
        bytes32 audioHash,
        string memory spotifyId
    ) {
        _requireOwned(tokenId);
        Song memory song = _songs[tokenId];
        
        return (
            song.currentState, 
            song.publishedAt, 
            song.streamCount, 
            song.totalRevenue, 
            song.audioHash,
            song.spotifyId
        );
    }
}
