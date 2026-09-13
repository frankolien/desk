# Desk

A perpetuals trading app for Monad where the trading key is your face.

Sign in with Face ID, fund a trading account, trade perpetuals, and never hold a key,
write a phrase, or connect a wallet. One passkey derives the wallet that funds the
account and the key that signs every trade, both on demand, neither stored.

Built for Monad Metropolis, September to October 2026, against Agora's Best Mobile
Trading App on Monad bounty. Native Swift and SwiftUI, iOS 18 and up.

| Ingredient | Role |
|---|---|
| [Mera](https://mera.category.xyz) | The only credential. Derives both keys from a passkey's PRF output. |
| AUSD | The collateral, and the only balance the app shows. |
| [Perpl](https://perpl.xyz) | The exchange: the account, the book, the position. |

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

Specified, and code begins 12 September 2026. The bounty closes 14 October 2026 at
04:59 GMT+1, which is thirty-two days.

Both blocking unknowns are closed. Testnet AUSD went on 11 September with Agora's
faucet; native PRF went on 12 September, confirmed against Apple's own SDK from iOS
18.0, and ship-gated at 18.4 because 18.0 to 18.3 return wrong values. What is owed
today is an Apple Developer account check, whose lead time is longer than this
schedule's slack. See `docs/05-milestones.md`.

## Its sibling

`../recourse` holds Recourse, a USDC money app on Arc, and Olien, the treasury
protocol behind it. Olien on Monad is the other Metropolis entry; the two now run in
parallel rather than one behind the other. About half of this app's spine is ported
from there, listed file by file in the technical spec, and the same passkey that trades
here can be a signer on an Olien treasury, which is the stretch at the end of the
product document.
