// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CrateBox} from "../src/CrateBox.sol";
import {GiftCrates} from "../src/GiftCrates.sol";
import {BasketRegistry} from "../src/BasketRegistry.sol";
import {StockRouter} from "../src/StockRouter.sol";
import {PythEntropySource} from "../src/random/PythEntropySource.sol";
import {DrandSource} from "../src/random/DrandSource.sol";
import {IRandomSource, IWETH} from "../src/interfaces/IRandom.sol";

/// Robinhood Chain only.
/// Usage: forge script script/Deploy.s.sol --rpc-url robinhood --broadcast
///        (testnet first: --rpc-url robinhood_testnet)
/// Required env: PRIVATE_KEY, OWNER (multisig), TREASURY, STABLE (USDG), ETH_USD_FEED, WETH
///   randomness: DRAND_PK_0..3, DRAND_GENESIS, DRAND_PERIOD (or PYTH_ENTROPY if Pyth Entropy is live on Robinhood Chain)
/// After deploy run `node scripts/configure.mjs` to set odds, stocks, feeds and the Uniswap router.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        IERC20 stable = IERC20(vm.envAddress("STABLE"));
        address ethFeed = vm.envAddress("ETH_USD_FEED");

        vm.startBroadcast(pk);

        // randomness ----------------------------------------------------
        IRandomSource source;
        address pyth = vm.envOr("PYTH_ENTROPY", address(0));
        if (pyth != address(0)) {
            PythEntropySource s = new PythEntropySource(pyth, deployer);
            source = IRandomSource(address(s));
        } else {
            uint256[4] memory key = [
                vm.envUint("DRAND_PK_0"), vm.envUint("DRAND_PK_1"), vm.envUint("DRAND_PK_2"), vm.envUint("DRAND_PK_3")
            ];
            DrandSource s = new DrandSource(deployer, key, uint64(vm.envUint("DRAND_GENESIS")),
                uint64(vm.envUint("DRAND_PERIOD")), vm.envOr("DRAND_KEEPER_FEE", uint256(0)));
            source = IRandomSource(address(s));
        }

        // crates ($0.10 normal, $1 premium; pot $2.50 / $25, small pot line $0.20 / $2) ----
        CrateBox normal = new CrateBox("StockBox Normal", "SCN", deployer, treasury, stable,
            ethFeed, source, 100_000, 2_500_000, 200_000);
        CrateBox premium = new CrateBox("StockBox Premium", "SCP", deployer, treasury, stable,
            ethFeed, source, 1_000_000, 25_000_000, 2_000_000);
        _setConsumer(source, address(normal), pyth != address(0));
        _setConsumer(source, address(premium), pyth != address(0));

        // gifts, baskets, router ----------------------------------------
        // verifier stays empty: StockBox links are "anyone" or "wallet list"
        GiftCrates gift = new GiftCrates(deployer, treasury, address(0));
        BasketRegistry reg = new BasketRegistry();
        StockRouter router = new StockRouter(deployer, treasury, IWETH(vm.envAddress("WETH")), gift, reg);
        gift.setRouter(address(router));

        vm.stopBroadcast();

        console2.log("chain", "robinhood");
        console2.log("randomSource", address(source));
        console2.log("normal", address(normal));
        console2.log("premium", address(premium));
        console2.log("gift", address(gift));
        console2.log("baskets", address(reg));
        console2.log("router", address(router));
        console2.log("Next: node scripts/configure.mjs");
        console2.log("Then ownership goes to", owner);
    }

    function _setConsumer(IRandomSource source, address c, bool isPyth) internal {
        if (isPyth) PythEntropySource(payable(address(source))).setConsumer(c, true);
        else DrandSource(address(source)).setConsumer(c, true);
    }
}
