# Desk

**Trade perps on Monad with your face.**

A native iPhone app for perpetual futures on [Perpl](https://perpl.xyz), where Face ID is
the trading key. Sign in and a passkey derives both the wallet that holds the collateral
and the key that signs your orders. The wallet key that moves your AUSD is never stored.
The order key, which can't withdraw, is sealed to your Face ID on this iPhone. No seed
phrase, no wallet app, no extension.

And copy the traders who are actually winning: read straight off Perpl's exchange
contract, copied as soon as their trade lands on the chain, measured on every fill.

Site: [trydesk.trade](https://trydesk.trade). App Store name: *Desk: Trade Perps on Monad*.
On TestFlight (testnet build).

Built for Monad Metropolis, September–October 2026: Agora's *Best Mobile Trading App on
Monad* and Perpl's *Best Use of Perpl's API*. Swift 6, SwiftUI, iOS 18.4+, iPhone.

| Ingredient | Role |
|---|---|
| [Mera](https://mera.category.xyz) | The only credential. Both keys derive from a passkey's PRF output. |
| AUSD | The collateral, and the only balance the app shows. |
| [Perpl](https://perpl.xyz) | The exchange: the account, the book, the position, the event stream. |
| Monad | The chain. Position events wake the copy loop as soon as their block lands. |

## What it does

- **Trade perps** — market orders signed on the device, sent over Perpl's
  websocket and tracked to a terminal phase. A market order is immediate-or-cancel within
  its slippage limit, so it fills at once or not at all. Hold to confirm. Every figure
  rounds the way that costs you.
- **See which way the crowd leans** — Hot Markets on Home adds up every open position on
  the busiest markets, live: how much is open, how many traders hold it, and which way
  they lean.
- **Follow the traders worth following** — a leaderboard read from the exchange
  contract, trade history indexed from the chain's own position events through Envio
  HyperSync, and a score built on win rate, profit factor and drawdown, weighted by the
  money actually at risk.
- **Copy them, or fade them** — shadow or live, fixed or conviction sizing, a leverage
  cap, price-protected entries, stops placed on Perpl itself, daily loss limits,
  per-market exposure caps, and baskets of the leaderboard's best.
- **Know the moment they trade** — push alerts with *Copy Trade*, *View Trader* and *Mute
  This Trader* on the notification; Copy Trade opens the ticket already filled in.
- **It doesn't leave the phone** — Portfolio, Watchlist and Auto-Copy widgets; a Live
  Activity with a working pause in the Dynamic Island; a Control Center toggle; Siri.
- **Share the result** — a position card over your own photo, with a code that opens Desk.
- **Trade tokens too** — Trending coins on Search, across Monad and the EVM chains Relay
  reaches, bought with MON from the same key; token pages with holders, trades, who got in
  first, and a risk card. EVM only: Solana is not offered anywhere.
- **Deposit with Apple Pay or a card** — through Crossmint's sheet inside the app, with the
  passkey wallet as the recipient; Desk never sees the card. Live once Crossmint enables Monad
  for Desk; until then it runs in their staging.
- **MON to AUSD and back** — the dollars for the desk from spare MON, and MON for gas
  and tokens from AUSD, in one sheet with a switch; checked on Monad before Face ID signs,
  approving at most the amount typed.
- **Follow wallets, not only traders** — a wallet's token moves and its perps on Perpl in
  one feed, with alerts, and a Watchlist and Market view on Signals.
- **Talk in the market, read the news** — a chat room per market, and headlines that
  mention a market. A story opens as a page inside Desk, never in Safari.
- **Trade from a browser too** — [trydesk.trade/app](https://trydesk.trade/app) signs in
  with the same passkey, derives the same keys in the tab, shows the live book and your
  positions beside the chart, and places and closes orders through a relay that forwards
  your signed requests and cannot sign. Locked when you leave; nothing is stored.
- **Follow and hear it in the browser too** — Follow a trader anywhere on the web app and
  turn on alerts: the same scan that pushes to the phone pushes to the browser, tab closed
  or not, through its own push service.

## Security, in one paragraph

No server can trade for anyone, including ours. The wallet key that moves AUSD is derived
from the passkey for each transaction and never stored. The order key can place and close
orders but cannot withdraw. It is sealed in the keychain so only this iPhone's current
Face ID enrolment opens it. It leaves memory when you lock Desk and when the phone locks
with Desk open. In the background iOS suspends Desk, so after five minutes away (twelve
hours with away copying on) the key can't be used, and it is wiped the moment Desk returns,
before anything can use it. The server pushes notifications and reads public chain data.
Nothing it holds could move your money, which is why live copying needs Desk and its key,
and why that is a deliberate trade rather than a shortcut. An unreadable position book is
never treated as an empty one, because that would announce closes that never happened.

## Layout

```
App/Desk            the app: screens, models, the copy engine, alerts, glance publishers
App/DeskWidgets     Portfolio, Watchlist and Auto-Copy widgets, the Live Activity, the control
App/Shared          what the app and the widgets both compile: glances, marks, widget views
DeskKit/            the Swift package — money, chain, auth, Perpl protocol, flow, UI
  Sources/DeskPerpl   REST and websocket clients, orders, positions, figures, the position book
  Sources/DeskChain   Monad RPC, EIP-712, transactions, pinned to viem vectors
  Sources/DeskAuth    passkeys, PRF derivation, the signing session
web/                the Vercel project: the landing page and eleven functions
  api/                traders, crowd, history, alerts, faucet, fx, relay, spot
  public/             the site — flat colour cards, product recordings, live figures
  tools/serve.mjs     local server with /api proxied to production
docs/               PRD, technical spec, system design, screens, algorithms, submission
tools/              testflight.sh, ExportOptions.plist, check-relying-party.sh
```

## Running it

```sh
xcodegen generate && open Desk.xcodeproj      # project.yml is the source of truth
swift test --package-path DeskKit             # 535 tests in 86 suites, ~0.3 s, no simulator
cd web && node --test                         # 213 server tests
node web/tools/serve.mjs                      # the site on :8790 with the live API
tools/testflight.sh                           # archive, export, upload to App Store Connect
```

The simulator uses a stub passkey (a fixed key, a fixed dev wallet); real derivation
happens only on hardware. Debug launch arguments open any screen directly — `-stage
home|market|signals|fund|empty|welcome`, plus `-copy-demo`, `-crowd-demo`,
`-copy-activity`, `-widget-gallery` — so every screen can be captured without walking
the flow.

Secrets live only in the server's environment, on Vercel and on the Railway worker. Nothing
in the app can reach them, by construction: the app has no server credential to leak.

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

Shipped to TestFlight on a testnet build. 535 Swift tests and 213 server tests pass. The
site, the alerts pipeline, the history indexer and the eleven functions are deployed.

The only recorded live fill so far is on testnet: a 0.06518 BTC long on 15 September 2026,
in [`docs/perpl-order-400-audit-2026-09-15.md`](docs/perpl-order-400-audit-2026-09-15.md).

The bounty closes 14 October 2026 at 04:59 GMT+1. Left: the demo video and a dated live
fill on mainnet.
