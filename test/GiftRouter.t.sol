// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {GiftCrates} from "../src/GiftCrates.sol";
import {BasketRegistry} from "../src/BasketRegistry.sol";
import {StockRouter} from "../src/StockRouter.sol";
import {IWETH} from "../src/interfaces/IRandom.sol";
import {MockERC20, MockWETH, MockFeed, MockDex} from "./mocks/Mocks.sol";

contract GiftRouterTest is Test {
    GiftCrates gift;
    BasketRegistry reg;
    StockRouter router;
    MockERC20 usdg;
    MockERC20 nvda;
    MockERC20 tsla;
    MockWETH weth;
    MockDex dex;
    address treasury = address(0x7EA5);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 verifierKey = 0xBEEF;

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockERC20("NVIDIA", "NVDAc", 18);
        tsla = new MockERC20("Tesla", "TSLAc", 18);
        weth = new MockWETH();
        gift = new GiftCrates(address(this), treasury, vm.addr(verifierKey));
        reg = new BasketRegistry();
        router = new StockRouter(address(this), treasury, IWETH(address(weth)), gift, reg);
        gift.setRouter(address(router));
        // 1 USDG (1e6) -> 1/160 NVDA (1e18/160): rate = 1e18 / (160 * 1e6)
        dex = new MockDex(1e12, 160);
        router.setTarget(address(dex), true);
        router.setFeed(address(usdg), address(new MockFeed(1e8, 8)), 0, 150, false);
        router.setFeed(address(nvda), address(new MockFeed(160e8, 8)), 0, 150, true);
        usdg.mint(alice, 10_000e6);
        vm.prank(alice);
        usdg.approve(address(router), type(uint256).max);
    }

    function _swapData(address tin, address tout, uint256 amt) internal view returns (bytes memory) {
        return abi.encodeCall(MockDex.swap, (tin, tout, amt, address(router)));
    }

    function test_swapTakesOnePercentStockFee() public {
        uint256 net = 99e6;
        vm.prank(alice);
        uint256 out = router.swap(address(usdg), 100e6, address(nvda), 0, address(dex),
            _swapData(address(usdg), address(nvda), net), block.timestamp);
        assertEq(usdg.balanceOf(treasury), 1e6);
        assertEq(nvda.balanceOf(alice), out);
        assertApproxEqRel(out, (99e18) / 160, 1e15);
    }

    function test_priceGuardRefusesBadQuote() public {
        dex.setRate(1e12, 170); // ~6% worse than Chainlink
        vm.prank(alice);
        vm.expectRevert();
        router.swap(address(usdg), 100e6, address(nvda), 0, address(dex),
            _swapData(address(usdg), address(nvda), 99e6), block.timestamp);
    }

    function test_unlistedTargetRefused() public {
        vm.prank(alice);
        vm.expectRevert(StockRouter.BadTarget.selector);
        router.swap(address(usdg), 100e6, address(nvda), 0, address(0xdead), "", block.timestamp);
    }

    function _linkParams(uint32 count, GiftCrates.Access access) internal pure returns (GiftCrates.GiftParams memory p) {
        p.count = count;
        p.access = access;
        p.title = "gm";
        p.note = "a tiny slice";
    }

    function test_buyGiftLinkClaimOpen() public {
        StockRouter.Leg[] memory legs = new StockRouter.Leg[](1);
        uint256 budget = 10e6 - (10e6 * 250) / 10_000; // after 2.5% fee
        legs[0] = StockRouter.Leg(address(nvda), budget, 0, address(dex), _swapData(address(usdg), address(nvda), budget));
        vm.prank(alice);
        uint256 batchId = router.buyGift(address(usdg), 10e6, legs, _linkParams(10, GiftCrates.Access.Anyone), block.timestamp);
        assertEq(usdg.balanceOf(treasury), 250_000);

        vm.prank(bob);
        uint256 id = gift.claim(batchId, new bytes32[](0), "");
        vm.prank(bob);
        vm.expectRevert(GiftCrates.AlreadyClaimed.selector);
        gift.claim(batchId, new bytes32[](0), "");

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(bob);
        gift.open(ids);
        assertGt(nvda.balanceOf(bob), 0);

        // alice takes back the 9 unclaimed crates
        uint256 before = nvda.balanceOf(alice);
        vm.prank(alice);
        gift.takeBack(batchId);
        assertEq(nvda.balanceOf(alice) - before, nvda.balanceOf(bob) * 9);
        (,,, uint32 total, uint32 minted,,,) = gift.batches(batchId);
        assertEq(total, minted);
    }

    function test_verifiedLinkNeedsSignature() public {
        StockRouter.Leg[] memory legs = new StockRouter.Leg[](1);
        uint256 budget = 10e6 - 250_000;
        legs[0] = StockRouter.Leg(address(usdg), budget, 0, address(0), ""); // gift USDG itself
        vm.prank(alice);
        uint256 batchId = router.buyGift(address(usdg), 10e6, legs, _linkParams(5, GiftCrates.Access.Verified), block.timestamp);

        vm.prank(bob);
        vm.expectRevert();
        gift.claim(batchId, new bytes32[](0), hex"00");

        bytes32 h = MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(address(gift), block.chainid, batchId, bob)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifierKey, h);
        vm.prank(bob);
        gift.claim(batchId, new bytes32[](0), abi.encodePacked(r, s, v));
        assertEq(gift.balanceOf(bob), 1);
    }

    function test_basketBuyPaysMaker() public {
        address[] memory tokens = new address[](2);
        uint256[] memory usd = new uint256[](2);
        (tokens[0], tokens[1]) = (address(nvda), address(usdg));
        (usd[0], usd[1]) = (1e6, 1e6);
        vm.prank(bob);
        uint256 basketId = reg.create("Mini", tokens, usd, bytes32(0));

        uint256 pay = 4e6; // 2 crates x $2
        uint256 net = pay - (pay * 250) / 10_000;
        StockRouter.Leg[] memory legs = new StockRouter.Leg[](2);
        legs[0] = StockRouter.Leg(address(nvda), net / 2, 0, address(dex), _swapData(address(usdg), address(nvda), net / 2));
        legs[1] = StockRouter.Leg(address(usdg), net / 2, 0, address(0), "");
        vm.prank(alice);
        router.buyBasket(basketId, 2, address(usdg), pay, legs, block.timestamp);
        assertEq(usdg.balanceOf(bob), (pay * 100) / 10_000); // maker 1%
        assertEq(gift.balanceOf(alice), 2);
    }
}
