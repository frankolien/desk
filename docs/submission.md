# Desk — Monad Metropolis submission

**Desk is a native iOS perpetuals app for Monad where your face is the trading key, and
where you can copy the traders who are actually winning on Perpl — automatically, in
shadow or live, with your own limits.**

Sign in with Face ID. No seed phrase, no wallet connect, no extension. One passkey derives
both the wallet that funds the account and the key that signs orders. The wallet key that
moves your AUSD is never stored. The order key, which can't withdraw, is sealed to your
Face ID on this iPhone.

- Platform: native Swift 6 / SwiftUI, iOS 18.4+, iPhone.
- Chain: Monad. Exchange: Perpl. Collateral: AUSD. Credential: Mera passkeys.
- Repository: this repo. Server: 11 Vercel functions in [`web/`](../web).
- Tests: 535 Swift tests in 86 suites (`swift test --package-path DeskKit`, ~0.3 s once
  built, no simulator) and 213 Node tests (`cd web && node --test`).

---

## 1. Agora — Best Mobile Trading App on Monad

### What makes it a mobile app rather than a website in a shell

- **The phone is the wallet.** The passkey's PRF output derives the EOA and the Perpl
  signing key. The wallet key that moves AUSD is derived again for each transaction and
  never stored. The order key can place and close orders but cannot withdraw. It is sealed
  in the keychain with `biometryCurrentSet` and `WhenPasscodeSetThisDeviceOnly`, so only
  this iPhone's current Face ID enrolment opens it. It leaves memory when you lock Desk
  and when the phone locks with Desk open. In the background iOS suspends Desk, so after
  five minutes away (twelve hours if away copying is on) the key can't be used, and it is
  wiped the moment Desk returns, before anything can use it. Losing the phone and its
  iCloud backup means the funds are gone, and the app says so in those words during
  onboarding.
- **Apple's own controls.** `TabView`, `Picker`, `Toggle`, `Menu`,
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

Four tabs.

| Tab | What it does |
|---|---|
| Home | Perpl's markets, and Hot Markets: how many traders hold each busy market and which way they lean; each market's chart and the ticket, with leverage and hold-to-confirm |
| Search | Perpl's markets, and wallets by address or name |
| Signals | Following and Top traders; trader profiles, scores and copy rules; the Auto-Copy hub with its result, open copies, history and limits |
| Profile | The AUSD balance, open and closed positions, Add funds, Withdraw, activity, and Settings with the network switch |

### Beyond the app itself

Push alerts for the traders you follow, with **Copy Trade**, **View Trader** and **Mute This
Trader** on the notification (Copy Trade asks for Face ID and opens Desk on a filled-in
ticket); an Auto-Copy widget with a working pause button; a Live
Activity that shows today's copy result in the Dynamic Island; and Siri phrases
("Pause auto-copy in Desk", "How is my copy trading in Desk").

---

## 2. Perpl — Best use of Perpl's API

Desk uses Perpl three ways: as a venue it trades on, as a data source it reads other
people's books from, and as an event stream it reacts to as soon as a trade's block lands.

### Execution

- Orders are signed on the device with the passkey-derived key and sent over Perpl's
  websocket, tracked frame by frame to a terminal phase (settled, rejected with a reason,
  or expired). Rejection reasons are translated into sentences, never codes.
- A market order goes out immediate-or-cancel with a slippage limit, so Perpl fills it at
  once within that limit or not at all. Orders carry `lb: 0`, as Perpl's own client does.
  Desk's deadline is a local timeout only: past it, the ticket says Perpl has not confirmed
  the order yet and asks you to check your positions, because the answer may still come.
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
| Price protection | A copy is skipped if the market has already moved past your limit from their entry, and what is left of the limit becomes the order's slippage bound on Perpl |
| Stop / take profit | Percent of margin, converted to a price and placed on the venue |
| Open copies | Maximum open at once |
| Daily loss limit | Auto-copy pauses itself when today's closed copies hit it |
| Exposure per market | Caps what all copies hold on one side of one market, so two traders long BTC do not double your risk |
| Offset guard | A copy that would cancel one you already hold is skipped, not sent |

### Profitability, measured rather than claimed

Every copy records the time from when Desk saw the move to the fill, and, for live copies,
the fill's slippage in basis points against the mark the copy was sized at. The Auto-Copy
screen shows realised PnL, win rate, copies and average time to fill, split between shadow
and live. Shadow mode exists so a strategy can be proven before any money moves.

### Real on-chain activity

- Positions are read from the Perpl exchange contract `0x34B6552d…12a6F` on Monad mainnet:
  the account, its position bitmap, and each open position row with its mark.
- A websocket subscription on `wss://rpc.monad.xyz` watches that contract's position
  events — `OpenedV2`, `IncreasedV2`, `Decreased`, `Closed`, `Liquidated`. An event naming
  a copied trader's account wakes the copy loop at once, as soon as the trader's block lands,
  not on the next poll. A poll runs underneath: every 15 seconds while the stream is up,
  every 4 when it is down.
- Trader history and scores are indexed from those same events through Envio HyperSync,
  sharded per account, with a resumable cursor.

### The trader score

Traders are scored out of 100: 45% win rate, 35% profit factor (capped at 3), 20%
freedom from drawdown, multiplied by a confidence factor for the number of trades, the
money at risk and whether they trade more than one market, minus a liquidation penalty. Dust scalpers with a 90% win rate on
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
web/api/           11 Vercel functions: market data, faucet, swaps, traders, alerts
```

**No server can trade for anyone.** The server pushes notifications, reads public chain
data and indexes history. It never holds a user's key. The order key is sealed to Face ID
on the phone and signs only while Desk has it unlocked. That is the trade-off behind
"copying runs while Desk has its key", and it is deliberate.

**Secrets** live only in the server's environment, on Vercel and on the Railway worker: the
APNs key, the cron secret, the indexer token, the data-service keys and the testnet faucet
key. Nothing sensitive ships in the app binary.

---

## 4. What is real, and what is not

Being explicit, because judges should not have to guess:

- Real: passkey derivation, order signing, Perpl reads and writes, the position event
  stream, trader history and scores indexed from mainnet events, push delivery through
  APNs, the copy engine and all its guards.
- Simulated by design: shadow copies. They fill at the real mainnet mark and pay real taker
  fees in the arithmetic, but send nothing.
- Requires the app: live copying, because the signing key is never on a server. It runs
  while Desk is open, or in the background with away copying on, until iOS closes the app.
- Live fills so far: the only recorded one is on testnet, a 0.06518 BTC long placed from
  the app on Perpl testnet on 15 September 2026, documented in
  [`perpl-order-400-audit-2026-09-15.md`](perpl-order-400-audit-2026-09-15.md).
- Mainnet fills: *(add dated explorer links after the founder's mainnet run)*

---

## 5. Links

- Demo video: *(add link)*
- Site: `https://trydesk.trade`
- Server: `https://web-lovat-nine-49.vercel.app`
- Exchange contract: `0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` (Monad)
- Build: `xcodegen generate && open Desk.xcodeproj`, scheme **Desk**, iOS 18.4+
