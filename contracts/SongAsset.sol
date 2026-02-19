// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Importiamo SOLO l'ultimo anello della catena. Si porta dietro tutto il resto!
import "./SongRoyaltiesModule.sol";

/// @title Spyral Song Asset - Contratto finale modulare
/// @author @gianlucaaf @gnico02
/// @notice Contratto principale: unisce ERC721, lifecycle, chainlink functions e royalties.
contract SongAsset is SongRoyaltiesModule {

    /// @dev Inizializza il contratto impostando il nome, il simbolo e l'owner iniziale.
    /// @param initialOwner Indirizzo che avrà i poteri di amministrazione (minter).
    /// @param router Indirizzo a cui inviare le richieste per Chainlink Oracle.
    constructor(address initialOwner, address router) 
        ERC721("Spyral Song Asset", "SPYRAL") 
        Ownable(initialOwner)
        FunctionsClient(router) 
    {}
    
}
