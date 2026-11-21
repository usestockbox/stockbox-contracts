// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StockBox baskets
/// @notice Anyone can publish a basket: 2 to 20 tokens, each with a dollar amount per crate.
/// Buying happens in StockRouter, which turns the payment into the tokens and makes gift crates.
contract BasketRegistry {
    struct Basket {
        address maker;
        bool active;
        uint40 createdAt;
        string name;
        bytes32 design;
        address[] tokens;
        uint256[] usd;    // 6 decimals, per crate
    }

    uint256 public constant MIN_USD = 10_000; // $0.01 per token
    uint256 public nextId = 1;
    mapping(uint256 => Basket) private baskets;
    mapping(address => uint256[]) private byMaker;

    event BasketCreated(uint256 indexed id, address indexed maker, string name, address[] tokens, uint256[] usd, bytes32 design);
    event BasketActive(uint256 indexed id, bool active);

    error BadBasket();
    error NotMaker();

    function create(string calldata name, address[] calldata tokens, uint256[] calldata usd, bytes32 design)
        external
        returns (uint256 id)
    {
        uint256 n = tokens.length;
        if (n < 2 || n > 20 || usd.length != n || bytes(name).length == 0 || bytes(name).length > 32) revert BadBasket();
        for (uint256 i; i < n; ++i) {
            if (usd[i] < MIN_USD || tokens[i] == address(0)) revert BadBasket();
            for (uint256 j; j < i; ++j) if (tokens[j] == tokens[i]) revert BadBasket();
        }
        id = nextId++;
        Basket storage b = baskets[id];
        b.maker = msg.sender;
        b.active = true;
        b.createdAt = uint40(block.timestamp);
        b.name = name;
        b.design = design;
        b.tokens = tokens;
        b.usd = usd;
        byMaker[msg.sender].push(id);
        emit BasketCreated(id, msg.sender, name, tokens, usd, design);
    }

    function setActive(uint256 id, bool active) external {
        if (baskets[id].maker != msg.sender) revert NotMaker();
        baskets[id].active = active;
        emit BasketActive(id, active);
    }

    function get(uint256 id) external view returns (Basket memory) {
        return baskets[id];
    }

    function priceUsd(uint256 id) external view returns (uint256 total) {
        uint256[] storage u = baskets[id].usd;
        for (uint256 i; i < u.length; ++i) total += u[i];
    }

    function ofMaker(address maker) external view returns (uint256[] memory) {
        return byMaker[maker];
    }
}
