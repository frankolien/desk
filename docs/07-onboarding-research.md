# What shipping apps actually do

Researched 13 September across three parallel investigations: Apple's own flows and HIG,
the reference app's store listing and docs, and a survey of Phantom, Rainbow, Uniswap
Wallet, Backpack, Jupiter, Dexari, MetaMask Perps, Robinhood, Coinbase, Revolut, Monzo,
Wise, N26, Nubank and Chime. Several findings came from reading shipping source —
Rainbow and Uniswap Wallet are open source, so their copy below is verbatim.

This file exists because the design was wrong twice, both times from designing against a
document instead of evidence. Read it before changing the flow.

## The finding that reorders everything

**Nobody ships a marketing carousel at first run.** Every polished carousel found —
Phantom's seven panels, the reference app's five, Dexari's six, Coinbase's eight — is an
**App Store listing**, not an in-app screen. In-app flows are three to six screens with no
tutorial.

This was got wrong here first: the reference screenshots supplied as inspiration included
its store gallery, several frames still showing `◀ App Store` in the status bar, and a
carousel was designed from them. There is no evidence the app contains one.

Apple's HIG, verbatim:

> "Consider providing a collection of context-specific tips instead of a single onboarding
> flow. … A context-specific tip can also help people learn better because it lets them
> concentrate on a single action or task before encountering new information."

> "Avoid displaying licensing details within your onboarding flow."

Nielsen Norman, seventy users, between-subjects: the group **required** to read a
deck-of-cards tutorial rated tasks significantly **harder** — SEQ 4.92 against 5.49,
p=0.047 — with no benefit to success or time.

Measured budget for the crypto cohort: **11 screens, 7 fields, 1 min 53 s**. Banking runs
14 screens and about six minutes. Desk's users come from the first group.

## Where the leverage acknowledgement goes

Not in onboarding. **Rainbow's is the reference implementation**, read from its source:

```
HAS_SEEN_PERPS_EXPLAIN_KEY = 'hasSeenPerpsExplainSheet'
// if not seen: push PERPS_EXPLAIN_SHEET; only onDismiss → set flag → continue
```

One sheet, three pages, shown **once ever**, gating the **first entry to perps**. Its
third page does not soften: *"Leverage amplifies your risk. Bigger gains when you're
right. Faster losses, and liquidation, when you're wrong."* Button label is a shared value
flipping **"Next" → "Got it"**. Pages blur as they leave centre. The sheet forces dark
even though the app is light.

Desk's `LeverageExplainer` is this pattern, with the liquidation distance computed from
the live market configuration rather than typed.

**Terms are footer microcopy, not a screen.** Rainbow: *"By proceeding, you agree to
Rainbow's Terms of Use"*. Uniswap: *"By continuing, I agree to the Terms of Service and
consent to the Privacy Policy"* — `body4`, `neutral2`, centred, links inline, **no
checkbox**. Wealthfront put its conditions on screens instead of links, ran 28 screens —
twice any other investing app — and scored the worst friction index in the study.

## The zero-balance moment

Desk's original bug: sign in, land on Long/Short, with no money and no desk. Every
well-designed app in the set avoids exactly this. Four strategies, in order of quality:

**1. Never render the state.** Robinhood puts **Add funds before "Sign up complete"** —
funding is a step of signup. Revolut solicits top-up **twice, before KYC**. The ordering
principle, and the most transferable decision found: *identity-lite → profile → intent →
money → KYC*.

**2. An account shell, not a trading screen.** Uniswap's `WelcomeWalletScreen` renders the
user's own home — avatar, display name, an `AnimatedNumber` counting up to **$0.00**, and
**two skeleton token loaders** standing in for tokens they do not own. Emptiness reads as
*loading*, not *failure*. Copy: *"Welcome to your new wallet"* / *"This is your personal
space for tokens, NFTs, and all of your trades. Finish setting it up to keep your funds
safe."*

**3. A required-badge card stack.** Uniswap's `OnboardingIntroCardStack`: *"Get your first
token"* / *"Fund your wallet by buying crypto or transferring from another account."* with
a **Required** pill. The stack renders `null` the moment it empties.

**4. A persistent funding affordance.** Monzo's `Add money` sits on the account card at £0
and at £10,000 — only the number changes.

Two supporting results. **Pre-tick the first item**: Nunes and Drèze's car-wash field
experiment, both cards requiring exactly eight more washes — 8 spaces with 0 stamped
completed at **19%**; 10 spaces with **2 pre-stamped** at **34%**. Show "1 of 4", never
"0 of 4". And **completion is not activation** — a checklist that gets 80% to `deposit ✓`
and nobody to a trade has failed; make the last item the trade.

## What reads premium, ranked by cost to impact

1. **One ambient light source on a black ground.** The reference app's diagonal grey
   sheen; Dexari's starfield. One radial gradient at four to eight percent white.
   **Flat `#000` with no wash is the single most reliable tell of an unfinished app.**
2. **Two-tier numerals.** `$39,842` white, `.28` grey. Monzo does the same with pence.
3. **Glass chips, not filled badges.** Faint light border, material behind.
4. **Accent restraint.** Every premium app runs one accent and reserves green and red
   exclusively for direction and PnL. **The brand accent must be neither red nor green —
   both are already spoken for in a perps app.** Proven escapes: Revolut's cobalt violet
   `#494fdf`, Wise's forest green, Phantom's lavender, Jupiter's lime. Monzo states the
   rule: *"Hot Coral is our soul, but in UI land, red shades usually mean 'something has
   horribly gone wrong'."*
5. **Depth by luminance, not shadow.** Revolut: *"no traditional drop-shadow language.
   Surfaces register depth via colour-blocking and surface-luminance shifts."*
6. **One radius geometry, applied everywhere.** Pill (`9999`) reads consumer — Revolut,
   Wise, Phantom, Jupiter. Six pixels and *"no pill geometry anywhere"* reads
   institutional — N26. **Mixing them is the prototype smell.**
7. **Motion that explains.** Uniswap's buttons fade in only after the intro animation
   completes; its background rotates over 150 seconds.
8. **Device mockups belong on the App Store; in-app, premium apps are austere.** Every 3D
   render found lives on a marketing surface.

## What reads like a prototype

Each with a receipt.

- **Dropping the user on a functional-but-empty screen.** Phantom's older build:
  *"$0.00 with no guidance — a dead end."*
- **A tempting CTA that does not help.** Coinbase's *"get started trap"* — the button
  *"doesn't offer any help at all. Instead, it immediately asks you how much Bitcoin you'd
  like to buy"*, defaulting the asset and removing the choice.
- **Permission prompts before value.** Coinbase asks for notifications at **screen five**.
- **No confirmation moment.** Wise ends registration *"with no confirmation feedback"*.
- **Spinners instead of named states.** Revolut says **"Checking image quality"**.
- **Generic errors.** *"Error occurred"* against *"Photo is too dark. Try again with better
  lighting."*
- **One empty state.** A prototype has one; a product has twelve. Rainbow ships
  `No Open Positions`, `No Previous Trades`, `No Balance`, `You are not watching any
  wallets`, `Nothing to send`.
- **Polish before structure.** *"The most common mistake is adding visual polish —
  gradients, shadows, animations — before fixing spacing and hierarchy."*

## Risk patterns that are actually standard

1. A one-time explainer gating the **leveraged surface**, not first launch.
2. **Liquidation price before confirmation**, never after. Dexari renders entry, mark and
   liquidation as three labelled columns.
3. Leverage as presets with an inverse-cushion explanation. MetaMask: *"The higher the
   leverage, the higher the chance of liquidation"* — 10× ≈ 10% cushion, 40× ≈ 2.5%.
4. **TP/SL attachable at order time**, described as *"strongly recommended"*.
5. **Hold-to-confirm on irreversible actions.** Rainbow: `Hold to Long`, `Hold to Short`,
   `Hold to Close`. Friction at execution, not at onboarding.
6. **The 1× honesty case.** Rainbow shows *"No Liquidation Risk / Trading without
   leverage"* at 1×. Cheap credibility.
7. An appropriateness quiz is a **centralised-exchange** pattern. Binance gates futures
   behind a fourteen-question test; no self-custodial app in the set ships one. Do not
   build it unless counsel asks.

Phantom's disclosure is the model to quote in review notes: *"Trading perpetual contracts
involves significant risk, including the potential for sudden and total loss of your
investment and collateral due to high leverage, market volatility, and liquidation."*

## App Review, which is not a design problem

Guideline **3.1.5(iv)**, verbatim:

> "Apps facilitating Initial Coin Offerings, **cryptocurrency futures trading**, and other
> crypto-securities or quasi-securities trading must come from established banks,
> securities firms, futures commission merchants, or other approved financial institutions
> and must comply with all applicable law."

And **5.1.1(ix)**: highly regulated fields *"should be submitted by a legal entity that
provides the services, and not by an individual developer."*

Also relevant: **3.2.2(viii)** on derivatives licensing; **2.3.3**, screenshots must show
the app in use rather than a splash screen; **5.1.1(v)**, account creation obliges in-app
account deletion.

**This does not affect the demo recording. It does affect TestFlight**, which the
milestones put in the 29 September to 5 October window, under an individual account.
Decide what to do about it before that week, not during it.

Age rating is a choice, not a mandate — Apple's Gambling definition is *"betting or
wagering using real money"*, which trading does not meet. Observed spread: Coinbase 4+,
Phantom 16+, Dexari 17+, Robinhood 18+. **17+ is the defensible choice** and costs
nothing.

## Verbatim copy worth keeping

- Rainbow: *"Leverage amplifies your risk. Bigger gains when you're right. Faster losses,
  and liquidation, when you're wrong."*
- Uniswap: *"This is your personal space for tokens, NFTs, and all of your trades."*
- Revolut, on why it asks: *"We need to know this for regulatory reasons. And also, we're
  curious!"*
- Monzo, as progress: *"That's 1 section down, 3 to go."*
- The reference app's own documentation voice, which matches this project's:
  *"A missing signal is not a safe verdict."* · *"unavailable must not be interpreted as
  verified safe."* · *"A target price is not a reservation of liquidity."*

## Gaps nobody closed

Cash App and Apple Card have no screen-level material — two agents ran out of budget.
The reference app's in-app onboarding, legal placement and zero-balance state were never
observed; only its store listing and home screen were. Do not fill these in with guesses.

## The exchange side, added after a fourth investigation

Coinbase, Coinbase Wallet, Robinhood, the Hyperliquid clients, and how the centralised
venues gate derivatives. The Hyperliquid clients matter most: they are the same product
Desk is, and several are two weeks old.

### The competitor's own stated bar

Coinbase Wallet — renamed back from Base App on **10 September 2026**, three days before
this was written, explicitly pivoting away from social and toward trading — ships perps
via Hyperliquid at 50×. Its App Store description opens:

> "The fastest way to trade anything, onchain. Coinbase Wallet takes you from **zero to
> trade in under a minute** — trade millions of assets, crypto, perps, and prediction
> markets in seconds."

Dexari's account-creation doc is subtitled *"Set up your Dexari account in under 30
seconds"* and runs five screens, two of them optional. **That is the bar. No carousel
appears in any of them.** The official Hyperliquid Android app opens directly onto the
trade screen, dimmed, with a Connect sheet over it.

### Gate at intent, with the market already in view

Kraken's is the best pattern found, verbatim: *"On the **Trade** tab, use the market
selector to navigate to a futures or margin market. Select the **Unlock** at the top of
the order form."* … terminating in **"Trade now"**, not "Done" — it closes the loop back
into the form the user was already looking at. Desk's explainer fires on Long or Short,
which is the same idea.

The counter-example is worth knowing: OKX's derivatives unlock is a radio button in a
settings sheet, three taps, *"visually indistinguishable from changing a preference"*.

### Robinhood, options, and the seventy-million-dollar lesson

FINRA's action documents the anti-pattern precisely. Robinhood *"does not require
customers to wait before reapplying"*, and worse, **told rejected customers which answers
had disqualified them** and prompted them to update those responses. One customer changed
risk tolerance from low to medium and experience from `N/A` to three years, and was
approved for level 3 **thirteen seconds later**. Another was rejected fourteen more times
in a day.

So: **never surface which answer caused a rejection**, and never allow instant retry.
Robinhood EU's perps assessment now escalates per entry point — 24h, then 48h, then 72h,
then two weeks — with a **mandatory in-app read before reapplying**.

### Defaults and honesty cases worth copying

- **Robinhood EU defaults to Isolated 1×.** Leverage is opt-in, not pre-dialled. Desk's
  ticket already defaults to 1×; keep it.
- **Rainbow shows "No Liquidation Risk / Trading without leverage" at 1×.** Cheap
  credibility, and it makes the 1× default meaningful rather than invisible.
- **Based's disabled CTA reads `Enter order size`** — the best empty-state microcopy found
  anywhere in this research. A button that names what is missing.
- **Based on liquidation:** *"The liquidation price displayed in the interface is **an
  estimate** and may differ from the actual liquidation price at the time of execution."*
  Desk computes its liquidation conservatively for the same reason; say so on screen.
- **Robinhood EU puts a `?` on the confirm sheet** for margin mechanics — inline at the
  moment of commitment rather than in a help centre.
- **Binance ties an experience picker to a leverage cap** — Beginner 2×, Experienced 5×,
  Advance 20× — one control that is disclosure, segmentation and risk limit at once. And
  it **locks leverage above 20× for the first thirty days of an account**. High leverage
  earned rather than warned about.

### A zero-balance account needs a job

Nobody ships a lonely centred illustration. Robinhood gives an empty account **three**
things — a reward gated on linking a funding source, a first-trade recommendation, and a
swipeable card rail above the empty watchlist. Based fills the screen with markets and
makes **Deposit the only white button**. Coinbase Wallet: *"New wallets display the
Assets tab with a prominent **Buy** button."*

### If Desk ever faces EU or UK retail

FCA **COBS 22.5.8R** makes the standardised CFD warning a layout constraint, verbatim:
it must be *"statically fixed and visible at the top of the screen even when the retail
client scrolls up or down"*. That grey pinned strip under the nav bar in every European
broker app is mandated, not designed.

And **COBS 4.12A** requires a 24-hour cooling-off before a direct offer, a personalised
warning *"by means of a pop-up box"*, and — the rule with teeth — *"The options… must be
presented with **equal prominence**."* You may not make Continue a filled primary and
Leave a grey text link.

Not applicable to a Monad testnet submission. Applicable the moment it is not.

### Ecosystem conventions, observed across every client

- **Near-black plus one saturated accent**, and the accent is never the direction colour.
  Hyperliquid mint `#97FCE4`, Dexari sage, Splash lime, Dexly cyan, Based **orange with
  mint longs**. Desk's amber-with-green-longs is the same decision.
- **Marketing type is serif; product type is sans.** Consistent across the whole set.
- **Size entry has two idioms:** a notched percent slider with 25/50/75/100 chips, or
  Splash's circular arc dial. **Leverage is always a separate modal or header chip, never
  inline with size.**
- **Age ratings are incoherent** — Dexari 17+, Coinbase 4+ on iOS and 18+ on Play, the
  official Hyperliquid Android app "Everyone". Make it a deliberate choice; 17+ is
  defensible and free.
- **Hyperliquid's `ApproveAgent` and `ApproveBuilderFee` signatures are mentioned by no
  mobile client's documentation.** They are presumably signed silently. Perpl's
  equivalent is `allowOrderForwarding`, and Desk names it in the opening sequence — which
  is a small honesty advantage worth keeping.
