// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

//contratto ereditato da ERC721 di OpenZeppelin, che fornisce tutte le funzionalità standard per un token non fungibile (NFT), e da Ownable, che consente di gestire i permessi di accesso al contratto.
contract SongAsset is ERC721, Ownable {

    using Strings for uint256;//permette di utilizzare metodi Strings(di OpenZeppelin) su uint256

    // 1. Lifecycle State Machine
    enum LifecycleState { Upload, Collaborate, Register, Publish, Revenue }

    struct Song {
        uint256 tokenId;
        LifecycleState currentState;
        address owner;
        // Altri dati...
    }
    mapping(uint256 => Song) private _songs;

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
    uint256 private _nextTokenId = 1; // Iniziamo da 1
    function mintSong(address owner) public onlyOwner returns (uint256) {
        //id con contatore
        uint256 newItemId = _nextTokenId;
        _nextTokenId++; // Incrementiamo per il prossimo
        _safeMint(owner, newItemId);
        _songs[newItemId] = Song({
            tokenId: newItemId,
            currentState: LifecycleState.Upload,
            owner: owner
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


    event StateChanged(uint256 indexed tokenId, LifecycleState newState);
    //il contratto consente al proprietario di un token di avanzare lo stato della canzone attraverso le fasi del ciclo di vita (Upload, Collaborate, Register, Publish, Revenue).
    function advanceState(uint256 tokenId) public {

        // MODIFICA 3: Stessa cosa qui. Sostituito _isApprovedOrOwner con la logica v5
        address owner = ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        Song storage song = _songs[tokenId];
        // Logica di transizione

        if (song.currentState == LifecycleState.Upload) {
        song.currentState = LifecycleState.Collaborate;
        } else if (song.currentState == LifecycleState.Collaborate) {
        song.currentState = LifecycleState.Register;
        } else if (song.currentState == LifecycleState.Register) {
        song.currentState = LifecycleState.Publish;
        } else if (song.currentState == LifecycleState.Publish) {
        song.currentState = LifecycleState.Revenue;
        }

        emit StateChanged(tokenId, song.currentState);
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