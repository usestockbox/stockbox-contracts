// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "./interfaces/IRandom.sol";
import {PriceLib} from "./lib/PriceLib.sol";
import {GiftCrates} from "./GiftCrates.sol";
import {BasketRegistry} from "./BasketRegistry.sol";

/// @title StockBox router
/// @notice Every trade on the Swap tab, every gift paid in USDG/ETH and every basket buy goes
/// through here. It takes the fee, calls a whitelisted DEX router with calldata built by the API,
/// and refuses the trade if what comes out is worth too little versus Chainlink.
/// The router never keeps user funds between transactions.
contract StockRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Leg {
        address tokenOut;   // what this leg buys
        uint256 amountIn;   // pay-token amount spent on this leg (after fee)
        uint256 minOut;
        address target;     // whitelisted DEX router; address(0) = keep the pay token as is
        bytes data;         // DEX calldata, recipient must be this router
    }

    struct Feed {
        address feed;
        uint32 maxAge;
        uint16 guardBps;    // max shortfall vs Chainlink for trades touching this token
        bool isStock;
    }

    IWETH public immutable weth;
    GiftCrates public immutable gift;        // address(0) on chains without gift crates
    BasketRegistry public immutable baskets; // address(0) on chains without baskets
    address public treasury;

    uint16 public stockFeeBps = 100;  // 1%
    uint16 public moneyFeeBps = 75;   // 0.75%
    uint16 public giftFeeBps = 250;   // 2.5%
    uint16 public makerBps = 100;     // 1% of a basket buy to its maker

    mapping(address => bool) public targets;
    mapping(address => Feed) public feeds;

    event Swapped(address indexed user, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, uint256 fee);
    event GiftBought(address indexed user, uint256 indexed batchId, address payToken, uint256 paid, uint256 fee);
    event BasketBought(address indexed user, uint256 indexed basketId, uint256 indexed batchId, uint32 quantity, uint256 paid, uint256 makerFee);

    error Expired();
    error BadTarget();
    error TooLittle(uint256 out, uint256 minOut);
    error PriceGuard(uint256 valueIn, uint256 valueOut);
    error BadLegs();
    error EthFailed();

    constructor(address owner_, address treasury_, IWETH weth_, GiftCrates gift_, BasketRegistry baskets_)
        Ownable(owner_)
    {
        treasury = treasury_;
        weth = weth_;
        gift = gift_;
        baskets = baskets_;
    }

    receive() external payable {
        require(msg.sender == address(weth), "no direct ETH");
    }

    // ================================================================= swap

    /// @notice Swap `amountIn` of `tokenIn` (address(0) = ETH) for `tokenOut` (address(0) = ETH).
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        address target,
        bytes calldata data,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 out) {
        if (block.timestamp > deadline) revert Expired();
        address tin = _pull(tokenIn, amountIn);
        address tout = tokenOut == address(0) ? address(weth) : tokenOut;
        uint16 bps = (feeds[tin].isStock || feeds[tout].isStock) ? stockFeeBps : moneyFeeBps;
        uint256 fee = (amountIn * bps) / 10_000;
        IERC20(tin).safeTransfer(treasury, fee);
        uint256 net = amountIn - fee;
        out = _exec(tin, net, tout, minOut, target, data);
        _guard(tin, net, tout, out);
        _push(tokenOut, out, msg.sender);
        emit Swapped(msg.sender, tokenIn, amountIn, tokenOut, out, fee);
    }

    // ================================================================= gifts

    /// @notice Pay in USDG or ETH; the router buys each item and makes the gift crates.
    /// `p.items` is ignored: items are what the legs bought, split evenly over `p.count` crates.
    function buyGift(
        address payToken,
        uint256 payAmount,
        Leg[] calldata legs,
        GiftCrates.GiftParams calldata p,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 batchId) {
        if (block.timestamp > deadline) revert Expired();
        address pay = _pull(payToken, payAmount);
        uint256 fee = (payAmount * giftFeeBps) / 10_000;
        IERC20(pay).safeTransfer(treasury, fee);
        GiftCrates.GiftParams memory q = p;
        q.items = _runLegs(pay, payAmount - fee, legs, p.count);
        batchId = _makeGift(msg.sender, q);
        emit GiftBought(msg.sender, batchId, payToken, payAmount, fee);
    }

    // ================================================================= baskets

    /// @notice Buy `quantity` crates of a basket. Leg i must buy basket token i.
    function buyBasket(
        uint256 basketId,
        uint32 quantity,
        address payToken,
        uint256 payAmount,
        Leg[] calldata legs,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 batchId) {
        if (block.timestamp > deadline) revert Expired();
        BasketRegistry.Basket memory b = baskets.get(basketId);
        if (!b.active || legs.length != b.tokens.length || quantity == 0 || quantity > 100) revert BadLegs();
        address pay = _pull(payToken, payAmount);
        for (uint256 i; i < legs.length; ++i) {
            address want = b.tokens[i];
            if (legs[i].tokenOut != want) revert BadLegs();
        }
        uint256 fee = (payAmount * giftFeeBps) / 10_000;
        uint256 makerFee = b.maker != msg.sender ? (payAmount * makerBps) / 10_000 : 0;
        if (makerFee > 0) IERC20(pay).safeTransfer(b.maker, makerFee);
        IERC20(pay).safeTransfer(treasury, fee - makerFee);

        GiftCrates.GiftParams memory q;
        q.items = _runLegs(pay, payAmount - fee, legs, quantity);
        q.count = quantity;
        q.recipients = new address[](quantity);
        for (uint256 i; i < quantity; ++i) q.recipients[i] = msg.sender;
        q.design = b.design;
        batchId = _makeGift(msg.sender, q);
        emit BasketBought(msg.sender, basketId, batchId, quantity, payAmount, makerFee);
    }

    // ================================================================= internals

    function _runLegs(address pay, uint256 budget, Leg[] calldata legs, uint32 count)
        internal
        returns (GiftCrates.Item[] memory its)
    {
        if (legs.length == 0 || legs.length > 20 || count == 0) revert BadLegs();
        its = new GiftCrates.Item[](legs.length);
        uint256 spent;
        for (uint256 i; i < legs.length; ++i) {
            Leg calldata l = legs[i];
            spent += l.amountIn;
            if (spent > budget) revert BadLegs();
            uint256 out;
            if (l.target == address(0)) {
                if (l.tokenOut != pay) revert BadLegs();
                out = l.amountIn;
            } else {
                out = _exec(pay, l.amountIn, l.tokenOut, l.minOut, l.target, l.data);
                _guard(pay, l.amountIn, l.tokenOut, out);
            }
            uint256 per = out / count;
            if (per == 0) revert TooLittle(out, count);
            its[i] = GiftCrates.Item(l.tokenOut, per);
            uint256 dust = out - per * count;
            if (dust > 0) IERC20(l.tokenOut).safeTransfer(msg.sender, dust);
        }
        if (budget > spent) IERC20(pay).safeTransfer(msg.sender, budget - spent);
    }

    function _makeGift(address creator, GiftCrates.GiftParams memory q) internal returns (uint256) {
        for (uint256 i; i < q.items.length; ++i) {
            IERC20(q.items[i].token).forceApprove(address(gift), q.items[i].amount * q.count);
        }
        return gift.createFor(creator, q);
    }

    function _exec(address tin, uint256 amountIn, address tout, uint256 minOut, address target, bytes calldata data)
        internal
        returns (uint256 out)
    {
        if (!targets[target]) revert BadTarget();
        uint256 inBefore = IERC20(tin).balanceOf(address(this));
        uint256 outBefore = IERC20(tout).balanceOf(address(this));
        IERC20(tin).forceApprove(target, amountIn);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly { revert(add(ret, 32), mload(ret)) }
        }
        IERC20(tin).forceApprove(target, 0);
        out = IERC20(tout).balanceOf(address(this)) - outBefore;
        if (out < minOut) revert TooLittle(out, minOut);
        uint256 spent = inBefore - IERC20(tin).balanceOf(address(this));
        if (spent < amountIn) IERC20(tin).safeTransfer(msg.sender, amountIn - spent);
    }

    /// @dev Refuse trades that give back much less than Chainlink says they should.
    function _guard(address tin, uint256 amountIn, address tout, uint256 out) internal view {
        Feed memory a = feeds[tin];
        Feed memory b = feeds[tout];
        if (a.feed == address(0) || b.feed == address(0)) return; // tokens without a feed: API checks extra
        uint256 vin = _usd(tin, amountIn, a);
        uint256 vout = _usd(tout, out, b);
        uint256 g = a.guardBps > b.guardBps ? a.guardBps : b.guardBps;
        if (vout * 10_000 < vin * (10_000 - g)) revert PriceGuard(vin, vout);
    }

    function _usd(address token, uint256 amount, Feed memory f) internal view returns (uint256) {
        (uint256 p, uint8 d) = PriceLib.read(f.feed, f.maxAge);
        return PriceLib.tokenToUsd(amount, p, d, IERC20Metadata(token).decimals());
    }

    function _pull(address token, uint256 amount) internal returns (address) {
        if (token == address(0)) {
            if (msg.value != amount) revert BadLegs();
            weth.deposit{value: amount}();
            return address(weth);
        }
        if (msg.value != 0) revert BadLegs();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        return token;
    }

    function _push(address token, uint256 amount, address to) internal {
        if (token == address(0)) {
            weth.withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ================================================================= admin

    function setTarget(address t, bool ok) external onlyOwner { targets[t] = ok; }
    function setFeed(address token, address feed, uint32 maxAge, uint16 guardBps, bool isStock) external onlyOwner {
        require(guardBps <= 1_000);
        feeds[token] = Feed(feed, maxAge, guardBps, isStock);
    }
    function setFees(uint16 stock, uint16 money, uint16 giftFee, uint16 maker) external onlyOwner {
        require(stock <= 300 && money <= 300 && giftFee <= 500 && maker <= giftFee);
        (stockFeeBps, moneyFeeBps, giftFeeBps, makerBps) = (stock, money, giftFee, maker);
    }
    function setTreasury(address t) external onlyOwner { treasury = t; }
}
