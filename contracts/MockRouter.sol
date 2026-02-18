// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockRouter {

    bytes32 public lastRequestId;

    fallback() external {
        lastRequestId = keccak256(
            abi.encode(block.timestamp, msg.sender)
        );

        assembly {
            mstore(0, sload(lastRequestId.slot))
            return(0, 32)
        }
    }
}
