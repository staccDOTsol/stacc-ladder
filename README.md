# StaccLadder

A Uniswap v4 hook on Robinhood Chain (4663). For every token it trades, it opens a family of pools: one per quote asset (ETH, USDG, or any listed quote) per fee tier. All of them pay the EIP-8429 fee ratchet. Depositors can hand the hook a book, and the hook lays that book's liquidity across the family by volatility.

**ALPHA. Unaudited. Funds can be lost. Use amounts you can afford to lose.**

## Live on Robinhood Chain

| | |
|---|---|
| StaccLadder (hook) | [`0x3BDAd0B539F815eDE3ff89cF511F2C37f99215C7`](https://robinhoodchain.blockscout.com/address/0x3BDAd0B539F815eDE3ff89cF511F2C37f99215C7) |
| LadderLogic (linked library) | [`0x80Cb4F20E3d75Db82380827ABD5CD18a6aedfa36`](https://robinhoodchain.blockscout.com/address/0x80Cb4F20E3d75Db82380827ABD5CD18a6aedfa36) |
| PoolManager (canonical v4) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Quotes | native ETH; USDG `0x5fc5…d168`, priced by the ETH/USDG pool (fee 460, spacing 9, no hook) |
| Pons factory (allowed) | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` |

The full record is in [`deployments/robinhood-4663.json`](deployments/robinhood-4663.json).

## What it does

**Families.** A token with a reference gets one pool per (quote, tier). The tiers are 0.3%, 1%, 3% and 10% (spacing 60/100/200/200), all on this hook.
- Initializing any one of them opens the rest of that pair's tiers.
- `openFamily(token)` opens every pair at once.
- Anyone can open pools on the hook, and anyone can LP them directly.

**References.** Before graduation, the reference is the Pons bonding curve's reserves. After graduation, it's the Uniswap pool Pons seeds on its meme hook, read from the factory's launch record. The switch is automatic.
- Between Pons's sweep and the seeding of that pool, the token has no reference. Rebalances and the shield pause instead of guessing.
- Tokens that aren't Pons launches use a v4 pool the owner sets.

**The fee ratchet (StaccToll, EIP-8429 token-level form).** The k-th reference to a token in a block pays `10 bp * k^2` of the amount, capped at 100%. The count runs across all senders and transactions, and the first reference is free.
- Swaps pay on their unspecified leg.
- LP adds and removes pay on their principal.
- A remove in the same block as its add counts once more.
- Only the non-quote token is counted, so ETH and USDG flow never ratchets.
- The toll is taken in kind and held for the beneficiary. `sinkBps` of it goes to `0xdead` when swept.

**Books (depositor-keyed).** `setBook(tokens, quotes, operator)`, then `deposit`. Each book keeps its own balances and a per-quote deposit ledger (`quoteTotal`). The hook lays a book as single-sided ranges: asks are token only, bids are quote only.
- **Shared quotes, weighted by volatility.** Each quote is shared among the book's tokens in proportion to the token's 1h sigma on that quote, so higher-vol tokens get more.
- **Quote mix.** `rebalanceQuotes` swaps between quotes so each quote's value share follows the summed sigma of the book's tokens on it.
- **Fee tier.** The pair's sigma implies a target fee (`feePerVol * sigma`). Liquidity is blended across the two tiers that bracket it: vol up, higher tiers; vol down, lower tiers.
- **Range width.** `3 * sigma` of that pair, clamped to 600..60000 ticks.

**Placement never moves toward a taker.** Asks sit at or above the highest of the pool price, the live reference and the smoothed reference. Bids sit at or below the lowest of them. The smoothed reference is from earlier blocks only. A rebalance refuses to place a pair when live and smoothed disagree by more than `maxDev` ticks. Pushing a reference within one transaction can therefore only make a book's quotes worse for whoever pushed it.

**The shield (LVR).** Before every swap into a pool that holds books, the hook moves untouched single-sided ranges that the reference has run past back behind it. It moves up to `shieldMax` books per swap, rotating. The swap must carry `stepGas` for this step, or it reverts, so a low-gas swap can't skip it.

**Orchestration.** After every swap, the hook runs one bounded step: the next due (book, token) is re-laid if `interval` has passed, or the book's quote mix if that entry is the quote mix. A failed step is skipped and never reverts the swap. Anyone can also call `rebalance(book, token)` or `rebalanceQuotes(book)`.

## Parameters at deploy

| | |
|---|---|
| tau (smoothing) | 600 s |
| horizon (sigma) | 3600 s |
| feePerVol | 20 pips per tick of sigma |
| widthMult | 3.00 x sigma |
| min / max width | 600 / 60000 ticks |
| maxDev | 2000 ticks |
| minVol / initVol | 50 / 1000 ticks |
| interval | 900 s |
| quoteDriftBps / maxSlipBps | 1000 / 100 |
| shieldMax / stepGas | 16 / 8,000,000 |

The owner can change parameters, the beneficiary and sink share, the Pons factory allowlist, references for non-Pons tokens, and the pricing pool of an already-listed quote. Anyone can list a new quote.

## Known limits

- A hook only counts references on its own pools. It can't toll hookless pools or other venues on the same token.
- Reverted calls are not counted. The EIP's client-level version counts them; a contract can't.
- A swap shields at most `shieldMax` books in its pool. Without a cap, someone could spam books until a swap exceeds the transaction gas limit.
- Swaps into pools with books need at least `stepGas + 150k` gas available. Used gas is far lower when nothing has to move.
- Outside LPs pay the ratchet on adds and removes. Interfaces that size amounts exactly, such as Uniswap's UI at low slippage, revert.
- Fee-on-transfer tokens are not supported as deposits.

## Build, test, deploy

```bash
git clone --recurse-submodules https://github.com/staccDOTsol/stacc-ladder && cd stacc-ladder
forge test            # fork tests against Robinhood mainnet: the real ZERO curve, USDG and PoolManager
KEY_FILE=path/to/key DRY=1 ./deploy.sh   # estimate only
KEY_FILE=path/to/key ./deploy.sh         # deploy + configure (idempotent)
NEW_TOKEN=0x... KEY_FILE=path/to/key ./e2e.sh   # list a Pons launch, open its family, set a book, deposit, lay it
```

Among other things, the fork tests:
- push a real Pons curve through graduation and seeding, then check that the reference switches on its own;
- check the ratchet at 0 / 40 / 90 bp for the 1st, 2nd and 3rd reference in a block;
- check that a same-block JIT add/remove pays k=3;
- check that the shield moves an ask behind a curve pump;
- check that a low-gas swap cannot skip the shield.

## License

MIT for this repository's sources. Uniswap v4-core is a git submodule under its own license.
