// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRandomSource, IRandomConsumer} from "./interfaces/IRandom.sol";
import {PriceLib} from "./lib/PriceLib.sol";

/// @title StockBox mystery crate
/// @notice One contract per tier (normal / premium) on Robinhood Chain. Each crate is a sealed ERC-721.
/// Opening asks the random source for one number per batch; the number decides every crate's
/// prize (from a public odds table) and stock (from the stocks paying right now). Prizes are paid
/// in stock from this contract's own vault. If the vault is short, the payout waits for a refill
/// and anyone can finish it later with `settle`.
contract CrateBox is ERC721Enumerable, Ownable, ReentrancyGuard, IRandomConsumer {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types
    enum Status { None, Sealed, Opening, Opened }

    struct Crate {
        Status status;
        uint40 boughtAt;
        uint64 batch;
        uint32 prizeUsd; // 6 decimals, 0 = not decided yet
        bool pot;        // prize came from the bonus pot
        address stock;
        uint256 amount;  // stock amount owed (decided at roll time)
    }

    struct Batch {
        address owner;
        bytes32 seed;
        bool ready;
        uint32 size;
        uint32 done;     // crates paid
        uint32 rolled;   // crates whose prize is decided
    }

    struct Stock {
        address token;
        address feed;
        uint32 maxAge;   // seconds, 0 = no staleness check
        bool paying;
    }

    // ------------------------------------------------------------------ config
    uint256 public constant MAX_BATCH = 200;
    uint256 public constant EXPIRY = 365 days;
    uint32 public constant BASE_GAS = 120_000;
    uint32 public constant GAS_PER_CRATE = 90_000;
    uint256 public constant INLINE_SETTLE = 20; // crates paid inside the random callback

    IERC20 public immutable stable;          // USDG
    uint8 public immutable stableDecimals;
    address public ethUsdFeed;               // Chainlink ETH/USD
    uint32 public ethFeedMaxAge = 1 hours;
    uint256 public immutable priceUsd;       // 6 decimals: 100_000 = $0.10
    address public treasury;
    IRandomSource public randomSource;
    string private baseUri;

    uint32[] private prizes;   // USD 6 decimals
    uint16[] private weights;  // out of 10_000
    uint16 public potBps = 200;            // share of each sale credited to the pot
    uint256 public potUsd;                 // current pot (6 decimals)
    uint256 public immutable potFullUsd;   // pot pays this once full
    uint256 public immutable potSmallUsd;  // pot line pays this while filling

    Stock[] private stocks;
    mapping(address => uint256) private stockIndex; // token => index + 1

    // ------------------------------------------------------------------ state
    uint256 public nextId = 1;
    uint64 public nextBatch = 1;
    mapping(uint256 => Crate) public crates;
    mapping(uint64 => Batch) public batches;
    mapping(uint64 => uint256[]) private batchIds;
    mapping(uint256 => uint64) public requestBatch;

    uint256 public totalSold;
    uint256 public totalOpened;
    uint256 public totalPaidUsd;
    uint256 public totalSent;

    // ------------------------------------------------------------------ events
    event Bought(address indexed buyer, uint256 firstId, uint256 quantity, bool withEth, uint256 paid);
    event OpenRequested(address indexed owner, uint64 indexed batch, uint256 requestId, uint256[] ids);
    event Randomness(uint64 indexed batch, bytes32 seed);
    event Rolled(uint256 indexed id, uint64 indexed batch, uint256 prizeUsd, address stock, uint256 amount, bool pot);
    event Paid(uint256 indexed id, address indexed owner, address stock, uint256 amount, uint256 prizeUsd);
    event Waiting(uint256 indexed id, address stock, uint256 amount);
    event Sent(address indexed from, address indexed to, uint256[] ids);
    event StockSet(address indexed token, address feed, uint32 maxAge, bool paying);
    event OddsSet(uint32[] prizes, uint16[] weights);

    error BadQuantity();
    error NotOwner(uint256 id);
    error NotSealed(uint256 id);
    error Expired(uint256 id);
    error FeeTooLow(uint256 needed);
    error OnlySource();
    error NotTransferable(uint256 id);
    error BadOdds();
    error EthRefundFailed();

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        address treasury_,
        IERC20 stable_,
        address ethUsdFeed_,
        IRandomSource source_,
        uint256 priceUsd_,
        uint256 potFullUsd_,
        uint256 potSmallUsd_
    ) ERC721(name_, symbol_) Ownable(owner_) {
        treasury = treasury_;
        stable = stable_;
        stableDecimals = IERC20Metadata(address(stable_)).decimals();
        ethUsdFeed = ethUsdFeed_;
        randomSource = source_;
        priceUsd = priceUsd_;
        potFullUsd = potFullUsd_;
        potSmallUsd = potSmallUsd_;
    }

    // ================================================================= buying

    /// @notice ETH needed to pay for `quantity` crates right now.
    function ethPrice(uint256 quantity) public view returns (uint256) {
        (uint256 p, uint8 d) = PriceLib.read(ethUsdFeed, ethFeedMaxAge);
        return PriceLib.usdToToken(priceUsd * quantity, p, d, 18);
    }

    /// @notice Buy sealed crates. Pay in the stable coin (approve first) or send ETH with `withEth`.
    function buy(uint256 quantity, bool withEth) external payable nonReentrant returns (uint256 firstId) {
        if (quantity == 0 || quantity > MAX_BATCH) revert BadQuantity();
        uint256 costUsd = priceUsd * quantity;
        uint256 paid;
        if (withEth) {
            paid = ethPrice(quantity);
            if (msg.value < paid) revert FeeTooLow(paid);
            _sendEth(treasury, paid);
            if (msg.value > paid) _sendEth(msg.sender, msg.value - paid);
        } else {
            paid = (costUsd * (10 ** stableDecimals)) / 1e6;
            stable.safeTransferFrom(msg.sender, treasury, paid);
            if (msg.value > 0) _sendEth(msg.sender, msg.value);
        }
        potUsd += (costUsd * potBps) / 10_000;
        firstId = nextId;
        for (uint256 i; i < quantity; ++i) {
            uint256 id = nextId++;
            crates[id] = Crate(Status.Sealed, uint40(block.timestamp), 0, 0, false, address(0), 0);
            _safeMint(msg.sender, id);
        }
        totalSold += quantity;
        emit Bought(msg.sender, firstId, quantity, withEth, paid);
    }

    // ================================================================= sending

    /// @notice Send sealed crates to another wallet (max 200).
    function sendMany(address to, uint256[] calldata ids) external {
        if (ids.length == 0 || ids.length > MAX_BATCH) revert BadQuantity();
        for (uint256 i; i < ids.length; ++i) transferFrom(msg.sender, to, ids[i]);
        totalSent += ids.length;
        emit Sent(msg.sender, to, ids);
    }

    /// @dev Only sealed, unexpired crates can move. Opening / opened crates stay put.
    function _update(address to, uint256 id, address auth)
        internal
        override(ERC721Enumerable)
        returns (address)
    {
        address from = _ownerOf(id);
        if (from != address(0) && to != address(0)) {
            Crate storage c = crates[id];
            if (c.status != Status.Sealed || block.timestamp > c.boughtAt + EXPIRY) revert NotTransferable(id);
        }
        return super._update(to, id, auth);
    }

    // ================================================================= opening

    /// @notice Gas the random callback needs for `n` crates.
    function callbackGas(uint256 n) public pure returns (uint32) {
        uint256 k = n < INLINE_SETTLE ? n : INLINE_SETTLE;
        return uint32(BASE_GAS + GAS_PER_CRATE * k);
    }

    /// @notice Opening fee (wei) for `n` crates. It pays for the random number only.
    function openFee(uint256 n) external view returns (uint256) {
        return randomSource.fee(callbackGas(n));
    }

    /// @notice Open up to 200 of your sealed crates with one random number.
    function open(uint256[] calldata ids) external payable nonReentrant returns (uint64 batchId) {
        uint256 n = ids.length;
        if (n == 0 || n > MAX_BATCH) revert BadQuantity();
        batchId = nextBatch++;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            if (ownerOf(id) != msg.sender) revert NotOwner(id);
            Crate storage c = crates[id];
            if (c.status != Status.Sealed) revert NotSealed(id);
            if (block.timestamp > c.boughtAt + EXPIRY) revert Expired(id);
            c.status = Status.Opening;
            c.batch = batchId;
        }
        batches[batchId] = Batch(msg.sender, bytes32(0), false, uint32(n), 0, 0);
        batchIds[batchId] = ids;

        uint32 gasLimit = callbackGas(n);
        uint256 f = randomSource.fee(gasLimit);
        if (msg.value < f) revert FeeTooLow(f);
        uint256 requestId = randomSource.request{value: f}(gasLimit);
        requestBatch[requestId] = batchId;
        if (msg.value > f) _sendEth(msg.sender, msg.value - f);
        emit OpenRequested(msg.sender, batchId, requestId, ids);
    }

    /// @inheritdoc IRandomConsumer
    function onRandom(uint256 requestId, bytes32 seed) external {
        if (msg.sender != address(randomSource)) revert OnlySource();
        uint64 b = requestBatch[requestId];
        Batch storage bt = batches[b];
        if (b == 0 || bt.ready) return; // unknown or duplicate: never revert inside the callback
        bt.seed = seed;
        bt.ready = true;
        emit Randomness(b, seed);
        // Pay what we can right away. A failure here must not undo the seed.
        try this.settleFromCallback(b) {} catch {}
    }

    /// @dev External so the callback can wrap it in try/catch. Only callable by this contract.
    function settleFromCallback(uint64 b) external {
        if (msg.sender != address(this)) revert OnlySource();
        _settle(b, INLINE_SETTLE);
    }

    /// @notice Finish a batch: rolls prizes not yet rolled and pays crates waiting on the vault.
    /// Anyone can call it; stock always goes to the batch owner.
    function settle(uint64 b, uint256 max) external nonReentrant returns (uint256 paid) {
        return _settle(b, max == 0 ? 50 : max);
    }

    function _settle(uint64 b, uint256 max) internal returns (uint256 paid) {
        Batch storage bt = batches[b];
        if (!bt.ready || bt.done == bt.size) return 0;
        uint256[] storage ids = batchIds[b];
        for (uint256 i; i < ids.length && paid < max; ++i) {
            uint256 id = ids[i];
            Crate storage c = crates[id];
            if (c.status == Status.Opened) continue;
            if (c.prizeUsd == 0) {
                if (!_roll(id, c, bt.seed)) continue; // nothing paying right now
                bt.rolled++;
            }
            if (IERC20(c.stock).balanceOf(address(this)) < c.amount) {
                emit Waiting(id, c.stock, c.amount);
                continue;
            }
            c.status = Status.Opened;
            bt.done++;
            totalOpened++;
            totalPaidUsd += c.prizeUsd;
            IERC20(c.stock).safeTransfer(bt.owner, c.amount);
            emit Paid(id, bt.owner, c.stock, c.amount, c.prizeUsd);
            paid++;
        }
    }

    /// @dev Decide prize and stock for one crate. Returns false if no stock is paying.
    function _roll(uint256 id, Crate storage c, bytes32 seed) internal returns (bool) {
        uint256 r = uint256(keccak256(abi.encode(seed, id)));
        uint256 prize;
        bool fromPot;
        if (r % 1000 == 999) {
            if (potUsd >= potFullUsd) {
                prize = potFullUsd;
                potUsd -= potFullUsd;
                fromPot = true;
            } else {
                prize = potSmallUsd;
            }
        } else {
            uint256 w = (r >> 16) % 10_000;
            uint256 acc;
            for (uint256 i; i < weights.length; ++i) {
                acc += weights[i];
                if (w < acc) { prize = prizes[i]; break; }
            }
        }
        // pick a paying stock
        uint256 n;
        for (uint256 i; i < stocks.length; ++i) if (stocks[i].paying) n++;
        if (n == 0) {
            if (fromPot) potUsd += prize; // give it back, roll again later
            return false;
        }
        uint256 pick = (r >> 64) % n;
        Stock memory s;
        for (uint256 i; i < stocks.length; ++i) {
            if (!stocks[i].paying) continue;
            if (pick == 0) { s = stocks[i]; break; }
            pick--;
        }
        (uint256 p, uint8 d) = PriceLib.read(s.feed, s.maxAge);
        uint256 amount = PriceLib.usdToToken(prize, p, d, IERC20Metadata(s.token).decimals());
        c.prizeUsd = uint32(prize);
        c.pot = fromPot;
        c.stock = s.token;
        c.amount = amount;
        emit Rolled(id, c.batch, prize, s.token, amount, fromPot);
        return true;
    }

    // ================================================================= views

    function odds() external view returns (uint32[] memory, uint16[] memory) {
        return (prizes, weights);
    }

    function stockList() external view returns (Stock[] memory) {
        return stocks;
    }

    function batchCrates(uint64 b) external view returns (uint256[] memory) {
        return batchIds[b];
    }

    function isExpired(uint256 id) external view returns (bool) {
        return crates[id].boughtAt != 0 && block.timestamp > crates[id].boughtAt + EXPIRY;
    }

    /// @notice Vault balance per stock, for the Vault page.
    function vault() external view returns (address[] memory tokens, uint256[] memory balances) {
        tokens = new address[](stocks.length);
        balances = new uint256[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            tokens[i] = stocks[i].token;
            balances[i] = IERC20(stocks[i].token).balanceOf(address(this));
        }
    }

    function _baseURI() internal view override(ERC721) returns (string memory) {
        return baseUri;
    }

    // ================================================================= admin
    // Use a multisig as owner. Odds changes are public events; announce them before you make them.

    function setOdds(uint32[] calldata p, uint16[] calldata w) external onlyOwner {
        if (p.length != w.length || p.length == 0) revert BadOdds();
        uint256 sum;
        for (uint256 i; i < w.length; ++i) sum += w[i];
        if (sum != 10_000) revert BadOdds();
        prizes = p;
        weights = w;
        emit OddsSet(p, w);
    }

    function setStock(address token, address feed, uint32 maxAge, bool paying) external onlyOwner {
        uint256 idx = stockIndex[token];
        if (idx == 0) {
            stocks.push(Stock(token, feed, maxAge, paying));
            stockIndex[token] = stocks.length;
        } else {
            stocks[idx - 1] = Stock(token, feed, maxAge, paying);
        }
        emit StockSet(token, feed, maxAge, paying);
    }

    function setPotBps(uint16 bps) external onlyOwner { require(bps <= 2_000); potBps = bps; }
    function setTreasury(address t) external onlyOwner { treasury = t; }
    function setRandomSource(IRandomSource s) external onlyOwner { randomSource = s; }
    function setEthFeed(address f, uint32 maxAge) external onlyOwner { ethUsdFeed = f; ethFeedMaxAge = maxAge; }
    function setBaseURI(string calldata u) external onlyOwner { baseUri = u; }

    /// @notice Move stock out of the vault (rebalancing). Visible onchain like everything else.
    function withdrawStock(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthRefundFailed();
    }
}
