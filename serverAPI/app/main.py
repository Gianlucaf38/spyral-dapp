from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, HTMLResponse
from fastapi.templating import Jinja2Templates
from datetime import datetime
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

        # Unpack dei dati dal contratto
        state_index = song_data[0]
        published_at = song_data[1]
        streams = song_data[2]
        revenue = song_data[3]
        audio_hash = song_data[4]
        spotify_id = song_data[5]

        state_info = LIFECYCLE_MAP.get(state_index, LIFECYCLE_MAP[0])
        
        # 1. Costruzione base dei metadati
        metadata = {
            "name": f"Spyral Song #{token_id}",
            "description": f"This song is currently in the {state_info['name']} phase.",
            "image": f"{IPFS_BASE_CID}/{state_info['file']}",
            "external_url": f"https://spyral.com/song/{token_id}",
            "attributes": [
                {"trait_type": "Lifecycle State", "value": state_info["name"]}
            ]
        }

        # 2. Aggiunta dinamica degli attributi in base allo stato (state_index)
        # Stato 0: Upload (mostriamo solo l'hash audio se presente)
        if state_index >= 0:
            if audio_hash and any(b != 0 for b in audio_hash):
                metadata["attributes"].append({"trait_type": "Audio Hash", "value": Web3.to_hex(audio_hash)})

        # Stato 1: Collaborate
        if state_index >= 1:
            metadata["attributes"].append({"trait_type": "Collaborators", "value": len(collaborators)})

        # Stato 2 e 3: Register & Publish
        if state_index >= 2:
            if spotify_id and spotify_id != "":
                metadata["attributes"].append({"trait_type": "Spotify ID", "value": spotify_id})
            if published_at > 0:
                metadata["attributes"].append({"trait_type": "Published Date", "display_type": "date", "value": published_at})

        # Stato 4: Revenue
        if state_index >= 4:
            metadata["attributes"].append({"trait_type": "Stream Count", "display_type": "number", "value": streams})
            metadata["attributes"].append({"trait_type": "Revenue Generated", "value": float(w3.from_wei(revenue, 'ether'))})

        return metadata

    except Exception as e:
        raise HTTPException(
            status_code=404,
            detail=f"Token {token_id} not found or error: {str(e)}"
        )
    

templates = Jinja2Templates(directory="templates")

@app.get("/view/{token_id}", response_class=HTMLResponse)
async def view_nft_modern(request: Request, token_id: int):
    try:
        # 1. Fetch Dati
        song_data = contract.functions.getSongData(token_id).call()
        state_idx = song_data[0]
        state_info = LIFECYCLE_MAP.get(state_idx, LIFECYCLE_MAP[0])
        
        # 2. Preparazione variabili per il template
        context = {
            "request": request,
            "token_id": token_id,
            "state_name": state_info["name"],
            "image_url": f"https://ipfs.io/ipfs/{IPFS_BASE_CID.replace('ipfs://', '')}/{state_info['file']}",
            "streams": song_data[2],
            "revenue": round(float(w3.from_wei(song_data[3], 'ether')), 4),
            "spotify_id": song_data[5],
            "pub_date": datetime.fromtimestamp(song_data[1]).strftime('%d %b %Y') if song_data[1] > 0 else "Pending",
            "progress": int(((state_idx + 1) / 5) * 100),
            "status_color": ["bg-slate-500", "bg-blue-600", "bg-fuchsia-600", "bg-emerald-500", "bg-amber-500"][state_idx]
        }
        
        # 3. Renderizza il file HTML passandogli il dizionario 'context'
        return templates.TemplateResponse("nft_view.html", context)

    except Exception as e:
        raise HTTPException(status_code=404, detail=str(e))