// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20, MockFeed} from "../test/mocks/Mocks.sol";

/// Robinhood Chain TESTNET only (chain id 46630).
/// Deploys a test USDG, test stock tokens and price feeds you control, so the whole site can be
/// tried end to end before mainnet. Anyone can mint the test tokens (the site shows a faucet button
/// when NETWORK=testnet). Never use these on mainnet.
///
///   forge script script/TestnetMocks.s.sol --rpc-url robinhood_testnet --broadcast
///
/// Paste the printed addresses into config/robinhood-testnet.json (tokens[].address / feed,
/// stable.address, ethUsdFeed) and use STABLE / ETH_USD_FEED in .env for Deploy.s.sol.
contract TestnetMocks is Script {
    function run() external {
        require(block.chainid == 46630, "testnet only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        MockERC20 usdg = new MockERC20("Test Global Dollar", "USDG", 6);
        MockFeed usdgFeed = new MockFeed(1e8, 8);
        MockFeed ethFeed = new MockFeed(3000e8, 8);
        console2.log("USDG", address(usdg));
        console2.log("USDG feed", address(usdgFeed));
        console2.log("ETH/USD feed", address(ethFeed));

        string[4] memory sym = ["NVDA", "TSLA", "SPY", "QQQ"];
        int256[4] memory px = [int256(180e8), 390e8, 730e8, 660e8];
        for (uint256 i; i < 4; ++i) {
            MockERC20 t = new MockERC20(string.concat("Test ", sym[i]), sym[i], 18);
            MockFeed f = new MockFeed(px[i], 8);
            console2.log(sym[i], address(t));
            console2.log(string.concat(sym[i], " feed"), address(f));
        }
        vm.stopBroadcast();
    }
}
