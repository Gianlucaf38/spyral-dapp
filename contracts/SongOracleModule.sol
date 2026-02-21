// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SongLifecycleModule.sol";

// CHAINLINK FUNCTIONS
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/// @notice Modulo: Chainlink Functions (request + fulfill).
abstract contract SongOracleModule is FunctionsClient, SongLifecycleModule{

    using FunctionsRequest for FunctionsRequest.Request;

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
    
    // @dev Configura i parametri Chainlink
    function setChainlinkConfig(uint64 _subscriptionId, bytes32 _donId, uint32 _gasLimit) public onlyOwner {
        subscriptionId = _subscriptionId;
        donId = _donId;
        gasLimit = _gasLimit;
    }
    
    /// @notice Invia una richiesta alla rete Chainlink (DON) per eseguire uno script JavaScript off-chain.
    /// @dev Funzione "Trigger". Crea la richiesta, carica gli argomenti e salva il contesto in `_pendingRequests`.
    ///      Richiede il pagamento in LINK (gestito dalla Subscription).
    /// @param tokenId L'ID del token per cui si richiede la verifica.
    /// @param reqType Il tipo di operazione: 0 per verifica pubblicazione, 1 per aggiornamento stream.
    /// @param source Il codice sorgente JavaScript (come stringa) che i nodi Chainlink eseguiranno.
    /// @return requestId L'ID univoco della richiesta generato dal coordinatore Chainlink.
    function requestOracleCheck(uint256 tokenId, RequestType reqType, string calldata source) public returns (bytes32 requestId) {
        address owner = ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        
        // Validazione specifica per la pubblicazione
        if (reqType == RequestType.CHECK_PUBLICATION) {
            require(_songs[tokenId].currentState == LifecycleState.Register, "Spyral: Not ready to publish");
            require(bytes(_songs[tokenId].spotifyId).length > 0, "Spyral: Spotify ID missing");
        }

        if (reqType == RequestType.UPDATE_STREAMS) {
            require(_songs[tokenId].currentState == LifecycleState.Publish, "Spyral: Song not published");
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

}
