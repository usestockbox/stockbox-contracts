// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title StockBox gift crates
/// @notice A gift crate holds exactly what its creator put in: no randomness. Crates are sealed
/// ERC-721s. A batch either goes straight to up to 100 wallets, or sits behind one link where
/// each wallet can claim one crate. Contents sit in this contract until a crate is opened.
contract GiftCrates is ERC721Enumerable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Access { Anyone, Verified, List }

    struct Item { address token; uint256 amount; } // amount per crate

    struct GiftParams {
        Item[] items;
        uint32 count;            // crates in this batch
        address[] recipients;    // direct gift: one crate each (length == count). Empty = link.
        Access access;           // link only
        bytes32 listRoot;        // link only, Access.List
        uint40 start;            // link only, 0 = now
        uint40 end;              // link only, 0 = no end
        string title;            // <= 16 bytes
        string note;             // <= 140 bytes
        bytes32 design;          // packed colours / sticker ids, read by the site
    }

    struct Batch {
        address creator;
        bool link;
        Access access;
        uint32 total;
        uint32 minted;
        uint40 start;
        uint40 end;
        bytes32 listRoot;
    }

    uint256 public constant MAX_DIRECT = 100;
    uint256 public constant MAX_LINK = 100_000;
    uint16 public feeBps = 250;
    address public treasury;
    address public router;       // StockRouter: already charged the fee
    address public verifier;     // signs "this wallet is verified" for Access.Verified

    uint256 public nextBatch = 1;
    uint256 public nextId = 1;
    mapping(uint256 => Batch) public batches;
    mapping(uint256 => Item[]) private batchItems;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(uint256 => uint256) public crateBatch;
    mapping(uint256 => bool) public opened;

    uint256 public totalGifted;
    uint256 public totalOpened;

    event GiftCreated(uint256 indexed batchId, address indexed creator, uint32 count, bool link, Access access,
        uint40 start, uint40 end, string title, string note, bytes32 design);
    event Claimed(uint256 indexed batchId, address indexed wallet, uint256 id);
    event GiftOpened(uint256 indexed id, uint256 indexed batchId, address indexed owner);
    event TakenBack(uint256 indexed batchId, uint32 crates);
    event ToppedUp(uint256 indexed batchId, uint32 crates);

    error BadParams();
    error NotCreator();
    error NotOpen();
    error AlreadyClaimed();
    error SoldOut();
    error NotAllowed();
    error NotOwner(uint256 id);
    error AlreadyOpened(uint256 id);

    constructor(address owner_, address treasury_, address verifier_)
        ERC721("StockBox Gift", "SCGIFT") Ownable(owner_)
    {
        treasury = treasury_;
        verifier = verifier_;
    }

    // ================================================================= create

    /// @notice Make a gift batch from tokens you already hold (approve each token first).
    /// Charges the fee on top of the contents.
    function create(GiftParams calldata p) external nonReentrant returns (uint256) {
        return _create(msg.sender, msg.sender, p, true);
    }

    /// @notice Used by StockRouter after it bought the contents with USDG/ETH and took the fee.
    function createFor(address creator, GiftParams calldata p) external nonReentrant returns (uint256) {
        if (msg.sender != router) revert NotAllowed();
        return _create(creator, msg.sender, p, false);
    }

    function _create(address creator, address payer, GiftParams calldata p, bool chargeFee)
        internal
        returns (uint256 batchId)
    {
        bool link = p.recipients.length == 0;
        if (p.items.length == 0 || p.items.length > 20 || p.count == 0) revert BadParams();
        if (link ? p.count > MAX_LINK : (p.count > MAX_DIRECT || p.recipients.length != p.count)) revert BadParams();
        if (bytes(p.title).length > 16 || bytes(p.note).length > 140) revert BadParams();
        if (p.end != 0 && p.end <= p.start) revert BadParams();

        batchId = nextBatch++;
        for (uint256 i; i < p.items.length; ++i) {
            Item calldata it = p.items[i];
            if (it.amount == 0) revert BadParams();
            uint256 total = it.amount * p.count;
            IERC20(it.token).safeTransferFrom(payer, address(this), total);
            if (chargeFee && feeBps > 0) {
                IERC20(it.token).safeTransferFrom(payer, treasury, (total * feeBps) / 10_000);
            }
            batchItems[batchId].push(it);
        }
        batches[batchId] = Batch(creator, link, p.access, p.count, 0, p.start, p.end, p.listRoot);
        totalGifted += p.count;
        emit GiftCreated(batchId, creator, p.count, link, p.access, p.start, p.end, p.title, p.note, p.design);

        if (!link) {
            batches[batchId].minted = p.count;
            for (uint256 i; i < p.count; ++i) _mintCrate(batchId, p.recipients[i]);
        }
    }

    function _mintCrate(uint256 batchId, address to) internal returns (uint256 id) {
        id = nextId++;
        crateBatch[id] = batchId;
        _safeMint(to, id);
    }

    // ================================================================= claim

    /// @notice Claim one crate from a link. `sig` is needed for verified-only links,
    /// `proof` for list links.
    function claim(uint256 batchId, bytes32[] calldata proof, bytes calldata sig)
        external
        nonReentrant
        returns (uint256 id)
    {
        Batch storage b = batches[batchId];
        if (!b.link) revert BadParams();
        if (block.timestamp < b.start || (b.end != 0 && block.timestamp > b.end)) revert NotOpen();
        if (claimed[batchId][msg.sender]) revert AlreadyClaimed();
        if (b.minted >= b.total) revert SoldOut();
        if (b.access == Access.Verified) {
            bytes32 h = MessageHashUtils.toEthSignedMessageHash(
                keccak256(abi.encode(address(this), block.chainid, batchId, msg.sender))
            );
            if (ECDSA.recover(h, sig) != verifier) revert NotAllowed();
        } else if (b.access == Access.List) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
            if (!MerkleProof.verify(proof, b.listRoot, leaf)) revert NotAllowed();
        }
        claimed[batchId][msg.sender] = true;
        b.minted++;
        id = _mintCrate(batchId, msg.sender);
        emit Claimed(batchId, msg.sender, id);
    }

    // ================================================================= open

    /// @notice Open gift crates you hold. Contents go to your wallet.
    function open(uint256[] calldata ids) external nonReentrant {
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            if (ownerOf(id) != msg.sender) revert NotOwner(id);
            if (opened[id]) revert AlreadyOpened(id);
            opened[id] = true;
            Item[] storage its = batchItems[crateBatch[id]];
            for (uint256 i; i < its.length; ++i) IERC20(its[i].token).safeTransfer(msg.sender, its[i].amount);
            totalOpened++;
            emit GiftOpened(id, crateBatch[id], msg.sender);
        }
    }

    /// @dev Opened crates stay where they are; sealed ones can be passed on.
    function _update(address to, uint256 id, address auth)
        internal
        override(ERC721Enumerable)
        returns (address)
    {
        address from = _ownerOf(id);
        if (from != address(0) && to != address(0) && opened[id]) revert AlreadyOpened(id);
        return super._update(to, id, auth);
    }

    // ================================================================= creator tools

    /// @notice Take back every unclaimed crate of a link. The link stops working.
    function takeBack(uint256 batchId) external nonReentrant {
        Batch storage b = batches[batchId];
        if (b.creator != msg.sender) revert NotCreator();
        if (!b.link) revert BadParams();
        uint32 left = b.total - b.minted;
        b.total = b.minted;
        Item[] storage its = batchItems[batchId];
        for (uint256 i; i < its.length; ++i) IERC20(its[i].token).safeTransfer(msg.sender, its[i].amount * left);
        emit TakenBack(batchId, left);
    }

    /// @notice Add more crates behind an existing link, same contents (fee applies).
    function topUp(uint256 batchId, uint32 more) external nonReentrant {
        Batch storage b = batches[batchId];
        if (b.creator != msg.sender) revert NotCreator();
        if (!b.link || more == 0 || b.total + more > MAX_LINK) revert BadParams();
        Item[] storage its = batchItems[batchId];
        for (uint256 i; i < its.length; ++i) {
            uint256 total = its[i].amount * more;
            IERC20(its[i].token).safeTransferFrom(msg.sender, address(this), total);
            if (feeBps > 0) IERC20(its[i].token).safeTransferFrom(msg.sender, treasury, (total * feeBps) / 10_000);
        }
        b.total += more;
        totalGifted += more;
        emit ToppedUp(batchId, more);
    }

    // ================================================================= views

    function items(uint256 batchId) external view returns (Item[] memory) {
        return batchItems[batchId];
    }

    function contentsOf(uint256 id) external view returns (Item[] memory) {
        return batchItems[crateBatch[id]];
    }

    // ================================================================= admin

    function setRouter(address r) external onlyOwner { router = r; }
    function setVerifier(address v) external onlyOwner { verifier = v; }
    function setTreasury(address t) external onlyOwner { treasury = t; }
    function setFeeBps(uint16 b) external onlyOwner { require(b <= 1_000); feeBps = b; }
}
