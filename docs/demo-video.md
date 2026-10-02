# Demo video: script and shot list

Target: **about 3 minutes**, screen recording from a real iPhone on **Monad mainnet**, voice-over
recorded afterwards. You start signed in, with your desk already funded: the video introduces
Desk, shows your balance and explains how a new person funds and opens a desk, then trades,
closes, follows and copies, and withdraws. Every amount is real, and the recording doubles as
the proof that Desk works on mainnet.

## Before recording

- **Mainnet.** Settings > Network > Monad mainnet > Use real funds. Say "mainnet" out loud; it is
  real money.
- **Money.** You're already signed in with a funded mainnet desk. Keep at least 60 AUSD in
  trading for the trade (50 AUSD at 5x is a comfortable size) and a little MON for fees.
- **Deposit push (optional).** To show "You received", send yourself a small top-up of AUSD from
  another wallet during the session, with the new TestFlight build, notifications and Deposit
  alerts on. If you skip it, drop the line that mentions it.
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

### 0:00–0:20 · Introduction

**Shot:** the iPhone home screen. Tap Desk. Face ID unlocks it. Home with live prices moving and
the Hot Markets cards. A slow scroll down the markets.

> "This is Desk, a native iPhone app for trading perpetuals on Monad. Every trade runs on Perpl,
> AUSD is the only money you see, and Mera's passkeys turn Face ID into your key. No seed phrase,
> no wallet app. Everything you're about to see is on Monad mainnet, with real money."

### 0:20–0:45 · Your balance, and how a new person gets started

**Shot:** Profile with your AUSD balance and what's in trading. Tap Add funds: Receive AUSD
opens the address and QR, and Swap MON for AUSD shows if you hold spare MON. Close the sheet.

> "I've already funded my desk, so this is my balance, in AUSD. If you're new, Add funds is where
> you start. Receive gives you an address to send AUSD to, from an exchange or any wallet, or you
> can swap MON you already hold. Then Open desk sets up your Perpl account under one Face ID: it
> approves the AUSD, creates the account, deposits it, and adds the key that signs your orders."

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

### 1:40–2:20 · Follow and copy

**Shot:** Signals > Top traders.

> "These are real traders on Perpl mainnet, ranked live."

**Shot:** open a trader with a high score and plenty of trades.

> "Each one is scored out of a hundred on their record. Win rate, profit factor, drawdown, and
> how many trades it's based on."

**Shot:** tap Follow.

> "I follow them. Now when they open, add to, trim or close a position, Desk tells me."

**Shot:** Auto-Copy rules with Shadow selected, then the price protection row.

> "Then I copy them, in Shadow first. Nothing is sent, but every copy is priced at the real mark,
> with fees. Price protection skips a copy if the market has already run past their entry."

**Shot:** the Auto-Copy hub's result card.

> "And the hub keeps score: my result, my win rate, and how fast each copy filled."

### 2:20–2:35 · A live alert (only if captured for real)

**Shot:** the trade alert on the Lock Screen. Press and hold, Copy Trade. Desk opens on the ticket.
Face ID, hold, filled. Then the Live Activity, tap Pause.

> "A trader I follow just opened a position. Copy Trade opens Desk with the trade ready. Face ID,
> hold, and it's mine. And I can pause copying right from my Lock Screen."

If no real alert arrived during the session, cut this section and give its time to the others.

### 2:35–2:50 · Take the money out

**Shot:** Profile > Withdraw. The step list, Face ID, the receipt with its explorer link. Open the
link on MonadVision for a second. End on the AUSD balance in the wallet.

> "And the money comes back out. Withdraw shows every step, and each one has a receipt on Monad's
> explorer. That's Desk: perps on Monad, settled in AUSD, from your iPhone."

## Rules for the cut

- No title cards longer than a second, and no music that fights the voice.
- Every claim on screen must be visibly happening. Say "mainnet" and "real money" where they
  apply, call a shadow copy a shadow copy, and never stage or fake a push.
- Keep one unbroken shot of a real order filling. That is the proof.
- End on the app, not a logo.

## Stills to capture while recording

For the submission form and the README, in this order: Home with live prices, Profile with the
AUSD balance, the BTC ticket with Est. fill, the Filled receipt, Position closed, a trader profile with its
score, and the Withdraw receipt. Add the Lock Screen alert only if it was captured live.

## After recording

Copy the explorer links of the trade, the close and the withdrawal into `docs/submission.md` under
"What is real", with their dates. Add your earlier deposit and Open desk from Profile's activity,
so the whole mainnet loop is on record.
