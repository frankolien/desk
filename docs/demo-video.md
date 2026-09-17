# Demo video — shot list and script

Target: **2 minutes 30**, screen recording from a real iPhone, voice-over recorded after.
Judges watch dozens of these; the first fifteen seconds decide whether they watch the rest,
so the hook is the copy engine, not the sign-in.

## Before recording

- Real device, not a simulator. Live Activity and the Dynamic Island only look right there.
- Do Not Disturb **off** — a trade alert has to arrive on camera.
- Battery above 50%, Wi-Fi strong, brightness high, no other notifications pending.
- The account is funded and already copying one trader with a history behind it, so the
  Auto-Copy screen is not empty.
- Have a second phone or a friend ready to trigger a push, or use the confirmation push by
  turning alerts on for a trader during the recording.
- Record in one take per section; cut later. iOS screen recording (Control Center) captures
  the Dynamic Island; a camera shot of the phone in hand is worth it for the Lock Screen.

## The script

| Time | Shot | Voice-over |
|---|---|---|
| 0:00–0:12 | Cold open: a trade alert lands on the Lock Screen. Press and hold. **Copy Trade** appears. Tap it; the ticket opens already filled in; hold to confirm; the fill toast. | "A trader you follow just opened a long on Perpl. You copied it from the Lock Screen, in about four seconds, and never opened the app." |
| 0:12–0:25 | Face ID sign-in on a fresh install: tap Continue with Face ID, straight into Home. | "This is Desk. Your face is the trading key. No seed phrase, no wallet connect — one passkey derives the wallet and the signing key, and neither is ever stored." |
| 0:25–0:50 | Signals tab: leaderboard, scroll, open a trader profile. Score gauge, stats, closed trades, style tags. | "Every trader here is read straight off Perpl's exchange contract on Monad. Their history is indexed from the chain's own position events, and scored on what survives: win rate, profit factor, drawdown, weighted by how much they actually risk." |
| 0:50–1:20 | Turn on Auto-Copy for that trader. Walk the Copy Rules sheet: Shadow/Live, Follow/Fade, Conviction sizing, leverage cap, stop loss, price protection. | "Copy them, or fade them. Size every copy by how much of their own account they put in. Cap their leverage with yours. Stops go on Perpl itself, so your copy stays protected even when Desk is closed — and price protection skips the copy if the market already ran away from their entry." |
| 1:20–1:45 | Auto-Copy screen: the result card, the traders, open copies, recent activity. Point at time-to-fill and slippage. | "It measures itself. Realised result, win rate, how many seconds after their move you filled, and how far from their entry. Shadow mode proves a strategy before a cent moves." |
| 1:45–2:05 | A copy fires live: the chain event arrives, the copy opens, the toast, the row in Recent. | "Desk watches Perpl's position events on Monad over a websocket, so a copy follows in the same block the trader moved in — not on the next poll." |
| 2:05–2:20 | Leave the app: the Dynamic Island shows today's result; swipe to the Lock Screen Live Activity; the Home Screen widget; say "Hey Siri, pause auto-copy in Desk". | "Then it lives where you already look. The Dynamic Island, the Lock Screen, the Home Screen, Control Center, and Siri." |
| 2:20–2:30 | Auto-Copy screen with the share-card summary, hold on it. | "Desk. Copy the best traders on Perpl, with your face as the key. Built on Monad." |

## Rules for the cut

- No title cards longer than a second and no music that fights the voice.
- Every claim on screen must be visibly happening. If a live copy will not fire on cue,
  show a shadow copy and say it is shadow.
- Keep one unbroken shot of a real order filling. That is the proof.
- End on the app, not a logo.

## Stills to capture while recording

For the submission form and the README, six screenshots in this order: Lock Screen alert
with buttons, trader profile, Copy Rules sheet, Auto-Copy summary, Dynamic Island, Home
Screen widget.
