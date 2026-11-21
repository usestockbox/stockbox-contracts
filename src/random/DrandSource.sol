// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BLS} from "bls-solidity/libraries/BLS.sol";
import {IRandomSource, IRandomConsumer} from "../interfaces/IRandom.sol";

/// @notice drand "evmnet" (BN254) randomness for StockBox on Robinhood Chain.
/// A request commits to a drand round that is still in the future. Anyone (our keeper, or the
/// user) can then submit that round's signature; the contract checks it against the League of
/// Entropy public key and uses keccak256(signature) as the seed.
///
/// !! Before mainnet: run test/DrandSource.t.sol against real evmnet vectors from
///    https://api.drand.sh/<EVMNET_CHAIN_HASH>/public/<round> and confirm DST and message format.
contract DrandSource is IRandomSource, Ownable {
    // drand evmnet uses BN254 G1 signatures with this hash-to-curve domain.
    bytes public constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    uint256[4] public publicKey;   // G2 public key of the evmnet chain (from /info)
    uint64 public immutable genesis;
    uint64 public immutable period;
    uint64 public constant ROUNDS_AHEAD = 2;
    uint256 public keeperFee;      // wei paid per request to cover the keeper's gas

    struct Req { address consumer; uint64 round; bool done; }
    uint256 public nextRequest = 1;
    mapping(uint256 => Req) public requests;
    mapping(address => bool) public consumers;

    event Requested(uint256 indexed requestId, address indexed consumer, uint64 round);
    event Fulfilled(uint256 indexed requestId, uint64 round, bytes32 seed);
    error NotConsumer();
    error FeeTooLow();
    error TooEarly();
    error BadSignature();
    error Done();

    constructor(address owner_, uint256[4] memory pk, uint64 genesis_, uint64 period_, uint256 keeperFee_)
        Ownable(owner_)
    {
        publicKey = pk;
        genesis = genesis_;
        period = period_;
        keeperFee = keeperFee_;
    }

    function currentRound() public view returns (uint64) {
        if (block.timestamp < genesis) return 0;
        return uint64((block.timestamp - genesis) / period + 1);
    }

    function fee(uint32) external view returns (uint256) {
        return keeperFee;
    }

    function request(uint32) external payable returns (uint256 id) {
        if (!consumers[msg.sender]) revert NotConsumer();
        if (msg.value < keeperFee) revert FeeTooLow();
        id = nextRequest++;
        uint64 round = currentRound() + ROUNDS_AHEAD;
        requests[id] = Req(msg.sender, round, false);
        emit Requested(id, msg.sender, round);
    }

    /// @notice Submit the drand signature (G1 point, uncompressed x,y) for the committed round.
    function fulfill(uint256 id, uint256[2] calldata signature) external {
        Req storage r = requests[id];
        if (r.consumer == address(0) || r.done) revert Done();
        if (currentRound() < r.round) revert TooEarly();
        BLS.PointG1 memory m = BLS.hashToPoint(DST, abi.encodePacked(keccak256(abi.encodePacked(r.round))));
        (bool pairingOk, bool callOk) = BLS.verifySingle(BLS.PointG1(signature[0], signature[1]), BLS.g2Unmarshal(abi.encodePacked(publicKey[0], publicKey[1], publicKey[2], publicKey[3])), m);
        if (!pairingOk || !callOk) revert BadSignature();
        r.done = true;
        bytes32 seed = keccak256(abi.encodePacked(signature[0], signature[1]));
        emit Fulfilled(id, r.round, seed);
        IRandomConsumer(r.consumer).onRandom(id, seed);
        if (keeperFee > 0) {
            (bool ok,) = msg.sender.call{value: keeperFee}("");
            ok; // keeper reward is best effort
        }
    }

    function setConsumer(address c, bool allowed) external onlyOwner { consumers[c] = allowed; }
    function setKeeperFee(uint256 f) external onlyOwner { keeperFee = f; }
}
