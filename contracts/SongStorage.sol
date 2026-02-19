// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Spyral Song Storage
/// @author @gianlucaaf @gnico02
/// @notice Contiene lo stato, le strutture dati e gli eventi per il ciclo di vita della canzone.
/// @dev Modulo di base. Ottimizzato per il risparmio di gas (Storage Packing).
abstract contract SongStorage {

    // --- ENUM E COSTANTI ---

    // Enum per distinguere le richieste all'oracolo
    enum RequestType { CHECK_PUBLICATION, UPDATE_STREAMS }

    // Soglia Stream per sbloccare i pagamenti (Spotify Logic)
    uint128 public constant STREAM_THRESHOLD = 1000;

    /// @notice Stati possibili del ciclo di vita di un asset musicale.
    enum LifecycleState { Upload, Collaborate, Register, Publish, Revenue }

    // --- STRUTTURE DATI ---

    /// @dev Struttura ottimizzata per il gas (Storage Packing).
    struct Song {
        LifecycleState currentState; // Slot 0 (8 bit) - Enum
        uint64 lastStateChange;      // Slot 0 (64 bit) - Timestamp
        uint128 totalRevenue;        // Slot 0 (128 bit) - Max ~3.4 * 10^38
        
        bytes32 audioHash;           // Slot 1 (256 bit) - Hash IPFS/File

        uint64 publishedAt;          // Slot 2 (64 bit) - Timestamp pubblicazione
        uint128 streamCount;         // Slot 2 (128 bit) - Contatore stream
        
        string spotifyId;            // Slot 3 (Dinamico) - ID traccia Spotify
    }

    /// @dev Collaboratore e relativa quota di royalty.
    struct Collaborator {
        address payable wallet;
        uint8 splitPercentage; // Percentuale intera (es. 25 = 25%)
    }

    // --- VARIABILI DI STATO ---

    mapping(uint256 => Song) internal _songs;
    mapping(uint256 => Collaborator[]) internal _collaborators;
    mapping(uint256 => uint256) internal _tokenBalances;
    
    uint256 internal _nextTokenId = 1;
    string internal _baseTokenURI = "https://spyral-dapp-production.up.railway/metadata/";
    
    // --- EVENTI ---

    /// @notice Emesso quando una canzone cambia stato nel ciclo di vita.
    event StateChanged(uint256 indexed tokenId, LifecycleState oldState, LifecycleState newState, uint64 timestamp);

    // @notice Emesso quando viene aggiornato il numero di stream (ogni 100k stream).
    event StreamCountUpdated(uint256 indexed tokenId, uint128 newCount); 

    /// @notice Emesso quando il contratto riceve fondi (revenue) per una canzone.
    event RevenueReceived(uint256 indexed tokenId, uint256 amount);

    /// @notice Emesso quando le royalties vengono distribuite ai collaboratori.
    event RoyaltiesDistributed(uint256 indexed tokenId, uint256 totalAmount);

    /// @notice Emesso quando parte una richiesta asincrona verso la rete Chainlink (Functions).
    event OracleRequestSent(bytes32 indexed requestId, uint256 tokenId, RequestType reqType);

    /// @notice Emesso quando il brano supera la soglia di ascolti (es. 1000 stream) e sblocca la fase di Revenue.
    event MonetizationUnlocked(uint256 indexed tokenId, uint128 streams);

    /// @notice Emesso quando l'ID della traccia Spotify viene collegato all'NFT.
    event SpotifyIdSet(uint256 indexed tokenId, string spotifyId);
}
