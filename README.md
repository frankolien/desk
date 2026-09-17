# Desk

A perpetuals trading app for Monad where the trading key is your face.

Sign in with Face ID, fund a trading account, trade perpetuals, and never hold a key,
write a phrase, or connect a wallet. One passkey derives the wallet that funds the
account and the key that signs every trade, both on demand, neither stored.

And copy the traders who are winning on Perpl: automatically, in shadow or live, with
your own limits, in the block they moved in.

Built for Monad Metropolis, September to October 2026, against Agora's Best Mobile
Trading App on Monad bounty and Perpl's Best Use of Perpl's API. Native Swift and
SwiftUI, iOS 18.4 and up.

| Ingredient | Role |
|---|---|
| [Mera](https://mera.category.xyz) | The only credential. Derives both keys from a passkey's PRF output. |
| AUSD | The collateral, and the only balance the app shows. |
| [Perpl](https://perpl.xyz) | The exchange: the account, the book, the position. |

## What it does

- **Trade perps on Perpl** with a passkey-derived key: market and limit orders signed on
  the device, tracked to a terminal phase, deadline-bound to the head block.
- **Follow traders read off-chain-free**, straight from Perpl's exchange contract: a
  leaderboard, profiles, trade history indexed from position events, and a score built on
  win rate, profit factor and drawdown, weighted by the money actually at risk.
- **Auto-copy** them, or fade them. Shadow or live, conviction sizing, leverage caps,
  price-protected entries, stops placed on Perpl itself, daily loss limits, per-market
  exposure caps, and baskets of the leaderboard's best.
- **Hear about it** through push alerts with Copy, View and Mute buttons; an Auto-Copy
  widget; a Live Activity in the Dynamic Island; a Control Center toggle; and Siri.

The submission write-up, covering both bounties, is [`docs/submission.md`](docs/submission.md);
the demo video script is [`docs/demo-video.md`](docs/demo-video.md).

## Documents

- [`docs/00-prd.md`](docs/00-prd.md): what it is, who it is for, the five screens and
  the criteria that say each one is finished.
- [`docs/01-technical-spec.md`](docs/01-technical-spec.md): how it is built, the Perpl
  protocol in detail, the key derivation, the session model, the tests and the build
  order.
- [`docs/02-system-design.md`](docs/02-system-design.md): the feature set, the corrected
  opening sequence, who owns which fact, and the socket and chain rules.
- [`docs/03-screen-designs.md`](docs/03-screen-designs.md): the design language and the
  five screens, drawn, with their states and their copy.
- [`docs/04-algorithms.md`](docs/04-algorithms.md): every formula, with the trap beside
  it. Scaling, margin, liquidation, funding, fees, gas, rounding.
- [`docs/05-milestones.md`](docs/05-milestones.md): the schedule, the cut line and the
  risks. Supersedes the build order in the technical spec.
- [`reference/perpl/`](reference/perpl/): the Node scripts that proved Perpl's
  authentication against the live testnet, and what it established. This stays the
  reference implementation; when the Swift and the script disagree, the script is
  right until proven otherwise. `eip712-vectors.mjs` and `tx-vectors.mjs` generate the
  viem cross-checks that the EIP-712 encoder and the transaction encoder are pinned to.

## Status

Built and running. 467 Swift tests (`swift test --package-path DeskKit`) and 64 server
tests (`cd web && node --test`) pass. The alerts pipeline, the trader history indexer and
the twelve Vercel functions are deployed; auto-copy, the widget, the Live Activity and the
Siri intents are in the app.

The bounty closes 14 October 2026 at 04:59 GMT+1. What is left is device verification of
push delivery and live fills, and the demo video.

## Its sibling

`../recourse` holds Recourse, a USDC money app on Arc, and Olien, the treasury
protocol behind it. Olien on Monad is the other Metropolis entry; the two now run in
parallel rather than one behind the other. About half of this app's spine is ported
from there, listed file by file in the technical spec, and the same passkey that trades
here can be a signer on an Olien treasury, which is the stretch at the end of the
product document.
