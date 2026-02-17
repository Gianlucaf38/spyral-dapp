const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SongAsset Oracle Mock Test", function () {

  let contract;
  let owner;
  let user;

  beforeEach(async function () {
    [owner, user] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("SongAssetMock");

   const Router = await ethers.getContractFactory("MockRouter");
const router = await Router.deploy();
await router.waitForDeployment();

contract = await Factory.deploy(
  owner.address,
  router.target
);


    await contract.waitForDeployment();
  });

  it("Mint → Request → Oracle callback", async function () {

    // 1 mint
    await contract.mintSong(user.address, ethers.keccak256(ethers.toUtf8Bytes("audio")));

    // 2 advance → Collaborate
    await contract.connect(user).advanceState(1);

    // 3 advance → Register
    await contract.connect(user).advanceState(1);

    // 4 spotify id
    await contract.setSpotifyId(1, "TEST");

    // 5 request oracle
    const tx = await contract.requestOracleCheck(
      1,
      0,
      "return Functions.encodeUint256(1);"
    );

    const receipt = await tx.wait();

    const event = receipt.logs.find(log =>
      log.fragment?.name === "OracleRequestSent"
    );

    const requestId = event.args.requestId;

    // 6 simulate oracle response = published
    const encoded = ethers.AbiCoder.defaultAbiCoder()
      .encode(["uint256"], [1]);

    await contract.mockFulfill(requestId, encoded);

    // 7 check state
    const data = await contract.getSongData(1);

    expect(data.currentState).to.equal(3); // Publish enum index
  });

  it("Stream milestone triggers revenue", async function () {

  await contract.mintSong(user.address, ethers.keccak256(ethers.toUtf8Bytes("audio")));

  await contract.connect(user).advanceState(1);
  await contract.connect(user).advanceState(1);
  await contract.setSpotifyId(1, "TEST");

  const tx = await contract.requestOracleCheck(
    1,
    0,
    "return Functions.encodeUint256(1);"
  );

  const receipt = await tx.wait();
  const event = receipt.logs.find(log => log.fragment?.name === "OracleRequestSent");
  const requestId = event.args.requestId;

  // publish first
  const publishEncoded = ethers.AbiCoder.defaultAbiCoder()
    .encode(["uint256"], [1]);

  await contract.mockFulfill(requestId, publishEncoded);

  // request stream update
  const tx2 = await contract.requestOracleCheck(
    1,
    1,
    "return Functions.encodeUint256(2000);"
  );

  const receipt2 = await tx2.wait();
  const event2 = receipt2.logs.find(log => log.fragment?.name === "OracleRequestSent");
  const requestId2 = event2.args.requestId;

  const streamEncoded = ethers.AbiCoder.defaultAbiCoder()
    .encode(["uint256"], [2000]);

  await contract.mockFulfill(requestId2, streamEncoded);

  const data = await contract.getSongData(1);

  expect(data.currentState).to.equal(4); // Revenue
});


});

