# abi.py

CONTRACT_ABI = [
    {
        "inputs": [{"internalType": "uint256", "name": "tokenId", "type": "uint256"}],
        "name": "getSongData",
        "outputs": [
            {"internalType": "uint8", "name": "currentState", "type": "uint8"},
            {"internalType": "uint64", "name": "publishedAt", "type": "uint64"},
            {"internalType": "uint128", "name": "streamCount", "type": "uint128"},
            {"internalType": "uint128", "name": "totalRevenue", "type": "uint128"},
            {"internalType": "bytes32", "name": "audioHash", "type": "bytes32"},
            {"internalType": "string", "name": "spotifyId", "type": "string"}
        ],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [{"internalType": "uint256", "name": "tokenId", "type": "uint256"}],
        "name": "getCollaborators",
        "outputs": [
            {
                "components": [
                    {"internalType": "address", "name": "wallet", "type": "address"},
                    {"internalType": "uint8", "name": "splitPercentage", "type": "uint8"}
                ],
                "internalType": "struct SongAsset.Collaborator[]",
                "name": "",
                "type": "tuple[]"
            }
        ],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [{"internalType": "uint256", "name": "tokenId", "type": "uint256"}],
        "name": "ownerOf",
        "outputs": [{"internalType": "address", "name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "name",
        "outputs": [{"internalType": "string", "name": "", "type": "string"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "symbol",
        "outputs": [{"internalType": "string", "name": "", "type": "string"}],
        "stateMutability": "view",
        "type": "function"
    }
]
