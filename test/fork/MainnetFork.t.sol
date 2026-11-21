// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CrateBox} from "../../src/CrateBox.sol";
import {DrandSource} from "../../src/random/DrandSource.sol";
import {IRandomSource, AggregatorV3Interface} from "../../src/interfaces/IRandom.sol";

/// Runs against a COPY of Robinhood Chain mainnet (nothing is sent to the real chain):
///   forge test --match-path test/fork/MainnetFork.t.sol --fork-url $ROBINHOOD_RPC_URL --ffi -vv
/// `npm run launch` runs it for you. It uses the real USDG, the real stock token and its real
/// Chainlink feed, and a REAL drand beacon fetched with curl, so it proves the whole crate flow
/// (buy -> open -> drand signature checked onchain -> stock paid) before you deploy for real.
contract MainnetForkTest is Test {
    address user = address(0xC0FFEE);

    function test_fullCrateFlowOnMainnetCopy() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        address stable = vm.envAddress("STABLE");
        address ethFeed = vm.envAddress("ETH_USD_FEED");
        address stock = vm.envAddress("FORK_STOCK");
        address stockFeed = vm.envAddress("FORK_STOCK_FEED");

        // feeds must answer and be reasonably fresh (stock feeds pause on weekends)
        (, int256 sp,, uint256 su,) = AggregatorV3Interface(stockFeed).latestRoundData();
        (, int256 ep,, uint256 eu,) = AggregatorV3Interface(ethFeed).latestRoundData();
        assertGt(sp, 0, "stock feed returns no price");
        assertGt(ep, 0, "ETH/USD feed returns no price");
        if (block.timestamp - su > 4 days) console2.log("WARNING: stock feed older than 4 days");
        if (block.timestamp - eu > 1 days) console2.log("WARNING: ETH/USD feed older than 1 day");

        // randomness: real drand evmnet key
        uint256[4] memory pk = [vm.envUint("DRAND_PK_0"), vm.envUint("DRAND_PK_1"), vm.envUint("DRAND_PK_2"), vm.envUint("DRAND_PK_3")];
        DrandSource drand = new DrandSource(address(this), pk, uint64(vm.envUint("DRAND_GENESIS")), uint64(vm.envUint("DRAND_PERIOD")), 0);

        CrateBox box = new CrateBox("StockBox Normal", "SCN", address(this), address(0x7EA5), IERC20(stable),
            ethFeed, IRandomSource(address(drand)), 100_000, 2_500_000, 200_000);
        drand.setConsumer(address(box), true);
        uint32[] memory p = new uint32[](7);
        uint16[] memory w = new uint16[](7);
        (p[0], p[1], p[2], p[3], p[4], p[5], p[6]) = (10_000, 25_000, 50_000, 100_000, 200_000, 500_000, 1_000_000);
        (w[0], w[1], w[2], w[3], w[4], w[5], w[6]) = (1600, 2600, 2700, 2000, 800, 250, 50);
        box.setOdds(p, w);
        box.setStock(stock, stockFeed, 0, true);

        // fill the vault and give the test user USDG + ETH (only on this local copy)
        uint8 sd = IERC20Metadata(stock).decimals();
        deal(stock, address(box), 100 * 10 ** sd);
        deal(stable, user, 100 * 10 ** IERC20Metadata(stable).decimals());
        vm.deal(user, 1 ether);

        // buy with USDG and with ETH
        vm.startPrank(user);
        IERC20(stable).approve(address(box), type(uint256).max);
        uint256 first = box.buy(4, false);
        box.buy{value: box.ethPrice(1) * 2}(1, true);
        assertEq(box.balanceOf(user), 5, "buying failed");

        // open all five
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < 5; ++i) ids[i] = first + i;
        uint64 batch = box.open{value: box.openFee(5)}(ids);
        vm.stopPrank();

        // wait for the committed drand round, fetch its real signature, submit it
        (, uint64 round,) = drand.requests(1);
        vm.warp(uint256(drand.genesis()) + uint256(round - 1) * drand.period() + 1);
        bytes memory sig = _drandSignature(round);
        (uint256 sx, uint256 sy) = abi.decode(sig, (uint256, uint256));
        uint256[2] memory s = [sx, sy];
        drand.fulfill(1, s);

        (,, bool ready,, uint32 done,) = box.batches(batch);
        assertTrue(ready, "drand signature was not accepted");
        assertEq(done, 5, "not every crate was paid");
        assertGt(IERC20(stock).balanceOf(user), 0, "user got no stock");
        console2.log("OK: bought 5, opened 5 with a real drand beacon, paid in stock. USD paid (6 dec):", box.totalPaidUsd());
    }

    function _drandSignature(uint64 round) internal returns (bytes memory) {
        string memory url = string.concat("https://api.drand.sh/", vm.envString("DRAND_CHAIN_HASH"), "/public/", vm.toString(uint256(round)));
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "for i in $(seq 1 20); do r=$(curl -sf ", url, ") && echo \"$r\" | sed -E 's/.*\"signature\":\"([0-9a-fA-F]+)\".*/0x\\1/' && exit 0; sleep 3; done; exit 1"
        );
        bytes memory out = vm.ffi(cmd);
        require(out.length == 64, "drand signature is not 64 bytes (evmnet G1 x,y)");
        return out;
    }
}
