# Copying while Desk is closed

The copy loop runs in the app. That is a consequence of the product's one rule — no server
holds a key that can trade for anyone — and of iOS, which suspends an app about thirty
seconds after it leaves the screen and kills it whenever it wants the memory. This page
records what was built to soften that (A), what would remove it (B), and why B is not
built yet.

## A — Away copying (shipped)

**What it does.** With *Keep copying when I leave* on in Auto-Copy settings:

1. The app keeps the trading key in memory after you leave, for up to twelve hours instead
   of five minutes. The key is still only ever in memory or sealed in the Secure Enclave;
   nothing about where it lives changes.
2. The app tells the server which traders it is copying (alongside which it follows for
   alerts). When one of them moves, the server sends a *background* push — no banner, no
   sound. iOS wakes Desk for up to thirty seconds; the copy loop takes the copy exactly as
   it would have with the screen on, and the app goes back to sleep.
3. Coming back after more than five minutes asks for Face ID before the screens show,
   even though the key is alive — so a phone left on a table is not an open desk.

**What it does not do.** If iOS has killed the app, there is no app to wake. The key is gone
with the process; the normal alert still lands ("X opened a long — open Desk to copy") and
the copy is one tap away. There is no way to make this reliable from the phone, and it is
not presented as reliable: the setting's own text says "until iOS closes the app".

**What it depends on.** The alerts scan has to run on a schedule. `.github/workflows/scan.yml`
calls it every five minutes at best; an external one-minute scheduler pointed at
`/api/alerts?job=scan` with the `Authorization: Bearer <CRON_SECRET>` header is the
production answer.

**Where it lives.** `CopyTrader.wake()`, `DeskAppDelegate.application(_:didReceiveRemoteNotification:)`,
`SigningSession.allowAway`, `AppModel.enterForeground`, `TradeAlerts.setCopying`, and on the
server `wakePayload` and the `copying` field of a subscription in `web/api/alerts.mjs`.

## B — Server-side copying (designed, not built)

**What it would do.** Copy around the clock, whether or not the phone is on.

**How.** A Perpl account can enrol more than one trading key. Desk would derive a second one
from the passkey — a different index, the same ceremony — enrol it on the account, and hand
it to Desk's server. The server runs the copy engine for that account: reads the followed
traders, applies the person's rules and guards, places orders signed with that key, and
places stops on the venue exactly as the app does.

**Why it is safe enough to consider.** A trading key can place orders. It cannot withdraw:
deposits and withdrawals are signed by the wallet key, which the passkey derives every
time and which never leaves the phone. So the worst case of a server-held trading key is a
bad trade on the account, bounded by the same stops, daily loss limit and exposure caps the
app enforces — the same worst case as the key in memory today. Revocation is de-enrolling
the key on Perpl, which the app can do with one Face ID, and which the server cannot undo.

**What it changes.** The sentence "no server can trade for anyone" becomes "no server can
trade for anyone unless they turned this on". That is a real change to the product's
promise and to what a breach of the server would mean. It has to be opt-in, explained in
those words, off by default, and revocable from the app in one tap.

**What it costs.**

- A second copy engine, in JavaScript, with the same rules, sizing, guards, price
  protection and stop placement as `CopyTrader` — and tests proving the two agree.
- A long-running worker. Vercel functions answer requests; they do not run a loop. The
  engine needs a process that stays up (Fly, Railway, a small VM) with the same event
  subscription the app uses.
- Key custody on the server: encrypted at rest, decrypted in memory per account, audit
  log of every order placed, and a kill switch that revokes every key in one action.
- Monitoring that pages someone when the engine stalls, and a status the app shows so a
  person knows their copies are running and when they last ran.
- A migration path: an account can be copied by the app or by the server, never both.

**Why not now.** Metropolis closes on 14 October. B is two to three weeks done properly, on
new infrastructure, holding users' trading keys, tested under real fills — the one thing
worse than not having it is shipping it half-built to judges. A gets "it copied while my
phone was in my pocket" for the demo with every security sentence still true, and this
page is the plan the Perpl reviewer asked for: the problem thought about, the path clear.

## The order of work if B is built

1. Prove the engine offline: run `CopyTrader`'s rule tests against the JavaScript engine
   with the same fixtures until they agree on every copy, skip and stop.
2. Enrol a second trading key from the app and revoke it, on testnet, with Face ID at both
   ends.
3. Run the server engine in shadow only for a week, for one account, and compare its log
   with the app's.
4. Live, opt-in, testnet, with the kill switch tested first.
5. Mainnet, after a soak of at least a week.
