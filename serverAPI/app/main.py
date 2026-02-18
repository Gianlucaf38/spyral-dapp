from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from web3 import Web3
from .abi import CONTRACT_ABI
import os

app = FastAPI(
    docs_url=None,
    redoc_url=None
)

# Configurazione Web3 - Assicurati di impostare queste variabili su Railway
RPC_URL = os.getenv("RPC_URL", "https://sepolia.base.org")
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS") # L'indirizzo del contratto deployato
IPFS_BASE_CID = "ipfs://bafybeice35pax2yc3pcwjdh445g7eol7lag4z4aalpgquv6bpdjdz6m7ja"
# Inizializzazione Web3
w3 = Web3(Web3.HTTPProvider(RPC_URL))



# Mapping degli stati e delle immagini IPFS corrispondenti 
LIFECYCLE_MAP = {
    0: {"name": "Upload", "file": "upload.jpg"},
    1: {"name": "Collaborate", "file": "collaborate.jpg"},
    2: {"name": "Register", "file": "register.jpg"},
    3: {"name": "Publish", "file": "publish.jpg"},
    4: {"name": "Revenue", "file": "revenue.jpg"}
}

contract = w3.eth.contract(
    address=Web3.to_checksum_address(CONTRACT_ADDRESS),
    abi=CONTRACT_ABI
)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)

@app.middleware("http")
async def allow_only_get(request: Request, call_next):
    if request.method != "GET":
        return JSONResponse(status_code=405, content={"error": "Method not allowed"})
    return await call_next(request)

@app.get("/")
async def root():
    return {"status": "ok", "network": "Base Sepolia"}

@app.get("/metadata/{token_id}")
async def get_nft_metadata(token_id: int):
    try:
        song_data = contract.functions.getSongData(token_id).call()
        collaborators = contract.functions.getCollaborators(token_id).call()

        # unpack corretto
        state_index = song_data[0]
        published_at = song_data[1]
        streams = song_data[2]
        revenue = song_data[3]
        audio_hash = song_data[4]
        spotify_id = song_data[5]

        state_info = LIFECYCLE_MAP.get(state_index, LIFECYCLE_MAP[0])

        return {
            "name": f"Spyral Song #{token_id}",
            "description": f"This song is in the {state_info['name']} phase with {streams:,} streams.",
            "image": f"{IPFS_BASE_CID}/{state_info['file']}",
            "external_url": f"https://spyral.com/song/{token_id}",
            "attributes": [
                {"trait_type": "Lifecycle State", "value": state_info["name"]},
                {"trait_type": "Stream Count", "display_type": "number", "value": streams},
                {"trait_type": "Revenue Generated", "value": float(w3.from_wei(revenue, 'ether'))},
                {"trait_type": "Published Date", "display_type": "date", "value": published_at},
                {"trait_type": "Spotify ID", "value": spotify_id},
                {"trait_type": "Audio Hash", "value": Web3.to_hex(audio_hash)},
                {"trait_type": "Collaborators", "value": len(collaborators)}
            ]
        }

    except Exception as e:
        raise HTTPException(
            status_code=404,
            detail=f"Token {token_id} not found or error: {str(e)}"
        )
