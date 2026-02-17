// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @title Spyral Song Asset - Dynamic NFT per la gestione del ciclo di vita musicale
/// @author @gianlucaaf @gnico02
/// @notice Gestisce il ciclo di vita di una canzone (DNFT) dalla creazione alla ridistribuzione dei proventi.
/// @dev Eredita da ERC721 (OpenZeppelin v5.x) e Ownable. Ottimizzato per il risparmio di gas e "Single Source of Truth".
contract SongAsset is ERC721, Ownable {
    using Strings for uint256;

    /// @notice Stati possibili del ciclo di vita di un asset musicale.
    enum LifecycleState { Upload, Collaborate, Register, Publish, Revenue }

    /// @dev Struttura ottimizzata per occupare esattamente 2 slot da 32 byte (gas optimization).
    struct Song {
        LifecycleState currentState; // Slot 1 (8 bit)
        uint64 lastStateChange;      // Slot 1 (64 bit) - Timestamp dell'ultima transizione
        uint128 totalRevenue;        // Slot 1 (128 bit) - Sufficiente per cifre astronomiche (10^38)
        bytes32 audioHash;           // Slot 2 (256 bit) - Hash per l'integrità del file audio

        uint64 publishedAt;          // Slot 3 (64 bit)
        uint128 streamCount;         // Slot 3 (128 bit)

    }

    /// @dev Collaboratore e relativa quota di royalty.
    struct Collaborator {
        address payable wallet;
        uint8 splitPercentage; // Percentuale intera (es. 25 = 25%)
    }

    mapping(uint256 => Song) private _songs;
    mapping(uint256 => Collaborator[]) private _collaborators;
    mapping(uint256 => uint256) private _tokenBalances;
    uint256 private _nextTokenId;
    string private _baseTokenURI = "https://api.spyral.com/metadata/";

    /// @notice Emesso quando una canzone cambia stato nel ciclo di vita.
    event StateChanged(uint256 indexed tokenId, LifecycleState oldState, LifecycleState newState, uint64 timestamp);

    // @notice Emesso quando viene aggiornato il numero di stream (ogni 100k stream).
    event StreamCountUpdated(uint256 indexed tokenId, uint128 newCount); 

    /// @notice Emesso quando il contratto riceve fondi (revenue) per una canzone.
    event RevenueReceived(uint256 indexed tokenId, uint256 amount);

    /// @notice Emesso quando le royalties vengono distribuite ai collaboratori.
    event RoyaltiesDistributed(uint256 indexed tokenId, uint256 totalAmount);


    /// @dev Inizializza il contratto impostando il nome, il simbolo e l'owner iniziale.
    /// @param initialOwner Indirizzo che avrà i poteri di amministrazione (minter).
    constructor(address initialOwner) 
        ERC721("Spyral Song Asset", "SPYRAL") 
        Ownable(initialOwner)
    {}

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
            streamCount: 0
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
        
        // Verifica autorizzazione (Strict Owner)
        address owner = ownerOf(tokenId);
        require(owner == msg.sender, "Spyral: Only owner can add collaborators");
        require(splitPercentage > 0 && splitPercentage <= 100, "Spyral: Invalid percentage");

        // @dev Check autorizzazione standard v5
        _checkAuthorized(owner, msg.sender, tokenId);

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

    /// @notice Aggiorna il contatore stream (es. al raggiungimento di milestone 100k)
    /// @dev Solo l'owner (Spyral Backend) può chiamarla per evitare dati falsi.
    function updateStreamMilestone(uint256 tokenId, uint128 newStreamCount) public onlyOwner {
        _requireOwned(tokenId);
        require(newStreamCount > _songs[tokenId].streamCount, "New count must be higher");
        
        _songs[tokenId].streamCount = newStreamCount;
        emit StreamCountUpdated(tokenId, newStreamCount);
    }

    /// @notice Avanza lo stato della canzone alla fase successiva.
    /// @dev Gestisce i cooldown temporali tra uno stato e l'altro per sicurezza.
    /// @param tokenId ID della canzone da far avanzare.
    function advanceState(uint256 tokenId) public {
        address owner = ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        
        Song storage song = _songs[tokenId];
        LifecycleState currentState = song.currentState;
        uint64 requiredWait = getCooldownForState(currentState);

        require(block.timestamp >= song.lastStateChange + requiredWait, "Spyral: Cooldown active");

        if (currentState == LifecycleState.Upload) {
            song.currentState = LifecycleState.Collaborate;
        } else if (currentState == LifecycleState.Collaborate) {
            // @dev Solo l'owner reale può chiudere la fase di collaborazione
            require(msg.sender == owner, "Spyral: Only owner can close phase");
            song.currentState = LifecycleState.Register;
        } else if (currentState == LifecycleState.Register) {
            song.currentState = LifecycleState.Publish;
            song.publishedAt = uint64(block.timestamp); //il timestamp corrente è quello di pubblicazione
        } else if (currentState == LifecycleState.Publish) {
            song.currentState = LifecycleState.Revenue;
        } else {
            revert("Spyral: Already in final state");
        }

        song.lastStateChange = uint64(block.timestamp);
        emit StateChanged(tokenId, currentState, song.currentState, song.lastStateChange);
    }

    /// @notice Restituisce i tempi di attesa obbligatori per ogni stato.
    /// @param state Lo stato di cui si vuole conoscere il cooldown.
    /// @return Tempo in secondi (uint64).
    function getCooldownForState(LifecycleState state) public pure returns (uint64) {
        if (state == LifecycleState.Upload) return 0;
        if (state == LifecycleState.Collaborate) return 1 days;
        if (state == LifecycleState.Register) return 7 days;
        if (state == LifecycleState.Publish) return 2 days;
        return 0;
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

    /// @notice Aggiorna l'indirizzo base dei metadati (IPFS CID).
    function setBaseURI(string memory newBaseURI) public onlyOwner {
        _baseTokenURI = newBaseURI;
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
        bytes32 audioHash
    ) {
        // Controllo esistenza token (versione corretta per OpenZeppelin v5)
        _requireOwned(tokenId);

        Song memory song = _songs[tokenId];
        
        return (
            song.currentState, 
            song.publishedAt, 
            song.streamCount, 
            song.totalRevenue, 
            song.audioHash
        );
    }

    /// @notice Deposita revenue per una SPECIFICA canzone.
    function depositRevenue(uint256 tokenId) public payable {
        _requireOwned(tokenId);
        require(msg.value > 0, "No value sent");
        
        // Aggiorna lo storico totale (Vanity Metric)
        _songs[tokenId].totalRevenue += uint128(msg.value);
        
        // Aggiorna il saldo prelevabile SPECIFICO per questa canzone
        _tokenBalances[tokenId] += msg.value;
        
        emit RevenueReceived(tokenId, msg.value);
    }

    /// @notice Distribuisce royalties. Include sia msg.value immediato che saldo accumulato.
    function distributeRoyalties(uint256 tokenId) public payable {
        require(_songs[tokenId].currentState == LifecycleState.Revenue, "Not in Revenue phase");
        _requireOwned(tokenId);

        // 1. Gestione di nuovi fondi in ingresso (Push)
        if (msg.value > 0) {
            _songs[tokenId].totalRevenue += uint128(msg.value);
            _tokenBalances[tokenId] += msg.value;
            emit RevenueReceived(tokenId, msg.value);
        }

        // 2. Calcolo del totale distribuibile per QUESTA canzone
        uint256 amountToDistribute = _tokenBalances[tokenId];
        require(amountToDistribute > 0, "No funds to distribute for this song");

        // 3. Azzeriamo il saldo PRIMA di inviare (Pattern Checks-Effects-Interactions)
        _tokenBalances[tokenId] = 0;

        Collaborator[] memory collaborators = _collaborators[tokenId];
        
        for (uint i = 0; i < collaborators.length; i++) {
            uint256 amount = (amountToDistribute * collaborators[i].splitPercentage) / 100;
            
            if (amount > 0) {
                (bool success, ) = collaborators[i].wallet.call{value: amount}("");
                require(success, "Transfer failed");
            }
        }

        emit RoyaltiesDistributed(tokenId, amountToDistribute);
    }

}