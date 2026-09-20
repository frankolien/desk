# Desk

**Trade perps on Monad with your face.**

A native iPhone app for perpetual futures on [Perpl](https://perpl.xyz), where Face ID is
the trading key. Sign in and a passkey derives both the wallet that holds the collateral
and the key that signs every order — on demand, in memory, never stored. No seed phrase,
no wallet app, no extension.

And copy the traders who are actually winning: read straight off Perpl's exchange
contract, copied in the block they move in, measured on every fill.

Site: [trydesk.trade](https://trydesk.trade). App Store name: *Desk: Trade Perps on Monad*.
On TestFlight (testnet build).

Built for Monad Metropolis, September–October 2026: Agora's *Best Mobile Trading App on
Monad* and Perpl's *Best Use of Perpl's API*. Swift 6, SwiftUI, iOS 18.4+, iPhone.

| Ingredient | Role |
|---|---|
| [Mera](https://mera.category.xyz) | The only credential. Both keys derive from a passkey's PRF output. |
| AUSD | The collateral, and the only balance the app shows. |
| [Perpl](https://perpl.xyz) | The exchange: the account, the book, the position, the event stream. |
| Monad | The chain. Position events wake the copy loop in the block they land in. |

## What it does

- **Trade perps** — market and limit orders signed on the device, sent over Perpl's
  websocket, tracked to a terminal phase, deadline-bound to the head block so a stale
  order cannot fill late. Hold to confirm. Every figure rounds the way that costs you.
- **See which way the crowd leans** — every open position on every market summed live:
  long against short, traders on each side, the biggest single position in the book, and
  a floor note when the book could not be read in full.
- **Follow the traders worth following** — a leaderboard read from the exchange
  contract, trade history indexed from the chain's own position events through Envio
  HyperSync, and a score built on win rate, profit factor and drawdown, weighted by the
  money actually at risk.
- **Copy them, or fade them** — shadow or live, fixed or conviction sizing, a leverage
  cap, price-protected entries, stops placed on Perpl itself, daily loss limits,
  per-market exposure caps, and baskets of the leaderboard's best.
- **Know the moment they trade** — push alerts with *Copy Trade*, *View* and *Mute* on
  the notification; the ticket opens already filled in.
- **It doesn't leave the phone** — Portfolio, Watchlist and Auto-Copy widgets; a Live
  Activity with a working pause in the Dynamic Island; a Control Center toggle; Siri.
- **Spot, too** — trending tokens with a live chart, transactions, holders and the order
  book, with a buy on the ones you can hold.
- **Share the result** — a position card over your own photo, with a code that opens Desk.

## Security, in one paragraph

No server can trade for anyone, including ours. The signing key exists only in the app's
memory, only while it is open and unlocked; it is wiped on lock and after a short grace
period in the background. The server pushes notifications and reads public chain data —
nothing it holds could move money, which is why live copying needs Desk open, and why
that is a deliberate trade rather than a shortcut. An unreadable position book is never
treated as an empty one, because that would announce closes that never happened.

## Layout

```
App/Desk            the app: screens, models, the copy engine, alerts, glance publishers
App/DeskWidgets     Portfolio, Watchlist and Auto-Copy widgets, the Live Activity, the control
App/Shared          what the app and the widgets both compile: glances, marks, widget views
DeskKit/            the Swift package — money, chain, auth, Perpl protocol, flow, UI
  Sources/DeskPerpl   REST and websocket clients, orders, positions, figures, the position book
  Sources/DeskChain   Monad RPC, EIP-712, transactions, pinned to viem vectors
  Sources/DeskAuth    passkeys, PRF derivation, the signing session
web/                the Vercel project: the landing page and twelve functions
  api/                traders, crowd, history, alerts, faucet, fx, market stream, relay, spot
  public/             the site — flat colour cards, product recordings, live figures
  tools/serve.mjs     local server with /api proxied to production
docs/               PRD, technical spec, system design, screens, algorithms, submission
tools/              testflight.sh, ExportOptions.plist, check-relying-party.sh
```

## Running it

```sh
xcodegen generate && open Desk.xcodeproj      # project.yml is the source of truth
swift test --package-path DeskKit             # 481 tests in 74 suites, ~0.3 s, no simulator
cd web && node --test                         # 76 server tests
node web/tools/serve.mjs                      # the site on :8790 with the live API
tools/testflight.sh                           # archive, export, upload to App Store Connect
```

The simulator uses a stub passkey (a fixed key, a fixed dev wallet); real derivation
happens only on hardware. Debug launch arguments open any screen directly — `-stage
home|market|signals|fund|empty|welcome`, plus `-copy-demo`, `-crowd-demo`,
`-copy-activity`, `-widget-gallery` — so every screen can be captured without walking
the flow.

Secrets live only in Vercel's environment. Nothing in the app can reach them, by
construction: the app has no server credential to leak.

## Documents

- [`docs/submission.md`](docs/submission.md) — the submission write-up, both bounties.
- [`docs/00-prd.md`](docs/00-prd.md) — what it is, who it is for, and what finished means.
- [`docs/01-technical-spec.md`](docs/01-technical-spec.md) — how it is built: the Perpl
  protocol, key derivation, the session model, the tests.
- [`docs/02-system-design.md`](docs/02-system-design.md) — who owns which fact; the
  socket and chain rules.
- [`docs/03-screen-designs.md`](docs/03-screen-designs.md) — the design language and the
  screens.
- [`docs/04-algorithms.md`](docs/04-algorithms.md) — every formula with the trap beside it.
- [`docs/demo-video.md`](docs/demo-video.md) — the demo script.
- [`reference/perpl/`](reference/perpl/) — the Node scripts that proved Perpl's
  authentication against the live testnet. When the Swift and the script disagree, the
  script is right until proven otherwise.

## Status

Shipped to TestFlight on a testnet build. 481 Swift tests and 76 server tests pass. The
site, the alerts pipeline, the history indexer and the twelve functions are deployed.

The bounty closes 14 October 2026 at 04:59 GMT+1. Left: the demo video, mainnet
verification of a live fill, and the public TestFlight link on the site.
