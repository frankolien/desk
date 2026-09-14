# Desk: what it is and what it has to do

A perpetuals trading app for Monad where the trading key is your face.

Written 11 September 2026. Working name; it appears in the bundle id, the passkey
relying party and the write-up, so it changes in the first days or not at all.

## Why this exists

Two reasons, and both have to hold or the project is not worth the weeks.

**The bounty.** Agora's **Best Mobile Trading App on Monad**, 10,000 USD, a single
prize, in the Onchain Finance and Trading track of Monad Metropolis. The deadline is
**14 October 2026 at 04:59 GMT+1**. This is one of two entries, alongside Olien on
Monad. The two run in parallel; neither is now behind the other.

The brief, quoted so that nothing is argued from memory:

> To be eligible, a team must build a mobile application that authenticates users via
> Mera (Monad's passkey authentication), holds and displays a stablecoin balance in
> AUSD, and executes trades through Perpl.

Judged on implementation quality, user experience, and "creative use of the three
integrations together, not just technical completeness". The deliverable is "a working
demo showing a user logging in via passkey, funding or viewing an AUSD balance, and
placing at least one trade on Perpl".

Three things follow from that wording and are worth stating plainly. The bar for Mera
is **authenticating via Mera**, not shipping a particular package, which is what lets
this be a native app. Displaying the AUSD balance is an eligibility requirement, not a
nicety, so the Fund screen is not optional. And the judging line says in its own words
that completeness is the floor rather than the prize.

**The product.** Perpetuals on a phone are still operated like crypto. To trade you
install a wallet, write down twelve words, fund it with a gas token you did not want,
connect it to a site, sign a message you cannot read, and keep a key on your device
that anyone holding the device can use. Every step of that is the operating manual,
not the trade. The same thesis behind Recourse applies here: the money is fine, the
manual is what stops people.

## Who it is for

Someone who already wants to trade and does not want the ceremony. Concretely: a
person who has used an exchange app, is comfortable with the idea of leverage, and
has never wanted to learn what a seed phrase is. They arrive with a phone and some
AUSD, and they should be trading within a minute of opening the app.

Not for: desktop market makers, anyone who wants twenty markets and a candlestick
toolbox, anyone who wants to bring their own hardware wallet. Those are real users
and this is not their app.

## The three ingredients

| Ingredient | Role | Why it is not decoration |
|---|---|---|
| Mera passkey | The only credential | Derives both keys. There is no other login, no other key, and no fallback that stores one. |
| AUSD | The collateral | The only balance the app shows. Every number on screen is denominated in it. |
| Perpl | The exchange | The account, the order book, the position, the funding, the withdrawal. |

Using all three is the bounty's floor. The prize is in how they combine, which is the
next section.

## What makes it different

**The key does not exist at rest.** Mera's model is that a passkey's PRF output is the
root and keys are derived from it on demand. Desk takes that literally. A Face ID
touch derives the Ed25519 key that Perpl trades with; the key lives in memory while
Desk is open, and is zeroed twenty seconds after Desk leaves the foreground, the moment
the phone locks, or when the person locks Desk themselves. The
secp256k1 wallet key is derived only for a contract call or an enrolment and zeroed on
the next line. There is no key in the keychain to steal and no export screen, because
there is nothing to export.

This is a real security property and also a real product one: the Account screen shows
whether the key is unlocked, and a button that locks it now. Most apps
hide their key handling. This one makes it the interface.

**Losing the phone costs nothing.** The passkey lives in iCloud Keychain. A new phone
signs in with Face ID and finds the same address, the same exchange account and the
same open position. No backup file, no phrase, no support ticket. Thirty seconds of
the demo video is a second device signing in and the position appearing.

**One passkey, two products.** The same passkey is a signer on an Olien treasury, the
other Metropolis entry. A team's treasury can fund a desk and a trader can trade inside
a limit the treasury set. That is the stretch, and it is the one thing no other
submission in either track can show.

## Principles

These decide arguments later, so they are written before the arguments happen.

1. **Never ask for a wallet.** No WalletConnect, no deep link into another app, no
   "connect" anywhere in the product. The account comes from the passkey or the app
   has failed.
2. **Never store a key.** The keychain holds the credential id and Perpl's opaque API
   token. Neither is a secret that can move money.
3. **Say the number before the signature.** Every order shows size, price, leverage,
   fee and liquidation price in AUSD before Face ID is asked for. The same rule as
   the Convert screen in Recourse.
4. **Never blank on a bad network.** A failed poll shows the last good figure with a
   note on its age, never a zero and never an empty screen. A trading app that shows
   a zero position during a reconnect is a trading app that causes a panic sell.
5. **One market done properly beats six done thinly.** The bounty judges quality.

## The journeys

Five screens. Anything not listed here is not in version one. Each journey has the
acceptance criteria that decide whether it is finished.

### 1. Sign in

The user opens the app and taps one button. On a first run this creates a passkey at
the app's relying party; afterwards it asserts against an existing one. Either way it
evaluates the PRF extension with Mera's default salt, derives the addresses, and lands
on Fund or Market depending on whether a desk exists.

Done when:
- A cold launch to a derived address takes one tap and one Face ID prompt.
- The EVM address printed matches the address Mera's own library derives from the
  same passkey in a browser at the same relying party.
- Deleting and reinstalling the app, then signing in, returns the same address.
- An authenticator with no PRF support produces a plain sentence about why the app
  cannot run, not a crash and not a silent fallback to a stored key.

### 2. Fund

Shows the MON balance and the AUSD balance for the derived address, with one line each
saying what they are for: MON pays for three setup transactions and nothing after
that, because trading itself is gasless. AUSD is the money. A
copy button, a QR, and a faucet link on testnet.

When AUSD is present and no exchange account exists, one button opens the desk. Behind
it: `aUSD.approve`, `Exchange.createAccount`, then the API key enrolment, which is an
EIP-712 wallet signature plus an Ed25519 proof of possession. Three signatures, one
Face ID prompt, one progress line, because the user asked for one thing.

Later top-ups run `depositCollateral` from the same screen.

Done when:
- Opening a desk from a funded address is one button and finishes in one flow, with a
  progress line naming each step in plain words.
- A failure at any step leaves the user able to retry without a duplicate approval or
  a stranded allowance.
- The screen states what MON is for, so nobody wonders why a dollars app wants a gas
  token.
- An address with an existing desk never sees this screen on launch.

### 3. Market

One market at launch, BTC, with others behind a picker only if `pub/context` makes a
second one nearly free. Live price over the trading websocket, a depth-lite view, and
the order ticket: side, size, leverage, market or limit.

The estimate appears before the confirm, in AUSD. Confirm runs a Face ID prompt only
if the signing session has expired, then sends the order and waits for its status.

Done when:
- Price updates are visibly live and a dropped socket reconnects and re-signs without
  the user touching anything.
- The ticket shows fee and liquidation price before the confirm, both correct against
  the values Perpl returns.
- An order placed from the phone appears in Perpl's own testnet interface.
- A rejected order says why in the exchange's own words, not a generic failure.

### 4. Position

Entry, mark, liquidation price, unrealised PnL, funding paid or received since entry,
and one button to close. A flat account shows Market instead, not an empty state.

Done when:
- The numbers agree with Perpl's interface for the same account, to the decimal.
- Close is one tap plus a confirmation, and reflects within a second of the fill.
- A partial fill is shown as a partial fill rather than rounded away.

### 5. Account

The address, the AUSD collateral, withdraw, and the key control: whether the trading
key is unlocked, a button that locks it now, and sign out.

There is no countdown. A fifteen-minute window was specified here first, and it was
wrong: when it ran out it put Face ID — or a sign-out — between a person and closing a
losing position. The trading key cannot move money, so a timer on it bought no safety.
It lives while Desk is open, survives a twenty-second trip to another app, and is wiped
after that or when the phone locks.

Withdrawals are contract calls the wallet signs, never the API key. That is worth a
sentence on the screen, because it is the reason a stolen API token cannot take the
money.

Done when:
- Nothing interrupts an order while Desk is open, and locking Desk forces a Face ID
  prompt on the next order.
- Leaving Desk for more than twenty seconds, or locking the phone, zeroes the key,
  provable by the next order asking for Face ID.
- A withdrawal reaches the derived address on Monad and the collateral figure drops by
  the right amount.

## Out of scope for version one

Named so they do not creep in: charts beyond a sparkline, order history, multiple
sub-accounts, limit order management beyond place and cancel, notifications, an
Android build, a web build, fiat on-ramp, referral or builder fees, and any market
beyond the picker described above.

## The adjacent bounties

Checked against the live Metropolis page on **13 September 2026**, because the brief in
the section above was transcribed on the 11th and the bounty list had not been read in
full. The $10,000 is confirmed, and it is not the only thing Desk is standing in front
of.

| Sponsor | Bounty | Prize | Where Desk stands |
|---|---|---|---|
| Agora | Best Mobile Trading App on Monad | $10,000 | The target. The whole build. |
| Perpl | Best use of Perpl's API | $5,000 | Already earned by the work in `DeskPerpl`: canonical signing strings, the authenticated socket, the pinned frame vectors. Nothing further to build. |
| Monad Foundation | Mera: One Passkey, Many Keys | $2,500 | Literally what `PasskeyAccounts` does — one PRF output, a secp256k1 wallet key and an Ed25519 trading key, on two derivation paths. Nothing further to build. |
| Monad Foundation | Best Mera-Powered UX on Monad | $2,500 | The thesis of the app. Contested by every other Mera entry, so this one is won on the onboarding, not on the cryptography. |
| — | Onchain Finance & Trading track | $30,000 / 3 teams | Desk's track. |
| — | Grand champion | $25,000 | Across all four tracks. |

Perpl also offers **$3,000 for a Best Analytics / Risk Tool**. Desk computes liquidation
distance, price impact and fee before the confirm, which is risk *disclosure* rather than
a risk tool; treat it as out of reach unless a position-risk screen is built, and it is
below the cut line if it competes with anything above.

### The bounties we are not chasing, and why

Decided 13 September against the full list of twenty-one, so it is not reopened in
October. Three of these are not merely out of scope — they are **incompatible**.

| Bounty | Prize | Verdict |
|---|---|---|
| Privy | $5,000 | **Incompatible.** Embedded-wallet auth. Desk's claim is that no layer holds a key. Adding it deletes the Mera bounties and the differentiator. |
| Dynamic | $5,000 | **Incompatible**, same reason. |
| MetaMask, Agent Wallet Plugin | $2,500 | **Incompatible.** Presumes a managed wallet. |
| Kuru, ×2 | $10,000 | Different exchange, spot orderbook. Violates principle 5. |
| Nansen, Chainlink CRE, Envio, Cleanverse | $11,000 | Different product. |
| Hunyuan / KIMI / Qwen credits | credits | No AI surface in Desk. |
| Aurora Intents, any-chain liquidity | $5,000 | Real, but a whole funding feature. Below the cut line; revisit only if 29 Sept – 5 Oct is genuinely slack. |
| Alchemy | $1,000 credits | **Open.** May be a config change if Alchemy serves Monad testnet — check once, take it if it is ten minutes, drop it otherwise. |

The judging line rewards "creative use of the three integrations together, not just
technical completeness". An app carrying eight SDKs scores worse on that sentence, not
better. Every bounty above is declined in service of the four we can win.

**The operational consequence: submit to all four.** They are separate bounty entries on
one project, and the extra work is submission text, not code. The three beyond Agora's
are already satisfied by code that exists — so the only way to lose them is to not enter.

**Dates, confirmed.** Submission closes **13 October**, judging runs 14–27 October,
winners announced **3 November**. This agrees with the 04:59 GMT+1 on the 14th used
throughout `05-milestones.md` — that is 23:59 US Eastern on the 13th — so the schedule
does not move.

**Submission deliverables, as the page words them:** a working product, a public
profile, a demo, a brief write-up, and a code link. New work must be done inside the
six-week window, which began 1 September.

One caveat on sourcing: the per-bounty detail pages live on `hackathon.monad.xyz`, which
refused connections from here on 13 September. The names, sponsors and amounts above come
from Monad's own Metropolis page; the **eligibility sentence quoted in "Why this exists"
has not been re-verified against the live bounty page**, and should be before the
write-up is finalised.

## What winning looks like

The bounty names three criteria, so the success criteria map to them.

**Implementation quality.** Every signature the app produces is pinned to a vector in
a test before it is sent to a server. The Perpl client is tested against the Node
reference script. The derivation is pinned to Mera's own output. A judge who opens the
repo finds tests, not assertions.

**User experience.** A stranger installs it, taps once, funds, and trades, without
being told anything. No seed phrase appears anywhere in the product or the copy.

**Creative use of the three.** The session model, the second device recovery, and the
treasury that funds a desk. All three are things the ingredients make possible and
that no one built before.

Beyond the bounty, the honest measure: would the author use it to trade their own
money. If the answer is no, the reason why is the next piece of work.

## Risks

| Risk | What happens | What we do |
|---|---|---|
| ~~iOS returns no PRF output~~ | Closed 12 September | Native PRF confirmed against Apple's SDK from iOS 18.0; ship-gated at 18.4. The React Native fallback is no longer needed. |
| A synced passkey returns different PRF on a second device | The recovery demo fails, and a real user sees a funded account as empty | An open Apple bug with no fix. The app compares the derived address against the last one it saw before showing a balance, and the recovery claim is stated honestly rather than absolutely. |
| ~~No testnet AUSD~~ | Closed 11 September | Agora runs a faucet on Monad testnet holding 670,000 AUSD. Verified on chain, details in the technical spec. |
| Perpl testnet is unstable near the deadline | The recording cannot be made | Record a working run as soon as one exists, then re-record only if there is time. |
| The calendar collides with Olien on Monad | Both entries suffer | Neither entry automatically wins now that they run in parallel; a collision is decided on the day against the cut line in `05-milestones.md`. |
| Perpl changes its API mid-build | The client breaks | Every message shape is pinned to a test, so a change fails loudly in a test rather than quietly in a demo. |
| Perpl geo-blocks where the demo is recorded | There is no live run to record, and a judge in a blocked country cannot open the app at all | `pub/context` carries `geo_block`, and on 13 September it reads BY, CU, GB, IR, KP, RU, SY, UA, US. The gateway decides, so this is checked against the recording location before any part of the schedule depends on a live trade. |
| Perpl turns enrolment off | Nobody can sign in, and the failure looks like a bug in our signing | `features.apiKeysEnabled` is read at sign-in and said out loud. It reads `on` as of 13 September. |

## Open decisions

- The name.
- One market or several at launch. Decide after reading `pub/context`.
- Testnet for the submission, now that the faucet is confirmed. Mainnet only if
  something forces it, because a demo that spends the founder's money gets recorded
  once.
- Whether the treasury stretch is worth the last week, decided on 1 October against
  the state of Olien on Monad.
