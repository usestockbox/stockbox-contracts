// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IEntropyConsumer} from "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import {IEntropyV2} from "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";
import {IRandomSource, IRandomConsumer} from "../interfaces/IRandom.sol";

/// @notice Pyth Entropy v2 adapter, an alternative to DrandSource if Pyth Entropy is live on
/// Robinhood Chain. The random number is revealed by Pyth's keeper after the
/// request transaction, so nobody (including us) can know a crate's prize in advance.
contract PythEntropySource is IRandomSource, IEntropyConsumer, Ownable {
    IEntropyV2 public immutable entropy;
    uint32 public constant FORWARD_GAS = 40_000; // our own callback overhead

    mapping(address => bool) public consumers;
    mapping(uint64 => address) public requester;

    event ConsumerSet(address indexed consumer, bool allowed);
    error NotConsumer();
    error FeeTooLow();

    constructor(address entropy_, address owner_) Ownable(owner_) {
        entropy = IEntropyV2(entropy_);
    }

    function setConsumer(address c, bool allowed) external onlyOwner {
        consumers[c] = allowed;
        emit ConsumerSet(c, allowed);
    }

    function fee(uint32 gasLimit) public view returns (uint256) {
        return entropy.getFeeV2(gasLimit + FORWARD_GAS);
    }

    function request(uint32 gasLimit) external payable returns (uint256) {
        if (!consumers[msg.sender]) revert NotConsumer();
        uint256 f = fee(gasLimit);
        if (msg.value < f) revert FeeTooLow();
        uint64 seq = entropy.requestV2{value: f}(gasLimit + FORWARD_GAS);
        requester[seq] = msg.sender;
        return seq;
    }

    function entropyCallback(uint64 sequence, address, bytes32 randomNumber) internal override {
        address c = requester[sequence];
        if (c == address(0)) return;
        delete requester[sequence];
        IRandomConsumer(c).onRandom(sequence, randomNumber);
    }

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    receive() external payable {}
}
