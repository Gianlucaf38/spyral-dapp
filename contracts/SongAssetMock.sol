// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SongAsset.sol";

contract SongAssetMock is SongAsset {

    constructor(address owner, address router)
        SongAsset(owner, router)
    {}

    function mockFulfill(
        bytes32 requestId,
        bytes memory response
    ) external {
        fulfillRequest(requestId, response, "");
    }
}
