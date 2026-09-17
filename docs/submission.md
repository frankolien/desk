# Desk — Monad Metropolis submission

**Desk is a native iOS perpetuals app for Monad where your face is the trading key, and
where you can copy the traders who are actually winning on Perpl — automatically, in
shadow or live, with your own limits.**

Sign in with Face ID. No seed phrase, no wallet connect, no extension. One passkey derives
both the wallet that funds the account and the key that signs every order, on demand, and
neither is ever stored.

- Platform: native Swift 6 / SwiftUI, iOS 18.4+, iPhone.
- Chain: Monad. Exchange: Perpl. Collateral: AUSD. Credential: Mera passkeys.
- Repository: this repo. Server: 12 Vercel functions in [`web/`](../web).
- Tests: 467 Swift tests (`swift test --package-path DeskKit`, ~0.3 s, no simulator) and
  64 Node tests (`cd web && node --test`).

---

## 1. Agora — Best Mobile Trading App on Monad

### What makes it a mobile app rather than a website in a shell

- **The phone is the wallet.** The passkey's PRF output derives the EOA and the Perpl
  signing key. Face ID is not a lock screen over a stored key; there is no stored key.
  Losing the phone and its iCloud backup means the funds are gone, and the app says so in
  those words during onboarding.
- **Every control is Apple's.** `TabView`, `Picker`, `Stepper`, `Toggle`,
  `ContentUnavailableView`, context menus, sheets with detents. On iOS 26 the surfaces are
  Liquid Glass; older versions get the material equivalent. Dark only, because a trading
  app on a near-black ground has no light mode worth testing.
- **It uses what only a phone has:** push notifications with actions, a Home and Lock
  Screen widget, a Live Activity with the Dynamic Island, a Control Center toggle, Siri
  phrases, haptics, and hold-to-confirm on every order.
- **Hostile-network honesty.** Every figure that cannot be read says so instead of showing
  a stale number or a zero. An unreadable position book is never treated as an empty one,
  because that would announce closes that did not happen.

### The screens

| Screen | What it does |
|---|---|
| Home | Balance, collateral, funding, network switch, activity |
| Perps | Market, chart, ticket with leverage and hold-to-confirm |
| Signals | Leaderboard of Perpl traders, trader profiles, scores, copy controls |
| Auto-Copy | The copy engine: result, traders, open copies, history, limits |
| Search / Watchlist | Markets and tokens |

### Beyond the app itself

Push alerts for the traders you follow, with **Copy Trade**, **View Trader** and **Mute**
buttons on the notification; an Auto-Copy widget with a working pause button; a Live
Activity that shows today's copy result in the Dynamic Island; and Siri phrases
("Pause auto-copy in Desk", "How is my copy trading in Desk").

---

## 2. Perpl — Best use of Perpl's API

Desk uses Perpl three ways: as a venue it trades on, as a data source it reads other
people's books from, and as an event stream it reacts to in the block the trade lands in.

### Execution

- Orders are signed on the device with the passkey-derived key and sent over Perpl's
  websocket, tracked frame by frame to a terminal phase (settled, rejected with a reason,
  or expired). Rejection reasons are translated into sentences, never codes.
- Every order is deadline-bound to the head block Desk already receives on the context
  call, so a stale order cannot fill late.
- Stops and take profits for live copies are placed **on Perpl**, not in the app, so a
  copy stays protected after Desk is closed. This is the difference between a toy copy bot
  and one you can leave.

### Risk management

Rules are per trader; guards are account-wide:

| Control | Behaviour |
|---|---|
| Mode | Shadow (simulated at the real mainnet mark, with taker fees both ways) or live |
| Direction | Follow or **fade** — take the opposite side of a trader you think is wrong |
| Sizing | Fixed margin, or **conviction**: scaled by how much of their own account they put in |
| Leverage cap | Their leverage, capped by yours |
| Price protection | A copy is skipped if the market has already moved past your limit from their entry, and the order can never fill beyond it |
| Stop / take profit | Percent of margin, converted to a price and placed on the venue |
| Open copies | Maximum open at once |
| Daily loss limit | Auto-copy pauses itself when today's closed copies hit it |
| Exposure per market | Caps what all copies hold on one side of one market, so two traders long BTC do not double your risk |
| Offset guard | A copy that would cancel one you already hold is skipped, not sent |

### Profitability, measured rather than claimed

Every copy records the time from the trader's move to the fill, and the slippage against
their entry in basis points. The Auto-Copy screen shows realised PnL, win rate, copies and
average time to fill, split between shadow and live. Shadow mode exists so a strategy can
be proven before any money moves.

### Real on-chain activity

- Positions are read from the Perpl exchange contract `0x34B6552d…12a6F` on Monad mainnet:
  the account, its position bitmap, and each open position row with its mark.
- A websocket subscription on `wss://rpc.monad.xyz` watches that contract's position
  events — `OpenedV2`, `IncreasedV2`, `Decreased`, `Closed`, `Liquidated`. An event naming
  a copied trader's account wakes the copy loop at once, so a copy follows in the block the
  trader moved in, with a 4-second poll underneath as the fallback.
- Trader history and scores are indexed from those same events through Envio HyperSync,
  sharded per account, with a resumable cursor.

### The trader score

Traders are ranked on what survives: 45% win rate, 35% profit factor (capped at 3), 20%
freedom from drawdown, multiplied by a confidence factor for both the number of trades and
the money at risk, minus a liquidation penalty. Dust scalpers with a 90% win rate on
$3 positions do not outrank real traders — that confidence factor exists because an early
version of the score put one at the top.

### Baskets

Copy the leaderboard as a portfolio: the top N by indexed score, re-picked on a schedule,
all under one set of rules.

---

## 3. How it is built

```
App/Desk/          the iOS app: screens, components, copy engine, alerts, publisher
App/DeskWidgets/   widget, Live Activity, Control Center toggle
App/Shared/        App Group state and App Intents, compiled into both
DeskKit/           local Swift package, seven targets with load-bearing boundaries:
                   DeskMoney (arithmetic, no network by construction), DeskNet,
                   DeskAuth, DeskChain, DeskPerpl, DeskFlow, DeskUI
web/api/           12 Vercel functions: market data, faucet, swaps, traders, alerts
```

**No server can trade for anyone.** The server pushes notifications, reads public chain
data and indexes history. The signing key exists only in the app's memory, only while it
is open and unlocked. That is the trade-off behind "copying runs while Desk is open", and
it is deliberate.

**Secrets** live only in Vercel's environment: the APNs key, the cron secret, the indexer
token. Nothing sensitive ships in the app binary.

---

## 4. What is real, and what is not

Being explicit, because judges should not have to guess:

- Real: passkey derivation, order signing, Perpl reads and writes, the position event
  stream, trader history and scores indexed from mainnet events, push delivery through
  APNs, the copy engine and all its guards.
- Simulated by design: shadow copies. They fill at the real mainnet mark and pay real taker
  fees in the arithmetic, but send nothing.
- Requires the app to be open: live copying, because the signing key is never on a server.

---

## 5. Links

- Demo video: *(add link)*
- Server: `https://web-lovat-nine-49.vercel.app`
- Exchange contract: `0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` (Monad)
- Build: `xcodegen generate && open Desk.xcodeproj`, scheme **Desk**, iOS 18.4+
