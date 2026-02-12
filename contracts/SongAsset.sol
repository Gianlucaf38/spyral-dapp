// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

//contratto ereditato da ERC721 di OpenZeppelin, che fornisce tutte le funzionalità standard per un token non fungibile (NFT), e da Ownable, che consente di gestire i permessi di accesso al contratto.
contract SongAsset is ERC721, Ownable {

    using Strings for uint256;//permette di utilizzare metodi Strings(di OpenZeppelin) su uint256
    //dice al contratto di "attaccare" tutte le funzioni della libreria Strings 
    //di OpenZeppelin al tipo di dato uint256. Questo permette di usare la sintassi tuoNumero.toString() per 
    //trasformare un ID numerico in testo.

    // 1. Lifecycle State Machine
    enum LifecycleState { Upload, Collaborate, Register, Publish, Revenue }

    //Per quanto riguarda la struct Song ci si è basati su delle scelte architetturali volte a ridurre il consumo di gas
    //cercando di evitare ridondanza di informazioni

    struct Song {
        //uint256 tokenId; RIMOZIONE 1: io accedo all'oggetto Song tramite il mapping(uint256 => Song) private _songs, per cui non
        //ha senso salvare nel valore di un "dizionario" la chiave del valore stesso
        LifecycleState currentState;
        //address owner; RIMOZIONE 2: L'owner è già gestito di default dalla libreria OpenZeppelin che possiede un mapping del tipo 
        //mapping(uint256 => address) private _owners, è tutto già gestito dalla funzione ownerOf(tokenId). Inoltre questo attributo 
        //aggiunge un grado di pericolosità in quanto se nella logica del programma si omette il trasferimento di questa proprietà potrebbe
        //esserci incoerenza tra i possessori di OpenZeppelin e quelli specificati da noi, arriviamo ad avere una "Single Source of Truth"
        // Altri dati...Procediamo con l'aggiunta efficiente di attributi
        uint64 lastStateChange; // Timestamp ultimo cambio stato, lo possiamo utilizzare per gestire temporalmente i cambi di stato
        uint128 totalRevenue; // Contatore revenue (basta per cifre enormi), serve a calcolare i guadagni della canzone per poterli ripartire tra i collaboratori
        bytes32 audioHash; // Checksum del file audio (SHA-256 o Keccak), questo è relativo all'integrità del file originale, permette di
        //certificare che il file a cui associamo l'NFT rimane sempre lo stesso e non hanno potuto ingannarci con un file fittizio o comunque danneggiato 

        //Ethereum salva per slot di 32 byte a cui accede direttamente con una sola gas fee, quindi in questo modo riusciamo ad acceder a due soli slot
    }
    mapping(uint256 => Song) private _songs;
    uint256 private _nextTokenId;

    //costruttore del contratto, che inizializza il nome e il simbolo del token NFT. 
    //In questo caso, il nome è "Spyral Song Asset" e il simbolo è "SPYRAL". Questi valori vengono passati al costruttore di ERC721 per configurare il token.
    // MODIFICA 1: Ownable ora vuole l'indirizzo iniziale tra parentesi
    constructor(address initialOwner) 
        ERC721("Spyral Song Asset", "SPYRAL") 
        Ownable(initialOwner)
        {}


    //questa funzione si occupa di mintare un nuovo token per una canzone, assegnandolo a un proprietario specificato. 
    //Viene utilizzata solo dal proprietario del contratto (ad esempio, l'amministratore) per creare nuovi asset musicali. 
    //Ogni volta che viene chiamata, genera un nuovo ID univoco per la canzone, la memorizza nella mappatura _songs e restituisce l'ID del token appena creato.

    /*
    SCELTA DEL TOKEN ID:
    1. Optare per un token id randomico in questo contesto potrebbe sembrare una scelta ottimale per una questione di privacy, tuttavia avremmo seri problemi
    sia dal punto di vista dei costi in gas per la funzione di hashing, sia per accedere a questi token, in quanto ad esempio non potremmo fare accessi sequenzial
    2. Analizzando l'approccio industriale di alcuni grandi aziende nel mondo degli NFT abbiamo riscontrato spesso un utilizzo di token sequenziali, per cui la nostra scelta
    è ricaduta su di essi. Inoltre con Solidity 0.8+ (che gestisce l'overflow matematico nativamente), usare una libreria esterna solo per fare +1 è uno spreco 
    di gas e complessità inutile.
    */ 
 
    function mintSong(address to, bytes32 _audioHash) public onlyOwner returns (uint256) {
        uint256 newItemId = _nextTokenId;
        unchecked { _nextTokenId++; } //Dalla versione 0.8 di Solidity, il compilatore controlla sempre se i numeri "sforano" (overflow). Questo controllo costa un po' di gas. 
        //Usare unchecked su un contatore uint256 che incrementa di 1 alla volta non è un problema perchè è computazionalmente impossibile
        //mandarlo in overflow prima che il sole esploda (tra circa 5 miliardi di anni)

        _safeMint(to, newItemId); //per il minting possiamo usare la funzione sicura dello standard ERC721

        _songs[newItemId] = Song({
            currentState: LifecycleState.Upload, //Stato iniziale
            lastStateChange: uint64(block.timestamp), //prendo il timestamp dal blocco in cui è stata validata la transazione relativa alla generazione del token
            totalRevenue: 0, //Si parte da zero guadagni
            audioHash: _audioHash //L'hash è computazionalmente troppo costoso da fare on chain con file di GB, per questo motivo lo calcoliamo nel frontend che andrò poi
            //a richiamare la funzione di minting passando direttamente l'hash già calcolato
        });

        return newItemId;
    }

    struct Collaborator {
        address payable wallet;
        uint8 splitPercentage; // Percentuale di royalty (es. 25 per 25%)
    }

    mapping(uint256 => Collaborator[]) private _collaborators;

    //Il contratto tiene traccia di chi ha lavorato alla canzone e in che misura. I collaboratori possono essere aggiunti solo dal proprietario del token, e ogni collaboratore ha una percentuale di royalty associata.
    //Sono immutabili
    function addCollaborator(uint256 tokenId, address payable wallet, uint8 splitPercentage) public {

        // MODIFICA 2: _isApprovedOrOwner non esiste più.
        // Si usa _checkAuthorized. E NON va dentro il 'require' (fa revert da solo).
        address owner = ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);

        // Aggiungi logica per controllare che la somma delle percentuali non superi 100
        _collaborators[tokenId].push(Collaborator(wallet, splitPercentage));
    }

    //utilizziamo funzione per definire il tempo di attesa tra i cambi di stato
    // NOTA questa funzione è puramente esemplificativa, in un contesto reale si potrebbe voler gestire in modo più dinamico o complesso i tempi di attesa, 
    //magari con parametri configurabili o basati su eventi specifici.
    // inoltre si potrebbe voler aggiungere un meccanismo di "emergenza" per bypassare i tempi di attesa in caso di necessità,
    // oppure per modificare i tempi di attesa in base a determinate condizioni (ad esempio, se la canzone ha raggiunto un certo numero di collaboratori o di visualizzazioni).
    function getCooldownForState(LifecycleState state) public pure returns (uint64) {
        if (state == LifecycleState.Upload) return 0;           // Immediato
        if (state == LifecycleState.Collaborate) return 1 days; // 24 ore
        if (state == LifecycleState.Register) return 7 days;    // 1 settimana
        if (state == LifecycleState.Publish) return 2 days;     // 48 ore
        return 0;
    }

    event StateChanged(uint256 indexed tokenId, LifecycleState oldState, LifecycleState newState, uint64 timestamp);
    //il contratto consente al proprietario di un token di avanzare lo stato della canzone attraverso le fasi del ciclo di vita (Upload, Collaborate, Register, Publish, Revenue).
    function advanceState(uint256 tokenId) public {

        // MODIFICA 3: Stessa cosa qui. Sostituito _isApprovedOrOwner con la logica v5

        //1. controllo che il token esista e che chi chiama la funzione sia autorizzato (proprietario o approvato)
        address owner = ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        Song storage song = _songs[tokenId];

        //2. controllo che sia passato abbastanza tempo dall'ultimo cambio di stato per evitare abusi
        LifecycleState currentState = song.currentState;
        uint64 requiredWait = getCooldownForState(currentState);


        require(
            block.timestamp >= song.lastStateChange + requiredWait,
            "Errore: Non è ancora trascorso il tempo necessario per questo stato"
        );

        //3. Logica di transizione

        if (song.currentState == LifecycleState.Upload) {
        song.currentState = LifecycleState.Collaborate;
        } else if (song.currentState == LifecycleState.Collaborate) {
        song.currentState = LifecycleState.Register;
        } else if (song.currentState == LifecycleState.Register) {
        song.currentState = LifecycleState.Publish;
        } else if (song.currentState == LifecycleState.Publish) {
        song.currentState = LifecycleState.Revenue;
        }else {
            // Se è già in Revenue, fermiamo tutto e restituiamo il gas residuo
            revert("Canzone gia nello stato finale");
        }

        // 4. Aggiorniamo il timestamp per il prossimo scatto
        song.lastStateChange = uint64(block.timestamp);

        emit StateChanged(tokenId, currentState, song.currentState, song.lastStateChange);
    }
    //NFT cambia aspetto in base a dove si trova nel ciclo di vita. 
    //Il metodo tokenURI restituisce un URI diverso a seconda dello stato attuale della canzone, permettendo di visualizzare metadati e immagini differenti per ogni fase del ciclo di vita.
    function tokenURI(uint256 tokenId) public view override returns (string
    memory) {
        // MODIFICA 4: _exists non esiste più. Si usa _requireOwned per controllare se esiste.
        _requireOwned(tokenId);

        LifecycleState state = _songs[tokenId].currentState;
        string memory baseURI = "ipfs://<YOUR_METADATA_FOLDER_CID>/"; 
        // Sostituisci con il tuo CID
        // Restituisce un file JSON diverso per ogni stato
    // Ho usato string.concat che è più moderno, ma bytes.concat va bene uguale
        if (state == LifecycleState.Upload) {
            return string(abi.encodePacked(baseURI, "upload.json"));
        } else if (state == LifecycleState.Collaborate) {
            return string(abi.encodePacked(baseURI, "collaborate.json"));
        }
        
        return string(abi.encodePacked(baseURI, "default.json"));
    }
}