# Demo video: script and shot list

The form caps the technical demo at **three minutes** and Agora's bounty video at **two**.
The script below is the master shot list, about four and a half minutes of material; record it
all, then cut twice as the *Cuts* section says. Screen recording from a real iPhone on **Monad
mainnet**, plus one screen recording from a Mac for the browser segment, voice-over recorded
afterwards. You start signed in, with your desk already funded: the video introduces Desk,
shows your balance and explains how a new person funds and opens a desk, then trades, closes,
follows and copies, follows a wallet off a token's tape, swaps AUSD back to MON, reads the market,
opens the same desk in a browser, and withdraws. Every amount is real, and the recording doubles
as the proof that Desk works on mainnet.

## Cuts

**Technical demo, under 3:00.** Introduction 0:20 · Your balance 0:25 · Place a trade 0:30 ·
Manage and close 0:25 · Follow and copy, trimmed to the sheet, Follow and the hub card 0:25 ·
Tokens and the wallet behind a buy, trimmed to the tape, Follow and the alert line 0:20 · The
browser, trimmed to the sign-in, the AUSD in the desk, the book and the drawer 0:25 · Take the
money out 0:10. Leave out the swap back, Read the room and the live alert; if the cut lands under
2:50, the swap's SWAPPED receipt fits as a five-second insert after the tokens.

**Agora bounty video, under 2:00.** It must show a passkey sign-in, an AUSD balance being funded
or viewed, and a trade on Perpl. The cut sheet, clip by clip, with the voice-over trimmed to fit
(about 185 words, which speaks in 1:15, so there is room to breathe):

| Time | Clip | Voice-over |
|---|---|---|
| 0:00–0:10 | Pickup: lock Desk in Settings, sign out, record the Welcome screen, Face ID, Home with your balance | "This is Desk, a native iPhone app for perps on Monad. Face ID is the account: a Mera passkey derives the wallet and the key that signs orders. No seed phrase." |
| 0:10–0:30 | Profile with the AUSD balance; Add funds; Receive; the swap row; close | "My balance, in AUSD, the only money you see. Add funds gives you an address, or swaps MON you already hold, both ways. Open desk sets up your Perpl account under one Face ID." |
| 0:30–1:00 | BTC, Long, 50 at 5x, the ticket, hold, Face ID, Filled. Keep hold to Filled unbroken | "Long Bitcoin, fifty AUSD at five times. The ticket shows margin, liquidation, fee, and the price Perpl's live book would fill me at. Hold. Face ID. Filled, on Monad mainnet, with real money." |
| 1:00–1:20 | The position, Close, MAX, hold, Position closed | "The position updates live. Closing is a checkout too: this is the AUSD I get back. Hold. Closed, exactly as Perpl reports it." |
| 1:20–1:40 | Mac: Safari, trydesk.trade/app, Sign in with your passkey, Touch ID, the portfolio with In trading and Wallet AUSD, then the book beside the chart | "The same passkey opens the same desk in a browser: same address, the AUSD in my desk right there, the live book beside the chart." |
| 1:40–1:55 | Withdraw, the step list, Face ID, the receipt, the explorer link | "And the money comes back out, with a receipt on Monad's explorer for every step. Perps on Monad, settled in AUSD, from your iPhone." |

Trimming the takes you already have: cut the home-screen scroll from the introduction, speed the
keypad typing to 2x or cut to the typed amount, and cut the waiting before Filled, but never cut
between the hold and Filled. Without the browser clip the cut lands at 1:35, which is fine.

**Pitch video, under 2:00.** Separate script in `pitch-video.md`; it reuses the Home and
leaderboard shots and otherwise is you talking.

**Perpl, best use of the API, under 2:00.** It must show the automation on Perpl with real on-chain
activity, so this is the only cut where one small live copy on camera is worth it: set one trader
to Live with fixed sizing at the minimum and a tight leverage cap just before the take, and call
it live. Signals > Top traders 0:10 · a trader's sheet, score and Follow 0:15 · Auto-Copy rules,
Live selected, price protection, the stop placed on Perpl 0:25 · the hub's result card with time
to fill and slippage 0:15 · the alert landing, Copy Trade, Face ID, filled 0:25 · the position on
the market page and its explorer receipt 0:15 · the Crowd view of the market, how many hold it
and which way 0:10. Voice: "Desk reads every trader off Perpl's exchange contract, scores them
on their record, and copies their moves the moment the trade lands on chain, under my rules. This
copy is live, on mainnet, with real money. Stops are placed on Perpl itself, so the copy stays
protected after Desk is closed. The hub measures every fill."

**Perpl, analytics and risk tool, under 2:00.** The dashboard is the web app, so this is a Mac
recording with the phone for the last shot. trydesk.trade/app Markets: open interest, funding,
the crowd lean per market 0:20 · one market: the live order book, the holders and which way they
lean 0:20 · Traders: the leaderboard, a trader in the drawer with open positions and the closed
history, the score 0:25 · a wallet page: holdings, realised PnL over 7 and 30 days, the trades,
the risk labels 0:25 · a token page: holders, the tape, bundlers and snipers, the risk card 0:15 ·
iPhone: Signals > Market, the long-against-short view of every market 0:15. Voice: "Protocol-level
and wallet-level in one place, all read from the exchange contract and Monad's own events: what
every market holds and which way it leans, who the traders are and how they really performed,
and what any wallet did. Every figure that cannot be read says so."

## Before recording

- **Mainnet.** Settings > Network > Monad mainnet > Use real funds. Say "mainnet" out loud; it is
  real money.
- **Money.** You're already signed in with a funded mainnet desk. Keep at least 60 AUSD in
  trading for the trade (50 AUSD at 5x is a comfortable size) and a little MON for fees.
- **Wallet AUSD for the swap back.** The swap back sells AUSD from the *wallet*, not from the desk.
  Keep 15–20 AUSD in the wallet (withdraw a little from trading beforehand if it is all in there)
  and about 0.05 MON, which pays the approval and the swap.
- **A token with a live tape.** On Search > Trending, pick a Monad token whose Trades tab moves,
  and note its name. The tokens segment and the swap segment both use it.
- **The build.** The TestFlight build archived on 7 October or later: it has the trader sheets,
  the Your desk sheet on the chart, the alert line on a followed wallet, the swap switch and the
  in-app news page.
- **Mac for the browser segment.** Safari on a Mac signed into the same iCloud account as the
  iPhone, so the passkey is there. Allow notifications for trydesk.trade when Safari asks; check
  System Settings > Notifications > Safari is on beforehand. One window at about 1280 wide,
  bookmarks bar hidden, recorded with Cmd-Shift-5. Open trydesk.trade/app and reload it right
  before the take, so the sign-in happens on camera. **Rehearse the browser order once off
  camera**: the web order path has been exercised end to end only with test accounts.
- **Deposit push (optional).** To show "You received", send yourself a small top-up of AUSD from
  another wallet during the session, with notifications and Deposit alerts on. If you skip it, drop
  the line that mentions it.
- **Face ID on the ticket.** It only shows when Desk is locked. Lock Desk in Settings right before
  the trade take. Never cut in a prompt from another take.
- **Copying.** Before the copy section, set one top trader to Auto-Copy in **Shadow**, so the hub
  has a result card. Never copy live on camera.
- **Alerts during the session.** Set `WORKER_SCAN_MS=60000` on Railway so a trade push lands within
  a minute. Set it back to `300000` afterwards.
- **Device.** Real iPhone, battery above 50%, strong Wi-Fi, brightness high, Do Not Disturb off,
  no other notifications pending. iOS screen recording (Control Center) captures the Dynamic
  Island. Record one take per section and cut later.

## The script

The first four sections are recorded. Their voice-over lines below carry two small additions
for the new features; the shots stand as they are, with one optional pickup.

### 0:00–0:20 · Introduction

**Shot:** the iPhone home screen. Tap Desk. Face ID unlocks it. Home with live prices moving and
the Hot Markets cards. A slow scroll down the markets.

> "This is Desk, a native iPhone app for trading perpetuals on Monad. Every trade runs on Perpl,
> AUSD is the only money you see, and Mera's passkeys turn Face ID into your key. No seed phrase,
> no wallet app. Everything you're about to see is on Monad mainnet, with real money. And at the
> end, the same account opens in a browser."

### 0:20–0:45 · Your balance, and how a new person gets started

**Shot:** Profile with your AUSD balance and what's in trading. Tap Add funds: Receive AUSD
opens the address and QR, and Swap MON for AUSD shows if you hold spare MON. Close the sheet.

> "I've already funded my desk, so this is my balance, in AUSD. If you're new, Add funds is where
> you start. Receive gives you an address to send AUSD to, from an exchange or any wallet, or you
> can swap MON you already hold, and later swap back the other way. Then Open desk sets up your
> Perpl account under one Face ID: it approves the AUSD, creates the account, deposits it, and adds
> the key that signs your orders."

*Optional, if you capture the top-up push:* "And Desk tells you the moment money lands."

### 0:45–1:15 · Place a trade

**Shot:** Home > BTC > Long. Type 50, set 5x. The ticket shows margin, liquidation, fee, total and
Est. fill. Hold. Face ID. "Forwarded", then the Filled receipt. Land on the position.

> "Let's go long Bitcoin with fifty AUSD at five times. Before I commit, the ticket shows my
> margin, where I'd be liquidated, the fee, and the price Perpl's live order book would fill me
> at. It reads like a checkout. Hold. Face ID. Filled, and that's my position."

### 1:15–1:40 · Manage and close it

**Shot:** Profile > the position: live PnL and distance to liquidation. Close > MAX. The checkout
shows the AUSD you get back. Hold. "Position closed" with the realised PnL.

> "The position updates live, with how far the price is from my liquidation. Closing is a
> checkout too: this is the AUSD I get back, after the fee. Hold. Closed, and that's my realised
> result, exactly as Perpl reports it."

*Optional pickup, five seconds, to splice before Close:* on the BTC chart, tap the briefcase in
the trade bar. **Your desk** slides up over the chart with the position; the **Your position**
strip sits under the chart. "My whole desk is a tap away on the chart. Nothing takes me off the
market."

### 1:40–2:15 · Follow and copy

**Shot:** Signals > Top traders.

> "These are real traders on Perpl mainnet, ranked live."

**Shot:** tap a trader with a high score and plenty of trades. The profile slides up as a sheet
over the list.

> "Each one is scored out of a hundred on their record: win rate, profit factor, drawdown, and how
> many trades it's based on. They open over the page, so I never lose my place."

**Shot:** tap Follow.

> "I follow them. Now when they open, add to, trim or close a position, Desk tells me."

**Shot:** Auto-Copy rules with Shadow selected, then the price protection row.

> "Then I copy them, in Shadow first. Nothing is sent, but every copy is priced at the real mark,
> with fees. Price protection skips a copy if the market has already run past their entry."

**Shot:** the Auto-Copy hub's result card.

> "And the hub keeps score: my result, my win rate, and how fast each copy filled."

### 2:15–2:45 · Tokens, and the people buying them

**Shot:** Search > Trending > the token you picked. The Trades tab: buys and sells arriving.

> "Desk trades tokens too, bought with MON. This is the live tape for one of them: real buys and
> sells on Monad, as they happen."

**Shot:** tap a buyer. Their wallet profile opens: what it holds, its PnL, its trades. Tap Follow.
It reads Following, and the bell line appears under it: **Alerts on · swaps over $250, every Perpl
move**. Tap the line, pick $50, save; the line now says $50.

> "Tap a buyer and you get the wallet: what it holds and what it has done. Follow it, and Desk
> tells me when it trades again: token swaps over the size I choose, and every move it makes on
> Perpl."

### 2:45–3:05 · MON when you need it

**Shot:** back on the token, tap Buy. Type more than your MON: **Not enough MON on Monad mainnet**,
and under it **Swap AUSD for MON**. Tap it. The swap sheet opens on AUSD → MON. Type 10. The quote:
you receive, at least, network fee. Hold. Face ID. "Approving AUSD for the swap", "Swapping", then
**SWAPPED** with the MON received. Done; the buy ticket now quotes.

> "Tokens need MON and I'd moved everything into AUSD for the desk, so Desk swaps back. Ten AUSD.
> It approves exactly ten to the router and not a cent more, checks the route on Monad before
> anything is signed, and Face ID signs. There's my MON, and the buy goes through."

*Optional:* complete the token buy if the MON covers it. Relay fills in about a minute; cut the
wait.

### 3:05–3:20 · Read the room

**Shot:** Home > BTC > the News tab. Tap a headline: the story opens as a page inside Desk, with
the markets it mentions as chips. Back. The Chat tab, with a message or two in the room.

> "Every market has its news, and a story opens inside Desk, never in Safari. And a room, for the
> people in the same trade."

### 3:20–4:00 · The same desk, in a browser

**Shot (Mac):** Safari on trydesk.trade/app. Connect wallet > **Sign in with your passkey** > Touch
ID. The address pill shows the same address as the phone. Portfolio: **In trading**, **Wallet
AUSD**, and the AUSD row **In your desk · Perpl**. Back to BTC: the order book beside the chart,
streaming. In the Crowd table, click a trader: the drawer opens over the page; **Follow**. The
bell: **Turn on alerts**; Safari asks; the **Trade alerts are on** notification lands. The ticket:
**Set up trading here**, Touch ID, then a small long. Filled; the position appears under the
chart.

**Shot (iPhone):** Your desk on the chart, with the same position.

> "The same passkey signs into a browser, on a Mac. Same address, same desk, the AUSD I hold in
> trading right there. The live order book sits beside the chart. Traders open in a drawer over
> the page, I can follow them here too, and the browser gets the same alerts the phone does. And I
> can trade: this browser registers its own key with Perpl, signed by my wallet, and a small long
> fills. On the phone, it's already in my desk."

### 4:00–4:15 · A live alert (only if captured for real)

**Shot:** the trade alert on the iPhone Lock Screen. Press and hold, Copy Trade. Desk opens on the
ticket. Face ID, hold, filled. Then the Live Activity, tap Pause. Or the same alert landing on the
Mac during the browser take.

> "A trader I follow just opened a position. Copy Trade opens Desk with the trade ready. Face ID,
> hold, and it's mine. And I can pause copying right from my Lock Screen."

If no real alert arrived during the session, cut this section and give its time to the others.

### 4:15–4:30 · Take the money out

**Shot:** Profile > Withdraw. The step list, Face ID, the receipt with its explorer link. Open the
link on MonadVision for a second. End on the AUSD balance in the wallet.

> "And the money comes back out. Withdraw shows every step, and each one has a receipt on Monad's
> explorer. That's Desk: perps on Monad, settled in AUSD, from your iPhone, or your browser."

## Rules for the cut

- No title cards longer than a second, and no music that fights the voice.
- Every claim on screen must be visibly happening. Say "mainnet" and "real money" where they
  apply, call a shadow copy a shadow copy, and never stage or fake a push.
- Keep one unbroken shot of a real order filling. That is the proof. The browser order is a second
  one; keep it unbroken too.
- The browser segment is its own recording: one window size throughout, no speed-up, and the
  passkey prompt on camera.
- End on the app, not a logo.

## Stills to capture while recording

For the submission form and the README, in this order: Home with live prices, Profile with the
AUSD balance, the BTC ticket with Est. fill, the Filled receipt, Position closed, a trader sheet
over the chart with its score, the token tape, the wallet profile with the alert line, the swap
receipt, the browser with the book and a trader in the drawer, the browser notification, and the
Withdraw receipt. Add the Lock Screen alert only if it was captured live.

## After recording

Copy the explorer links of the trade, the close, the swap, the browser order and the withdrawal
into `docs/submission.md` under "What is real", with their dates. Add your earlier deposit and Open
desk from Profile's activity, so the whole mainnet loop is on record.
