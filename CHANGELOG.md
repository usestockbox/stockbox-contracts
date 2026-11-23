# Changelog

All notable changes to StockBox on Robinhood Chain (chain id 4663).

## 2026-11-23 · Day 1

### Added
- Holder-only gift links: GiftCrates `Access.Verified`. A claim needs a signature from the StockBox verifier, which is given only to wallets holding at least 500,000 $STOCKBOX.
- Anti-bot checks for holder links: balance snapshot at link creation, minimum wallet activity, limited wallets per connection.
- Token gift boxes: fill gift crates with any ERC-20 straight from the creator's wallet (`GiftCrates.create`), with presets for $STOCKBOX, $PONS and $HEY.
- Official $STOCKBOX token: `0xf58063bf99aa8241fef4668b9ed283bec531d450`.
- HEY Research page claimed with an onchain owner signature.

### Changed
- `GiftCrates.setVerifier` set to the StockBox keeper.

### Verified
- All 6 contracts verified on Blockscout: Normal crate, Premium crate, StockRouter, GiftCrates, BasketRegistry, DrandSource.

## 2026-11-22 · Launch
- Contracts deployed to Robinhood Chain mainnet.
- usestockbox.com live: crates, gifts, baskets, swap, campaigns.
- $STOCKBOX launched on Pons.
