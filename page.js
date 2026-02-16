'use client';

import { ConnectButton } from '@rainbow-me/rainbowkit';
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
  useReadContract
} from 'wagmi';
import { useState, useEffect, useMemo } from 'react';
import songAssetABI from '../abi/SongAsset.json';

const CONTRACT_ADDRESS = "0x77e2cde08930Db56c795E8983bCc09Ab90f1703a";

/* ---------------- IPFS HELPER ---------------- */
function toGateway(uri) {
  if (!uri) return "";
  if (uri.startsWith("http")) return uri;
  return uri.replace("ipfs://", "https://ipfs.io/ipfs/");
}

export default function Home() {

  /* ---------- FIX HYDRATION ---------- */
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const { address, isConnected } = useAccount();

  /* ---------- INPUT STATES ---------- */
  const [audioHashInput, setAudioHashInput] = useState("");
  const [recipientAddress, setRecipientAddress] = useState("");
  const [tokenId, setTokenId] = useState("0");
  const [collabWallet, setCollabWallet] = useState("");
  const [collabPercent, setCollabPercent] = useState("");

  /* ---------- METADATA STATES ---------- */
  const [image, setImage] = useState("");
  const [name, setName] = useState("");
  const [loadingMeta, setLoadingMeta] = useState(false);

  /* ---------- SAFE TOKEN ID ---------- */
  const safeTokenId =
    tokenId && !isNaN(tokenId)
      ? BigInt(tokenId)
      : undefined;

  /* ---------- READ CONTRACT OWNER ---------- */
  const { data: contractOwner } = useReadContract({
    address: CONTRACT_ADDRESS,
    abi: songAssetABI.abi,
    functionName: "owner",
    watch: true
  });

  /* ---------- READ TOKEN OWNER ---------- */
  const { data: tokenOwner } = useReadContract({
    address: CONTRACT_ADDRESS,
    abi: songAssetABI.abi,
    functionName: "ownerOf",
    args: safeTokenId !== undefined ? [safeTokenId] : undefined,
    query: { enabled: safeTokenId !== undefined },
    watch: true
  });

  /* ---------- READ TOKEN URI ---------- */
  const {
    data: tokenUri,
    refetch: refetchUri
  } = useReadContract({
    address: CONTRACT_ADDRESS,
    abi: songAssetABI.abi,
    functionName: "tokenURI",
    args: safeTokenId !== undefined ? [safeTokenId] : undefined,
    query: { enabled: safeTokenId !== undefined },
    watch: true
  });

  /* ---------- ROLE LOGIC ---------- */
  const isAdmin = useMemo(() => {
    if (!address || !contractOwner) return false;
    return contractOwner.toLowerCase() === address.toLowerCase();
  }, [address, contractOwner]);

  const isTokenOwner = useMemo(() => {
    if (!address || !tokenOwner) return false;
    return tokenOwner.toLowerCase() === address.toLowerCase();
  }, [address, tokenOwner]);

  /* ---------- DEFAULT RECIPIENT ---------- */
  useEffect(() => {
    if (isConnected && address && !recipientAddress) {
      setRecipientAddress(address);
    }
  }, [isConnected, address]);

  /* ---------- FETCH METADATA ---------- */
  useEffect(() => {
    async function load() {
      if (!tokenUri) return;

      setLoadingMeta(true);

      try {
        const res = await fetch(toGateway(tokenUri));
        const json = await res.json();

        if (json.image) setImage(toGateway(json.image));
        if (json.name) setName(json.name);
      } catch (err) {
        setImage("https://placehold.co/400x400?text=Metadata+Error");
      } finally {
        setLoadingMeta(false);
      }
    }
    load();
  }, [tokenUri]);

  /* ---------- STATE DETECTION FROM URI ---------- */
  const phase = useMemo(() => {
    if (!tokenUri) return "none";
    if (tokenUri.includes("upload")) return "Upload";
    if (tokenUri.includes("collaborate")) return "Collaborate";
    if (tokenUri.includes("register")) return "Register";
    if (tokenUri.includes("publish")) return "Publish";
    if (tokenUri.includes("revenue")) return "Revenue";
    return "Unknown";
  }, [tokenUri]);

  const isCollaborate = phase === "Collaborate";

  /* ---------- WRITE CONTRACT ---------- */
  const { data: hash, writeContract, isPending, error } =
    useWriteContract();

  const { isSuccess } = useWaitForTransactionReceipt({ hash });

  /* refresh automatico dopo tx */
  useEffect(() => {
    if (isSuccess) {
      refetchUri();
    }
  }, [isSuccess]);

  /* ---------- ACTIONS ---------- */

  function mint() {
    if (!audioHashInput) return alert("Hash mancante");
    writeContract({
      address: CONTRACT_ADDRESS,
      abi: songAssetABI.abi,
      functionName: "mintSong",
      args: [recipientAddress, audioHashInput]
    });
  }

  function advance() {
    if (safeTokenId === undefined) return;
    writeContract({
      address: CONTRACT_ADDRESS,
      abi: songAssetABI.abi,
      functionName: "advanceState",
      args: [safeTokenId]
    });
  }

  function addCollab() {
    if (!collabWallet || !collabPercent) return;
    writeContract({
      address: CONTRACT_ADDRESS,
      abi: songAssetABI.abi,
      functionName: "addCollaborator",
      args: [safeTokenId, collabWallet, Number(collabPercent)]
    });
  }

  if (!mounted) return null;

  /* ---------- UI ---------- */

  const input = "bg-gray-800 p-3 rounded border border-gray-600 w-full";
  const btn = "bg-purple-600 hover:bg-purple-700 p-3 rounded w-full font-bold disabled:opacity-40";

  return (
    <main className="min-h-screen flex flex-col items-center p-10 gap-8 bg-black text-white">

      <h1 className="text-4xl font-bold">
        Spyral {isAdmin ? "(Admin)" : "(User)"}
      </h1>

      <ConnectButton />

      {!isConnected && (
        <p className="text-gray-400">Connetti wallet</p>
      )}

      {isConnected && (
        <div className="grid md:grid-cols-2 gap-8 w-full max-w-5xl">

          {/* MINT */}
          <div className="bg-gray-900 border border-gray-700 p-6 rounded-xl flex flex-col gap-3">

            <h2 className="font-bold text-xl text-purple-400">
              Mint
            </h2>

            {isAdmin ? (
              <>
                <input
                  className={input}
                  placeholder="Audio Hash"
                  value={audioHashInput}
                  onChange={e => setAudioHashInput(e.target.value)}
                />

                <input
                  className={input}
                  placeholder="Recipient"
                  value={recipientAddress}
                  onChange={e => setRecipientAddress(e.target.value)}
                />

                <button
                  onClick={mint}
                  disabled={isPending}
                  className={btn}
                >
                  Mint NFT
                </button>
              </>
            ) : (
              <p className="text-gray-500 text-sm">
                Solo admin può mintare
              </p>
            )}
          </div>

          {/* PANEL */}
          <div className="bg-gray-900 border border-gray-700 p-6 rounded-xl flex flex-col gap-4">

            <h2 className="font-bold text-xl text-blue-400">
              Gestione
            </h2>

            <input
              type="number"
              className={input}
              value={tokenId}
              onChange={e => setTokenId(e.target.value)}
            />

            <p className="text-sm">
              Stato: <b>{phase}</b>
            </p>

            {/* IMAGE */}
            <div className="aspect-square bg-black border border-gray-700 rounded flex items-center justify-center overflow-hidden">
              {loadingMeta
                ? "Loading IPFS..."
                : image && <img src={image} className="object-cover w-full h-full" />}
            </div>

            {isTokenOwner && (
              <>
                <button onClick={advance} className={btn}>
                  Avanza Stato
                </button>

                {isCollaborate && (
                  <>
                    <input
                      className={input}
                      placeholder="Wallet"
                      value={collabWallet}
                      onChange={e => setCollabWallet(e.target.value)}
                    />

                    <input
                      className={input}
                      placeholder="%"
                      value={collabPercent}
                      onChange={e => setCollabPercent(e.target.value)}
                    />

                    <button onClick={addCollab} className={btn}>
                      Add Collaborator
                    </button>
                  </>
                )}
              </>
            )}

          </div>
        </div>
      )}

      {/* TX STATUS */}
      {hash && (
        <p className="text-green-400 text-xs break-all">
          TX: {hash}
        </p>
      )}

      {error && (
        <p className="text-red-400 text-xs">
          {error.shortMessage || error.message}
        </p>
      )}

    </main>
  );
}
