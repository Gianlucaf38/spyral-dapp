// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SongOracleModule.sol";

/// @notice Modulo: gestione economica (deposito revenue + distribuzione royalties).
/// @dev Lo storage sta in SongStorage. Il contratto finale deve assicurare che tokenId esista (es. _requireOwned(tokenId)).
abstract contract SongRoyaltiesModule is SongOracleModule {
   // --- GESTIONE ECONOMICA (Con Blocchi Soglia) ---

    /// @notice Permette di depositare ricavi (ETH) per una specifica canzone.
    /// @dev Funzione "Payable". Accetta ETH solo se la canzone ha superato la soglia di stream (Stato: Revenue).
    ///      I fondi vengono accumulati nel mapping `_tokenBalances` in attesa di distribuzione.
    ///      Se lo stato non è `Revenue`, la transazione viene rifiutata (Revert) per proteggere i pagatori.
    /// @param tokenId L'ID della canzone che ha generato il guadagno.
    function depositRevenue(uint256 tokenId) public payable {
        require(msg.value > 0, "Spyral: No value sent");
        require(_songs[tokenId].currentState == LifecycleState.Revenue, "Spyral: Song threshold not reached yet");
        
        // Aggiorna lo storico totale (non diminuisce mai)
        _songs[tokenId].totalRevenue += uint128(msg.value);
        // Aggiorna il bilancio prelevabile attuale (diminuisce quando si distribuisce)
        _tokenBalances[tokenId] += msg.value;
        
        emit RevenueReceived(tokenId, msg.sender,msg.value);
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
            emit RevenueReceived(tokenId, msg.sender,msg.value);
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
