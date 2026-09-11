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
- [`reference/perpl/`](reference/perpl/): the Node script that proved Perpl's
  authentication against the live testnet, and what it established. This stays the
  reference implementation; when the Swift and the script disagree, the script is
  right until proven otherwise.

## Status

Specified, not started. Code begins 17 September 2026, after Arc mainnet week on the
sibling project.

Two unknowns are owed before then and are written up at the end of the technical spec:
whether iOS returns PRF output on a real device, and where testnet AUSD comes from.

## Its sibling

`../recourse` holds Recourse, a USDC money app on Arc, and Olien, the treasury
protocol behind it. Olien on Monad is the primary Metropolis entry; this is the
second. About half of this app's spine is ported from there, listed file by file in
the technical spec, and the same passkey that trades here can be a signer on an Olien
treasury, which is the stretch at the end of the product document.
