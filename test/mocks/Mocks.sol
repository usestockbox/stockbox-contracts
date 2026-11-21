// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRandomSource, IRandomConsumer} from "../../src/interfaces/IRandom.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { dec = d; }
    function decimals() public view override returns (uint8) { return dec; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 a) external {
        _burn(msg.sender, a);
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok);
    }
}

contract MockFeed {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;
    constructor(int256 a, uint8 d) { answer = a; decimals = d; updatedAt = block.timestamp; }
    function set(int256 a) external { answer = a; updatedAt = block.timestamp; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Random source where the test decides when the number arrives.
contract MockRandomSource is IRandomSource {
    uint256 public nextId = 1;
    uint256 public price;
    mapping(uint256 => address) public consumerOf;
    function setFee(uint256 f) external { price = f; }
    function fee(uint32) external view returns (uint256) { return price; }
    function request(uint32) external payable returns (uint256 id) {
        require(msg.value >= price, "fee");
        id = nextId++;
        consumerOf[id] = msg.sender;
    }
    function fulfill(uint256 id, bytes32 seed) external {
        IRandomConsumer(consumerOf[id]).onRandom(id, seed);
    }
}

/// @notice DEX stand-in: swaps at a fixed rate (out = in * num / den) and pays `to`.
contract MockDex {
    uint256 public num;
    uint256 public den;
    constructor(uint256 n, uint256 d) { num = n; den = d; }
    function setRate(uint256 n, uint256 d) external { num = n; den = d; }
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to) external returns (uint256 out) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = (amountIn * num) / den;
        MockERC20(tokenOut).mint(to, out);
    }
}
