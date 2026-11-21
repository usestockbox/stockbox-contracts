# StockBox contracts

Smart contracts behind [usestockbox.com](https://usestockbox.com): mystery crates, gift crates, baskets and swaps that pay out real Robinhood stock tokens on **Robinhood Chain** (chain id 4663).

[Website](https://usestockbox.com) · [X @usestockbox](https://x.com/usestockbox) · [Docs](https://usestockbox.com/#docs)

## Deployed on Robinhood Chain mainnet

| Contract | Address |
|---|---|
| CrateBox (normal crate, $0.10) | [`0xf525c15ab491bb3fcc8dc69cbae33384fe4cc966`](https://robinhoodchain.blockscout.com/address/0xf525c15ab491bb3fcc8dc69cbae33384fe4cc966) |
| CrateBox (premium crate, $1) | [`0xdd97336d04e27e5630ab6208a44e322b0cf94f8d`](https://robinhoodchain.blockscout.com/address/0xdd97336d04e27e5630ab6208a44e322b0cf94f8d) |
| GiftCrates | [`0x043994f9baae0beff9af0b324b9fd499c0ffcf8a`](https://robinhoodchain.blockscout.com/address/0x043994f9baae0beff9af0b324b9fd499c0ffcf8a) |
| BasketRegistry | [`0x14e1c8aad9bad2fed0e53ce362ccdcf3f4c7237a`](https://robinhoodchain.blockscout.com/address/0x14e1c8aad9bad2fed0e53ce362ccdcf3f4c7237a) |
| StockRouter | [`0x28182af2e40e967c98c3eef596a08ff880d87d1d`](https://robinhoodchain.blockscout.com/address/0x28182af2e40e967c98c3eef596a08ff880d87d1d) |
| DrandSource (randomness) | [`0x3a1783e4685b2075cfc736c3df0948a0f359c4d1`](https://robinhoodchain.blockscout.com/address/0x3a1783e4685b2075cfc736c3df0948a0f359c4d1) |

Every crate is an onchain NFT. Prizes are paid from each crate's own vault, which anyone can check on the explorer.

### Stock tokens and price feeds

| Stock | Token | Chainlink feed |
|---|---|---|
| AAPL | [`0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9`](https://robinhoodchain.blockscout.com/address/0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9) | [`0x6B22A786bAa607d76728168703a39Ea9C99f2cD0`](https://robinhoodchain.blockscout.com/address/0x6B22A786bAa607d76728168703a39Ea9C99f2cD0) |
| AMZN | [`0x12f190a9F9d7D37a250758b26824B97CE941bF54`](https://robinhoodchain.blockscout.com/address/0x12f190a9F9d7D37a250758b26824B97CE941bF54) | [`0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C`](https://robinhoodchain.blockscout.com/address/0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C) |
| AMD | [`0x86923f96303D656E4aa86D9d42D1e57ad2023fdC`](https://robinhoodchain.blockscout.com/address/0x86923f96303D656E4aa86D9d42D1e57ad2023fdC) | [`0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72`](https://robinhoodchain.blockscout.com/address/0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72) |
| COIN | [`0x6330D8C3178a418788dF01a47479c0ce7CCF450b`](https://robinhoodchain.blockscout.com/address/0x6330D8C3178a418788dF01a47479c0ce7CCF450b) | [`0xA3a468A452940B7D6b69991207B508c609a98Ef2`](https://robinhoodchain.blockscout.com/address/0xA3a468A452940B7D6b69991207B508c609a98Ef2) |
| CRCL | [`0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5`](https://robinhoodchain.blockscout.com/address/0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5) | [`0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a`](https://robinhoodchain.blockscout.com/address/0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a) |

Machine-readable list: [`deployments.json`](deployments.json).

## How it works

- **CrateBox**: buy a sealed crate with USDG or ETH. Opening it requests one random number; the prize comes from a published odds table and is paid in stock tokens from the crate's vault. A crate can also hit the bonus pot (1 in 1,000).
- **DrandSource**: randomness from the [drand](https://drand.love) evmnet beacon, verified onchain with BLS signatures, so nobody (including us) can pick the result.
- **GiftCrates**: fill a crate with stock tokens and send it to a wallet, a list of wallets or anyone with a link.
- **BasketRegistry**: mixes of up to 20 tokens that anyone can create and buy.
- **StockRouter**: swaps through Uniswap on Robinhood Chain, with prices checked against Chainlink and a slippage cap.

## Build and test

Requires [Foundry](https://getfoundry.sh).

```
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0 pyth-network/pyth-crosschain randa-mu/bls-solidity --no-git
forge build
forge test
```

## Disclaimer

Not investment advice. Prizes are random; a crate can be worth more or less than you paid. Robinhood stock tokens are not available in the US. StockBox is not affiliated with Robinhood or the companies shown.

## License

MIT
