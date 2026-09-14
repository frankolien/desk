# Desk: the screens

Five screens, drawn. Written 12 September 2026. The product document says what each
screen is for and when it is finished; this says what is on it, in what order, and what
it does when things go wrong.

Every number on every screen is denominated in AUSD. Nothing here shows a seed phrase,
a network name, a gas estimate in gwei, or the word "connect".

## The design language

Desk is not one company's style. It is three moves, and naming them settles arguments
that would otherwise be settled by taste in week four.

| Move | From | Applies to |
|---|---|---|
| One saturated accent on a near-black flat ground, billboard-scale figures, keypad-first entry | Cash App | Fund, the ticket, every amount |
| Live price large and high-contrast at the top, secondary metrics smaller and muted below, progressive disclosure, bottom nav of three | Robinhood | Market, Position |
| Security stated as interface, full disclosure before the biometric, nothing exportable because nothing is stored | Apple Wallet and Apple Card | Sign in, Account |

The discipline to steal from Coinbase without the feeling: a small, constrained token
set. Twenty-odd colours, under twenty type styles. A judge scoring implementation
quality can see a design system; they cannot see good intentions.

### Tokens, ported from Recourse

The palette arrives already opinionated, and its rules carry over unchanged.

```
night        #070907   near-black with a green cast, not neutral black
nightChip    #141A16   one step up from the ground, only on tappable things
nightText    #EDF2ED   nightMuted  #8C998F    nightLine  #212B23

ledger       #05634A   deep pine. The brand accent, and a FILL only
onLedger     #EDF2ED   what sits on a pine fill

rise         #4CC38A   long, and profit
fall         #E5484D   short, and loss
onFall       #0B0D0B

impactAmber  #E8B339   impactOrange  #F08C3C    impactRed = fall
```

**One correction the port forced, found by computing rather than looking.** Recourse's
`ledger` was chosen against a near-white canvas. On Desk's near-black ground it reaches
**2.75:1** — under the 3:1 floor for a UI component and far under the 4.5:1 a figure
needs. So pine stays as the button fill, where the contrast that matters is the label
against the fill (6.41:1), and a lighter green carries every figure that sits on the
ground. `rise` is 9.02:1 there and `fall` 5.10:1.

The pair is also separated by **luminance and not only hue** — 1.77:1 between them — so
they stay distinguishable under Apple's grayscale filter, which is the rule the section
below asks for. Every one of these numbers is asserted in `Tests/DeskUITests`, so the
palette cannot drift out of compliance without a test going red.

Three rules come with them:

1. **Dark means flat — on a screen.** One ground, no section containers, no nested
   cards. Chips appear only on things that can be tapped. **Sheets are the exception:**
   inside a sheet, grouping earns its keep, and the ticket's consequence rows read
   better as separate chips than as a flat list. Flat outside, carded inside.
2. **Green is reserved.** It means an action or a positive state, never decoration and
   never structure. Micro-labels stay muted.
3. **Type is the system font, semibold, large.** No licensed face. Figures are
   `.monospacedDigit()` everywhere a value can change, so a price does not jitter.

### The interaction grammar

Borrowed from the native Solana apps, which have already solved the mechanics of
trading on a phone even where their product decisions go the other way. Four patterns,
and they apply everywhere.

**Everything consequential arrives as a sheet**, with a grab handle, over a dimmed
parent. The ticket, the close confirmation, the withdrawal, the funding sequence.
Sheets keep the price on screen behind them, which matters when the thing you are
deciding depends on it. Screens are for places you *are*; sheets are for things you are
*doing*.

**The action button states its own blocked reason.** Not a grey rectangle that fails
silently — a button that reads "Enter an amount", then "Not enough collateral", then
"Price is 30s old", then finally "Long 0.0148 BTC · 1×". The button is the error
surface, so an error never needs its own alert. This is the single best pattern in the
reference set and it solves the stale-price case for free.

**Direction is carried by the whole sheet, not just a label.** The confirm button is
green for a long and red for a short, and the tint follows through the sheet. Redundant
with the side chip, which is the point — see the grayscale rule below.

**Amount entry is keypad-first, with the consequences directly beneath it.** The app's
own keypad on the ground, never the system keyboard sliding over the figure. The number
at the top, what it costs immediately under it, the keypad below that, the action
pinned to the bottom. That ordering is principle 3 rendered as a layout.

One smaller thing worth taking: the cost of a transaction sits as a quiet chip beside
the confirm button, not as a row in the estimate. It is a fact about the network, not a
term of the trade.

### Up and down without colour

Long and short, profit and loss, must survive the grayscale filter — Apple's own test,
and a thirty-second one per screen. The encoding ladder, strongest first: an explicit
sign using U+2212 MINUS rather than a hyphen; a shape, `arrow.up` or `arrow.down` from
SF Symbols so it scales with Dynamic Type; the word "Long" or "Short"; stable position;
and a real luminance difference between the up and down colours. Respect
`accessibilityDifferentiateWithoutColor`.

## 1. Sign in

One screen, one button, nothing else. A wordmark, a sentence, and **Continue with
Face ID** — labelled with the method, because Apple's guidance is to name it rather
than to show a generic verb or an icon.

First run creates a passkey; afterwards it asserts against the stored credential id.
Never call create twice: Mera generates a fresh user handle on every create, so a second
create silently makes a second wallet.

If registration returns `isSupported == true` but no PRF output, run an assertion with
the same salt immediately. That is a second Face ID prompt and it is correct.

**The address guard.** After derivation, compare against the last address this install
saw. On a mismatch, stop and say so plainly — Apple has an open bug where a synced
passkey returns different PRF output on different devices, and the failure mode without
this check is a user staring at a funded account showing zero. Offer to retry rather
than proceeding.

No PRF support at all gets a plain sentence about why the app cannot run. Not a crash,
and never a fallback that stores a key.

## 2. Fund

The screen a stranger meets second, and the one the bounty requires.

```
Your money
  1,240.00  AUSD            ← the figure. Billboard scale
  Ready to trade

Gas
  0.19 MON
  Pays for three setup transactions. Trading itself is free.

[ address chip · copy · QR ]

──────────────────────────────
Open your desk                             [ Open ]
Moves 1,240.00 AUSD to the exchange.
```

**The MON line says what MON is for**, because a dollars app asking for a gas token is
otherwise a question mark. And it states the good news plainly: after setup, orders
cost nothing, because the exchange forwards and pays.

**The testnet funding sequence is guided, not a list of links.** Three steps with their
own states, in order, because getting this wrong strands a user on step one:

1. **MON** — QuickNode's faucet. It is the only one that serves a brand-new address;
   the official Monad faucet requires Ethereum mainnet balance and history, which a
   passkey-derived address will never have.
2. **AUSD** — Agora's faucet contract, `requestFunds`, 10,000 AUSD. The sixty-second
   cooldown is **global**, so a failure here usually means somebody else claimed. Say
   that, and count down. There is no per-address lockout, so an address can claim
   repeatedly up to the 100,000 AUSD ceiling.
3. **Open the desk.**

After MON arrives, wait about 1.2 seconds before the first spend. Monad validates
balances against lagged state and a spend too soon is rejected.

**Opening the desk is one button and one progress line**, naming each step in plain
words: approving, opening, enabling trading, registering the key. Four steps, one Face
ID prompt, because the user asked for one thing. On failure the line stops where it
stopped and the button becomes **Resume**, which restarts from the first unsatisfied
precondition rather than the beginning.

An address that already has a desk never sees this screen on launch.

## 3. Market

One market. The screen itself is calm; the ticket is a sheet over it.

```
┌──────────────────────────────────────┐
│  Desk              1,282.18 AUSD  ◔  │   ← balance always visible
├──────────────────────────────────────┤
│                                      │
│  BTC perpetual                       │
│  67,412.30                           │   ← large, monospaced
│  ▲ 1.42%  today                      │
│                                      │
│  ╱╲╱‾╲╱╲___╱‾╲__╱‾                   │   ← sparkline, hairline, no axes
│                                      │
│  ─────────────────────────────       │
│  [ depth-lite: bids | asks ]         │
│                                      │
│      ( Long )        ( Short )       │   ← floating pills, not a docked bar
└──────────────────────────────────────┘
```

The account button doubles as the key indicator: unlocked or locked, tapping through to
Account when unlocked and straight to Face ID when locked. One element doing two jobs, and it puts
the product's main idea on the home screen without a sentence explaining it.

**Long and Short do not trade.** They open the ticket. Keeping the size and leverage
controls off the home screen matters more than the extra tap — an always-visible
leverage slider is an invitation to fiddle, and that is the exact surface the FCA's
research is about.

The ticket is a sheet, and its order is fixed: the amount, then what the amount costs,
then the keypad, then the action. Nothing consequential is behind a disclosure.

```
   ┌─ grab handle ─────────────────┐
   │  Long                    BTC  │   ← side + market
   │  1,000.00              AUSD   │   ← the figure being typed
   │                               │
   │  Order value      1,000.00    │
   │  Margin           1,000.00    │
   │  Liquidation      62,315.40   │
   │                   7.6% away   │
   │  Fee                  0.35    │
   │  Price impact         0.04%   │
   │                               │
   │  [ 25% ][ 50% ][ 75% ]  Max   │
   │  ┌ 1 ┐┌ 2 ┐┌ 3 ┐              │
   │  ┌ 4 ┐┌ 5 ┐┌ 6 ┐              │
   │  ┌ 7 ┐┌ 8 ┐┌ 9 ┐              │
   │  ┌ . ┐┌ 0 ┐┌ ⌫ ┐              │
   │                               │
   │  [1×]   [ Long 0.0148 BTC ]   │   ← leverage chip · stateful CTA
   └───────────────────────────────┘
```

**Leverage opens at 1x.** Not 2, not 5, not the last value used. The FCA names "high
default amounts for investments and leverage" as a harm vector in this exact product
category, and a pre-selected leverage is the single easiest dark pattern to ship by
accident. The control is a chip showing the current multiplier which opens a slider
bound to a text field; fifteen stops is a small enough range that this works.

**Size is typed, with percentage chips writing into the same field.** Typed entry is
the source of truth. No pre-selected Max chip — that defaults the user to the ceiling.

**Everything above the confirm, always.** Order value, margin, liquidation price with
its distance, fee, and price impact for market orders. Perpl's own word is "liquidation
distance", and distance is the number that means something; the absolute price hides how
close you are. The fee is an absolute AUSD figure, not basis points, and it must not
imply a round trip — Perpl charges on open only, and closing is free.

**The confirm button says what it does.** "Long 0.0148 BTC · 1×", never "Confirm".

**Slippage colouring**, borrowed from Uniswap's published thresholds so the boundary
has a reason behind it: neutral to 1%, amber 1 to 3%, orange 3 to 5%, red above 5%.
Perpl's own cap is `order_max_market_slippage_bps`, 1000 on testnet BTC, which makes
"will this fill" the real question rather than "what will it cost".

### Price freshness

A mark price is not a ten-hertz stream. Perpl writes mark on chain only when it moves
more than 0.05%, so a frantic animation would be decorating a value that barely moves —
and the SEC's own list of digital engagement practices names "visual cues, like changing
colors". Calm is both better design and safer ground.

| State | Age | Price | Confirm |
|---|---|---|---|
| Live | < 2s | full opacity, brief flash on change | enabled |
| Settling | 2–5s | full opacity, flashing stops | enabled |
| Stale | 5–15s | dimmed to ~55%, digits frozen, "Last updated 8s ago" | enabled, re-priced on submit |
| Disconnected | > 15s | dimmed last-known-good, "Reconnecting…" pill | **disabled, with the reason on screen** |

The flash is 80 to 120ms of hold and 150 to 250ms of fade, capped at three per second,
on the digits rather than the row, and off entirely under Reduce Motion. Desktop
blotters use 500ms and a full second; that is far too slow for a phone, and above three
per second a full-area flash approaches the WCAG seizure criterion.

Retry is silent with exponential backoff and becomes visible only once it fails. Never
blank, never a dash, never a zero, and never a spinner over a number.

The disconnected threshold should be Perpl's own on-chain maximum index age. When the
screen says the price is too old, the contract would reject the order anyway, so
disabling the button is honest rather than paternalistic.

## 4. Position

A flat account shows Market instead. There is no empty state here.

Mobile orders this differently from a desktop table, and the mobile convention wins:
**profit and loss first, liquidation second**, then size, then reference prices.

```
Long BTC · 3×

  +42.18 AUSD                        ← first. Sign, colour, and arrow
  +4.2%  on margin                   ← label the denominator. It is not standard

  Liquidation    62,315.40   7.6% away
  Size           1,000.00 AUSD  ·  0.0148 BTC
  Entry          66,980.10
  Mark           67,412.30
  Funding        −0.83 AUSD  since you opened

            [ Close position ]
```

**Size is two labelled rows**, notional and base. It is the cleanest resolution of the
base-versus-quote ambiguity, and it matters most in an app where the user thinks in
dollars.

**The percentage needs its denominator named.** Hyperliquid divides by equity, Binance
by entry margin, OKX by position margin, dYdX publishes none. They are not
interchangeable, so pick one and write what it is.

**Field-level staleness.** When the feed goes stale, mark, PnL and liquidation dim and
freeze **together** — they derive from the same tick. Entry, size and funding do not
dim, because they are still true. No exchange UI does this; it costs almost nothing and
it is exactly the craft a judge scoring implementation quality would notice.

Close is one tap plus a confirmation, and it must use the close order types. Closing a
long by opening a short inverts the position and pays a taker fee; the close type pays
nothing and is exempt from the initial margin check, so an underwater position can
always be closed. A partial fill is shown as a partial fill, never rounded away.

## 5. Account

Where the product's main idea becomes visible.

```
Address     0x50B2…a8F9            [ copy ]
Collateral  1,282.18 AUSD

Trading key
  Unlocked · held in memory while Desk is open
  Derived from your face. Never stored, never written to disk.
                                     [ Lock now ]  [ Sign out ]

Withdraw                             [ Withdraw ]
Withdrawals are signed by your face, not by the trading key.
That is why a stolen key cannot move your money.
```

There is no countdown. Locking must actually force a Face ID prompt on the next order,
and leaving Desk for more than twenty seconds or locking the phone does the same —
provable the same way.

The withdraw sentence earns its place: it is the reason the architecture is not just a
convenience. This is the one screen where slide-to-confirm is right — a withdrawal is
rare and consequential, and a nonstandard gesture suits it. On the order ticket it would
be wrong, because a repeated action habituates and the gesture decays into a button with
extra steps.

## Rules that apply everywhere

**Confirmation.** The deliberate tap is the moment of consent, not the Face ID prompt.
Face ID begins scanning the instant it is invoked and gives no final chance to cancel,
which is Apple's own documented caveat — so the full estimate must be on screen before
the tap, and the prompt only authorises what was already decided.

**Never blank on a bad network.** The last good figure with a note on its age. A zero
position during a reconnect causes a panic sell.

**Accessibility.** A ticking price is marked `.updatesFrequently`, which tells assistive
technology to poll rather than be interrupted; iOS has no live-region equivalent and
this is the documented answer. Announcements are reserved for discrete events — filled,
rejected, liquidation threshold crossed — with the uninterruptible priority kept for
margin warnings. Currency is spoken through a formatter, not read off the glyphs.
Direction is a word, not an arrow glyph. At accessibility text sizes, columns collapse
to stacked rows; nothing shrinks and nothing is clamped.

**Three prohibitions**, each with a regulator or a consent order behind it: no
celebratory animation on a fill, ever. No pre-selected leverage above 1x, and no
pre-selected Max. No push notification that prompts a trade — which is moot, because
notifications are out of scope.

## What the reference apps do that Desk will not

The native Solana trading apps are where the interaction grammar above comes from, and
they are genuinely good at it. But they are portfolio apps with trading attached, and
Desk is a position app with one market. These are the places the borrowing stops, listed
so that a good pattern does not smuggle in a decision we already made the other way.

| They do | Desk does | Why |
|---|---|---|
| Leverage pre-set at 25x; `MAX 40x` advertised on market rows | Opens at 1x; the ceiling is a fact, not a feature | The one harm vector a regulator names in this exact category |
| A social tab: copy trading, win rates, "see their PnL" | Nothing | Measured at +12% trades and +6% risky trades in a randomised trial |
| Export Wallet, iCloud backup, and a terms screen disclaiming all liability for lost access | None of it exists | There is nothing to export. This absence *is* the product |
| Notification permission on first launch | Never asked | Default-on price alerts, flagged in the FCA's 2025 review |
| An empty state reading "No Open Positions" | The market, with the ticket one tap away | An empty state in a one-market app is a wasted screen |
| Token lists, watchlists, search, trending | One market | One market done properly beats six done thinly |
| Candlesticks with six timeframes and volume bars | A sparkline | A chart is for choosing between instruments. We already chose |
| Fee as a percentage; liquidation price as a dash | Fee in AUSD; liquidation price *and* its distance | Principle 3. The number has to mean something |
| Red and green carrying meaning alone | Sign, shape, word, position, and a luminance difference | It has to survive the grayscale test |

The useful framing: Desk's ticket ends up looking like theirs and being better on every
number it shows. Take the shell, fix the contents.


## Never blank, as a type

`LastGood<Value>` holds the last successful value and the count of failures since. Its
`recordFailure` cannot reach the value — there is no way to clear one except by replacing
it with a better one — so the fourth principle is enforced rather than remembered. A
failure does not make a value look fresher either: the age keeps growing, so a figure
that has stopped updating slides through settling into stale and then disconnected on its
own.

Retry is silent for the first two failures and only then worth a sentence, because a
spinner over a number that is still correct is worse than no spinner. The backoff doubles
from 500ms to a thirty-second ceiling, and carries no jitter: jitter exists to stop a
fleet retrying in lockstep, and one phone reconnecting stampedes nothing, so it would buy
nothing but an untestable delay.
