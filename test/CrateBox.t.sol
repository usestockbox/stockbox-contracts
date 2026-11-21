// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CrateBox} from "../src/CrateBox.sol";
import {IRandomSource} from "../src/interfaces/IRandom.sol";
import {MockERC20, MockFeed, MockRandomSource} from "./mocks/Mocks.sol";

contract CrateBoxTest is Test {
    CrateBox box;
    MockERC20 usdg;
    MockERC20 nvda;
    MockFeed nvdaFeed;
    MockFeed ethFeed;
    MockRandomSource rng;
    address treasury = address(0x7EA5);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockERC20("NVIDIA", "NVDAc", 18);
        nvdaFeed = new MockFeed(160e8, 8);   // $160
        ethFeed = new MockFeed(3000e8, 8);   // $3000
        rng = new MockRandomSource();
        box = new CrateBox("StockBox Normal", "SCN", address(this), treasury, IERC20(address(usdg)),
            address(ethFeed), IRandomSource(address(rng)), 100_000, 2_500_000, 200_000);
        uint32[] memory p = new uint32[](7);
        uint16[] memory w = new uint16[](7);
        (p[0], p[1], p[2], p[3], p[4], p[5], p[6]) = (10_000, 25_000, 50_000, 100_000, 200_000, 500_000, 1_000_000);
        (w[0], w[1], w[2], w[3], w[4], w[5], w[6]) = (1600, 2600, 2700, 2000, 800, 250, 50);
        box.setOdds(p, w);
        box.setStock(address(nvda), address(nvdaFeed), 0, true);
        nvda.mint(address(box), 100e18); // vault
        usdg.mint(alice, 1_000e6);
        vm.prank(alice);
        usdg.approve(address(box), type(uint256).max);
    }

    function _buy(uint256 n) internal returns (uint256 first) {
        vm.prank(alice);
        first = box.buy(n, false);
    }

    function _ids(uint256 first, uint256 n) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = first + i;
    }

    function test_buyWithStable() public {
        uint256 first = _buy(10);
        assertEq(box.ownerOf(first), alice);
        assertEq(box.balanceOf(alice), 10);
        assertEq(usdg.balanceOf(treasury), 1e6); // 10 x $0.10
        assertEq(box.potUsd(), 20_000);          // 2% of $1
        assertEq(box.totalSold(), 10);
    }

    function test_buyWithEthRefundsExtra() public {
        uint256 need = box.ethPrice(1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        box.buy{value: 1 ether}(1, true);
        assertEq(treasury.balance, need);
        assertEq(alice.balance, 1 ether - need);
    }

    function test_openAndPay() public {
        uint256 first = _buy(5);
        vm.prank(alice);
        uint64 b = box.open(_ids(first, 5));
        rng.fulfill(1, keccak256("seed"));
        (,,,, uint32 done,) = box.batches(b);
        assertEq(done, 5);
        assertGt(nvda.balanceOf(alice), 0);
        assertEq(box.totalOpened(), 5);
    }

    function test_cannotMoveOpenedCrate() public {
        uint256 first = _buy(1);
        vm.prank(alice);
        box.open(_ids(first, 1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrateBox.NotTransferable.selector, first));
        box.transferFrom(alice, bob, first);
    }

    function test_sendSealed() public {
        uint256 first = _buy(3);
        vm.prank(alice);
        box.sendMany(bob, _ids(first, 3));
        assertEq(box.balanceOf(bob), 3);
        assertEq(box.totalSent(), 3);
    }

    function test_expiredCannotOpen() public {
        uint256 first = _buy(1);
        vm.warp(block.timestamp + 366 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrateBox.Expired.selector, first));
        box.open(_ids(first, 1));
    }

    function test_vaultShortWaitsThenSettles() public {
        box.withdrawStock(address(nvda), 100e18, address(this));
        uint256 first = _buy(2);
        vm.prank(alice);
        uint64 b = box.open(_ids(first, 2));
        rng.fulfill(1, keccak256("x"));
        (,,,, uint32 done,) = box.batches(b);
        assertEq(done, 0);
        nvda.mint(address(box), 10e18); // refill
        box.settle(b, 0);
        (,,,, done,) = box.batches(b);
        assertEq(done, 2);
    }

    function test_onlySourceCanCallback() public {
        vm.expectRevert(CrateBox.OnlySource.selector);
        box.onRandom(1, bytes32(0));
    }

    function test_oddsMustSumTo10000() public {
        uint32[] memory p = new uint32[](1);
        uint16[] memory w = new uint16[](1);
        p[0] = 1; w[0] = 9999;
        vm.expectRevert(CrateBox.BadOdds.selector);
        box.setOdds(p, w);
    }

    function test_openFeeRequired() public {
        rng.setFee(0.01 ether);
        uint256 first = _buy(1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrateBox.FeeTooLow.selector, 0.01 ether));
        box.open(_ids(first, 1));
    }

    /// Over many rolls the average payout should be close to the published average.
    function test_averagePayoutMatchesOdds() public {
        usdg.mint(alice, 100_000e6);
        nvda.mint(address(box), 10_000e18);
        uint256 total;
        for (uint256 k; k < 10; ++k) {
            uint256 first = _buy(200);
            vm.prank(alice);
            uint64 b = box.open(_ids(first, 200));
            rng.fulfill(k + 1, keccak256(abi.encode(k)));
            box.settle(b, 200);
        }
        total = box.totalPaidUsd();
        // published average of the table above is ~$0.0751 per crate (sum of prize x chance)
        assertApproxEqRel(total / 2000, 75_100, 0.15e18);
    }
}
