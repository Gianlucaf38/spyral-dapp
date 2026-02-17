// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// IMPORT CHAINLINK
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/// @title Spyral Song Asset - Dynamic NFT per la gestione del ciclo di vita musicale
/// @author @gianlucaaf @gnico02
/// @notice Gestisce il ciclo di vita di una canzone (DNFT) dalla creazione alla ridistribuzione dei proventi.
/// @dev Eredita da ERC721 (OpenZeppelin v5.x) e Ownable. Ottimizzato per il risparmio di gas e "Single Source of Truth".
contract SongAsset is ERC721, Ownable, FunctionsClient {
    using Strings for uint256;
    using FunctionsRequest for FunctionsRequest.Request;

    // Enum per distinguere le richieste all'oracolo
    enum RequestType { CHECK_PUBLICATION, UPDATE_STREAMS }

    // Soglia Stream per sbloccare i pagamenti (Spotify Logic)
    uint128 public constant STREAM_THRESHOLD = 1000;

    /// @notice Stati possibili del ciclo di vita di un asset musicale.
    enum LifecycleState { Upload, Collaborate, Register, Publish, Revenue }

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

    mapping(uint256 => Song) private _songs;
    mapping(uint256 => Collaborator[]) private _collaborators;
    mapping(uint256 => uint256) private _tokenBalances;
    uint256 private _nextTokenId = 1;
    string private _baseTokenURI = "https://api.spyral.com/metadata/";

  // --- CONFIGURAZIONE CHAINLINK FUNCTIONS ---

    /// @dev ID della Decentralized Oracle Network (DON). Specifica quale rete di nodi eseguirà il codice JS.
    /// @notice Cambia in base alla chain (es. Polygon Amoy, Base Sepolia).
    bytes32 public donId; 

    /// @dev ID della sottoscrizione Chainlink per il pagamento delle fee in LINK.
    /// @notice Deve essere finanziata tramite functions.chain.link.
    uint64 public subscriptionId; 

    /// @dev Limite di gas riservato per l'esecuzione della callback `fulfillRequest`.
    /// @notice 300k è sufficiente per aggiornamenti di stato ed eventi; aumentare se la logica diventa complessa.
    uint32 public gasLimit = 300000; 
    
    // --- GESTIONE STATO ASINCRONO ---

    /// @dev Struttura temporanea per preservare il contesto tra la richiesta e la risposta dell'oracolo.
    /// @notice Necessaria perché `fulfillRequest` riceve solo il `requestId` e non sa a quale Token o operazione si riferisce.
    struct PendingRequest {
        uint256 tokenId;    // L'NFT su cui stiamo operando
        RequestType reqType; // Il tipo di operazione (es. verifica pubblicazione o aggiornamento stream)
    }

    /// @dev Mappa l'ID della richiesta (generato da Chainlink) al contesto dell'operazione.
    mapping(bytes32 => PendingRequest) private _pendingRequests;

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


    /// @dev Inizializza il contratto impostando il nome, il simbolo e l'owner iniziale.
    /// @param initialOwner Indirizzo che avrà i poteri di amministrazione (minter), @param router inidirizzo a cui inviare le richieste per Chainlink Oracle.
    constructor(address initialOwner, address router) 
        ERC721("Spyral Song Asset", "SPYRAL") 
        Ownable(initialOwner)
        FunctionsClient(router) // Inizializza client Chainlink
    {}

    // @dev Configura i parametri Chainlink
    function setChainlinkConfig(uint64 _subscriptionId, bytes32 _donId, uint32 _gasLimit) public onlyOwner {
        subscriptionId = _subscriptionId;
        donId = _donId;
        gasLimit = _gasLimit;
    }

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
    /// @dev Solo l'owner (Spyral Backend) può chiamarla per evitare dati falsi, è una funzione di backup per God Mode dell'owner.
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
    

    /// @notice Restituisce i tempi di attesa obbligatori per ogni stato.
    /// @param state Lo stato di cui si vuole conoscere il cooldown.
    /// @return Tempo in secondi (uint64).
    //DEPRECATA 
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

    // --- LOGICA ORACOLO CHAINLINK ---

    /// @notice Invia una richiesta alla rete Chainlink (DON) per eseguire uno script JavaScript off-chain.
    /// @dev Funzione "Trigger". Crea la richiesta, carica gli argomenti e salva il contesto in `_pendingRequests`.
    ///      Richiede il pagamento in LINK (gestito dalla Subscription).
    /// @param tokenId L'ID del token per cui si richiede la verifica.
    /// @param reqType Il tipo di operazione: 0 per verifica pubblicazione, 1 per aggiornamento stream.
    /// @param source Il codice sorgente JavaScript (come stringa) che i nodi Chainlink eseguiranno.
    /// @return requestId L'ID univoco della richiesta generato dal coordinatore Chainlink.
    function requestOracleCheck(uint256 tokenId, RequestType reqType, string calldata source) public onlyOwner returns (bytes32 requestId) {
        _requireOwned(tokenId);
        
        // Validazione specifica per la pubblicazione
        if (reqType == RequestType.CHECK_PUBLICATION) {
            require(_songs[tokenId].currentState == LifecycleState.Register, "Spyral: Not ready to publish");
            require(bytes(_songs[tokenId].spotifyId).length > 0, "Spyral: Spotify ID missing");
        }

        // Preparazione della richiesta (Functions v1)
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source); // Carica il codice JS
        
        string[] memory args = new string[](1);
        args[0] = _songs[tokenId].spotifyId; // Passa l'ID Spotify come argomento al JS (args[0])
        req.setArgs(args);

        // Invio richiesta al Router e salvataggio del mapping per la callback
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId);
        _pendingRequests[requestId] = PendingRequest(tokenId, reqType);

        emit OracleRequestSent(requestId, tokenId, reqType);
        return requestId;
    }

    /// @notice Callback interna chiamata dai nodi Chainlink per restituire il risultato dell'esecuzione JS.
    /// @dev Gestisce la logica di transizione di stato e sblocco monetizzazione.
    ///      ATTENZIONE: Questa funzione consuma gas pagato dalla Subscription, non dall'utente.
    /// @param requestId L'ID della richiesta originale (usato per recuperare il contesto).
    /// @param response I dati restituiti dal codice JS (codificati in bytes).
    /// @param err Eventuali errori restituiti dalla rete DON (se vuoto, tutto ok).
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        // Recupera il contesto salvato in precedenza
        PendingRequest memory req = _pendingRequests[requestId];
        uint256 tokenId = req.tokenId;

        // Gestione errori e pulizia
        if (req.tokenId == 0) return; // Richiesta non trovata o ID non valido
        if (err.length > 0) {
            delete _pendingRequests[requestId]; // Pulisce la memoria anche in caso di errore
            return;
        }

        // LOGICA DI AGGIORNAMENTO STATO
        if (req.reqType == RequestType.CHECK_PUBLICATION) {
            // Caso 1: Verifica Pubblicazione (Il JS deve ritornare 1 se trovato)
            uint256 isPublished = abi.decode(response, (uint256));
            if (isPublished == 1) {
                Song storage song = _songs[tokenId];
                song.currentState = LifecycleState.Publish;
                song.publishedAt = uint64(block.timestamp);
                song.lastStateChange = uint64(block.timestamp);
                emit StateChanged(tokenId, LifecycleState.Register, LifecycleState.Publish, song.lastStateChange);
            }
            
        } else if (req.reqType == RequestType.UPDATE_STREAMS) {
            // Caso 2: Aggiornamento Stream (Il JS deve ritornare il numero di stream)
            uint256 fetchedStreams = abi.decode(response, (uint256));
            Song storage song = _songs[tokenId];

            // Aggiorniamo solo se il nuovo valore è maggiore del precedente (protezione anti-rollback)
            if (fetchedStreams > song.streamCount) {
                song.streamCount = uint128(fetchedStreams);
                emit StreamCountUpdated(tokenId, uint128(fetchedStreams));
                
                // --- LOGICA CRITICA: Sblocco Revenue ---
                // Se siamo in fase 'Publish' E superiamo la soglia (1000 stream), sblocca i pagamenti.
                if (song.currentState == LifecycleState.Publish && fetchedStreams >= STREAM_THRESHOLD) {
                    song.currentState = LifecycleState.Revenue;
                    song.lastStateChange = uint64(block.timestamp);
                    emit StateChanged(tokenId, LifecycleState.Publish, LifecycleState.Revenue, song.lastStateChange);
                    emit MonetizationUnlocked(tokenId, uint128(fetchedStreams));
                }
            }
        }
        
        // Pulizia finale della memoria temporanea
        delete _pendingRequests[requestId];
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
        // Controllo esistenza token (versione corretta per OpenZeppelin v5)
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

   // --- GESTIONE ECONOMICA (Con Blocchi Soglia) ---

    /// @notice Permette di depositare ricavi (ETH) per una specifica canzone.
    /// @dev Funzione "Payable". Accetta ETH solo se la canzone ha superato la soglia di stream (Stato: Revenue).
    ///      I fondi vengono accumulati nel mapping `_tokenBalances` in attesa di distribuzione.
    ///      Se lo stato non è `Revenue`, la transazione viene rifiutata (Revert) per proteggere i pagatori.
    /// @param tokenId L'ID della canzone che ha generato il guadagno.
    function depositRevenue(uint256 tokenId) public payable {
        _requireOwned(tokenId);
        require(msg.value > 0, "Spyral: No value sent");
        
        // IL BLOCCO SOGLIA: Il cuore della tokenomics condizionale
        // Se provi a pagare una canzone con <1000 stream, i soldi tornano indietro.
        require(_songs[tokenId].currentState == LifecycleState.Revenue, "Spyral: Song threshold not reached yet");
        
        // Aggiorna lo storico totale (non diminuisce mai)
        _songs[tokenId].totalRevenue += uint128(msg.value);
        // Aggiorna il bilancio prelevabile attuale (diminuisce quando si distribuisce)
        _tokenBalances[tokenId] += msg.value;
        
        emit RevenueReceived(tokenId, msg.value);
    }

    /// @notice Distribuisce i fondi accumulati a tutti i collaboratori in base alle loro percentuali.
    /// @dev Implementa il pattern "Check-Effects-Interactions" per prevenire attacchi di Reentrancy.
    ///      È `payable` per permettere di depositare e distribuire in un'unica transazione (Gas Saving).
    /// @param tokenId L'ID della canzone di cui distribuire i proventi.
    function distributeRoyalties(uint256 tokenId) public payable {
        // Controllo di sicurezza ridondante: Distribuzione vietata se non siamo in Revenue
        require(_songs[tokenId].currentState == LifecycleState.Revenue, "Spyral: Not in Revenue phase");
        _requireOwned(tokenId);

        // Feature "Ibrida": Se invii ETH chiamando questa funzione, li aggiunge al totale prima di dividere.
        // Utile per piattaforme esterne che vogliono pagare e chiudere i conti in un colpo solo.
        if (msg.value > 0) {
            _songs[tokenId].totalRevenue += uint128(msg.value);
            _tokenBalances[tokenId] += msg.value;
            emit RevenueReceived(tokenId, msg.value);
        }

        // Snapshot del bilancio attuale
        uint256 amountToDistribute = _tokenBalances[tokenId];
        require(amountToDistribute > 0, "Spyral: No funds to distribute");

        // CHECK-EFFECTS-INTERACTIONS: Azzeramento PRIMA del loop di pagamento
        _tokenBalances[tokenId] = 0; 

        Collaborator[] memory collaborators = _collaborators[tokenId];
        
        // Loop di pagamento
        for (uint i = 0; i < collaborators.length; i++) {
            // Calcolo quota: (Totale * Percentuale) / 100
            uint256 amount = (amountToDistribute * collaborators[i].splitPercentage) / 100;
            
            if (amount > 0) {
                // Invio fondi usando .call (metodo più sicuro contro smart contract wallet)
                (bool success, ) = collaborators[i].wallet.call{value: amount}("");
                require(success, "Spyral: Transfer failed");
            }
        }
        emit RoyaltiesDistributed(tokenId, amountToDistribute);
    }

}