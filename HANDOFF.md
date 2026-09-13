# Handoff

Written 13 September 2026, end of day two of thirty-two. Read this first.

## What this is

Desk: a native iOS perpetuals trading app for Monad where the trading key is derived from
a passkey. Built for Agora's **Best Mobile Trading App on Monad** bounty, 10,000 USD,
closing **14 October 2026 at 04:59 GMT+1**. Required integrations: Mera (passkey auth),
AUSD (collateral), Perpl (exchange).

## The one instruction that matters

**The user prioritises UI and UX above everything else.** That is a direct quote in
substance: *"I PRIORITIZE UI/UX MORE THAN ANYTHING ELSE."* The library underneath is in
good shape and well tested; the app on top is where the work is. Two design mistakes have
already been made, both from designing against a document rather than against evidence:

1. Building from `03-screen-designs.md` after the user supplied reference screenshots.
   The screenshots win. They are read properly in `06-design-study.md`.
2. Designing a feature carousel from those screenshots, when several of them are the
   reference app's **App Store listing**, not its onboarding. See
   `07-onboarding-research.md`.

Do not design from prose. Look at what shipping apps do, then build.

## Where the code is

```
App/Desk/            the iOS app — screens, components, app model
DeskKit/             the local Swift package: seven library targets
  Sources/DeskMoney  arithmetic. Depends on nothing, so it cannot reach the network
  Sources/DeskNet    HTTP and websocket transport
  Sources/DeskAuth   derivation, signing, the session, the relying party
  Sources/DeskChain  ABI, RLP, EIP-712, transactions, Monad RPC
  Sources/DeskPerpl  the exchange client
  Sources/DeskFlow   enrolment and the opening sequence — where the three meet
  Sources/DeskUI     palette, type, direction encoding, surfaces
project.yml          XcodeGen is the source of truth; Desk.xcodeproj is generated
docs/                00 prd · 01 spec · 02 system · 03 screens · 04 algorithms ·
                     05 milestones · 06 design study · 07 onboarding research
tools/               check-relying-party.sh
reference/perpl/     the Node scripts that generate the cross-check vectors
```

### Commands

```bash
swift test --package-path DeskKit          # 317 tests, ~0.2s, no simulator
xcodegen generate && open Desk.xcodeproj   # the project is git-ignored
xcodebuild -project Desk.xcodeproj -scheme Desk \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build/xcode -skipPackagePluginValidation \
  -skipMacroValidation build
DESK_LIVE=1 swift test --package-path DeskKit --filter LiveMonadTests
```

Two traps. `swift-secp256k1` ships a build plugin — Xcode prompts to trust it, the CLI
needs `-skipPackagePluginValidation`. And Xcode builds dump intermediates into the repo
root; they are git-ignored but worth deleting.

The app takes `-stage welcome|signin|fund|market` in DEBUG to jump straight to a screen
for screenshots.

## State

**Library: done and audited.** Four adversarial audits found **45 real defects**, every
one of which had passed its own module's tests. Every signature is pinned to a viem
vector; the live suite runs against Monad testnet. Do not take the library on trust, but
do not rewrite it either — read `04-algorithms.md` §14–16 for what the audits found.

**App: Welcome and Home are designed.** The leverage explainer too. Fund, Market,
Position, Account and the ticket exist but are first drafts that predate the research.

**The shell changed on 13 September, and this is the important part.** Sign-in used to
route straight to `MarketScreen`, so the first thing a person saw after proving who they
were was a mark price with Long and Short under it. It now routes to `TradingShell`, a
three-tab shell — **Home, Market, Account** — landing on `HomeScreen`.

Home is the account, in the order a person actually asks: what do I have (the AUSD
figure, hero, tap to hide, persisted), what can I do (Add funds / Withdraw / Trade /
More, with exactly one tile lit when the balance is zero), what am I in (position), what
is it doing (the market card). Market is now a destination, and `MarketModel` is owned by
the shell so the price survives tab switches and the sparkline has a series.

Run `-stage empty` for the zero-balance first run and `-stage market` for the funded one.
Both are the screens most likely to be wrong and least likely to be looked at.

### Next, in order

1. **The ticket, rebuilt.** Consequence rows as separate cards, a percentage slider above
   the keypad, a settings chip beside the CTA, and **hold-to-confirm**.
2. **Position on Home.** The card is an honest empty state but has never rendered a real
   position — `HomeScreen.positionSection` needs the PnL-first card once `AppModel` carries
   one.
3. **The guided funding sequence.** MON faucet → AUSD faucet → open desk. Fund shows the
   destination, not the path.
4. **Haptics.** Selection on the leverage scrubber, notification-success on a fill.
5. **Onboarding copy.** "Face ID Sign-In" sells the floor; the key is *derived* from the
   passkey, not unlocked by it. See the note under the Welcome screen.
6. **App icon.** Still the default white square.
7. Glass chips everywhere, and one radius geometry throughout.

## Where it stands, 13 September

**Every blocker in `05-milestones.md` is closed.** Paid Apple membership confirmed,
individual account is fine on the internal TestFlight path, and the relying party is
live at **`desk-trading.vercel.app`** — verified serving its association file directly,
no redirect. `tools/check-relying-party.sh` with no arguments checks the domain *and*
compares the two copies of it in the repository.

**The chain runs end to end in code:** passkey → wallet key → approve → account →
enrol → socket → order. `PasskeyCeremony` is the real AuthenticationServices flow,
balances and positions come off the chain and the venue, the ticket sends through
`OrderDesk`, and `openDesk` runs the real four-step sequence.

**Nothing in the app is invented any more.** Eleven controls did nothing this morning
and now none do. The fabricated market table and wallet list are gone. Every figure on
every screen either comes from the venue or renders `--`.

### What is left

1. **A physical iPhone on 18.4+.** The ceremony cannot run in a simulator. This is the
   only thing between the repository and a real Face ID sign-in.
2. **A funded testnet address.** Agora's faucet was at 600,000 AUSD on 13 September,
   down from 640,000 two days before — about sixty claims.
3. **The Perpl builder id**, for enrolment.
4. **The ticket's remaining design pass** — percentage slider above the keypad, leverage
   as a header chip, insufficient-margin explanation.
5. **App-layer tests.** DeskKit has 383; the app target has none, and both instances of
   the order-association race lived in app code. The fix that scales is moving logic
   down — `OrderProgress` is the pattern — rather than adding a UI test target.

### Two traps worth not rediscovering

**`INFOPLIST_KEY_<custom>` silently does nothing.** Xcode injects only keys it
recognises. The setting appears in `-showBuildSettings` and the value is simply absent
from the built plist. A missing relying party falls back to the debug stub, which would
have signed every user in as the same person.

**Vercel's Deployment Protection answers 302 to an SSO page.** That is exactly the
redirect Apple refuses and a browser follows silently. It defaults to on.

## Decisions already made, with their reasons

- **Amber `#E8B339` is the action colour, not green.** Green means profit; a green confirm
  button and a green PnL figure make the same statement. Direction owns green and red,
  action owns amber. Contrast 10.4:1 on the ground.
- **The ported pine `#05634A` reaches only 2.75:1** on near-black — it was chosen against
  Recourse's white canvas. It survives as a quiet brand surface, never a figure.
- **`rise #4CC38A` and `fall #E5484D`** are separated by 1.77:1 in luminance so they
  survive a grayscale filter. Asserted in `Tests/DeskUITests`.
- **Never flat black.** `DeskBackground` puts one amber light at 7% and one cool fill at
  3.5% on every screen.
- **`--`, never `0.00`,** for a value that does not exist. A zero is a claim.
- **The leverage explainer gates the first trade, not the launch.** Terms are footer
  microcopy.
- **Dark only.** An untested light mode in thirty-one days is a liability.
- **The package lives in `DeskKit/`, flat targets inside.** Checked against fourteen
  production Swift packages; none nests targets under a grouping folder.

## Blocked, and who by

- **The relying party.** Permanent once the first passkey exists. Run
  `tools/check-relying-party.sh <domain>` on any candidate — the requirement that catches
  people is that Apple will not follow a redirect, and `apple.com` itself fails it.
- **Apple Developer account type.** Passkeys need associated domains, which need a **paid**
  membership. Also: App Review guideline 3.1.5(iv) says crypto futures apps must come from
  approved financial institutions, and 5.1.1(ix) says not from an individual developer.
  Irrelevant to a demo video, material to TestFlight. See `07-onboarding-research.md`.
- **A Perpl builder id.** Manual, via Discord, and frozen at enrolment.
- **Device signing.** Xcode has no Apple ID signed in, so device builds fail at
  provisioning. Simulator works. A physical iPhone is connected and on iOS 26.6.2.

## Unanswered questions

- How far toward the reference app's look — full saturation, or the current green identity
  with its structure?
- Do Market and Position merge into one screen?
- Testnet for the submission, or mainnet?

## Uncommitted

Everything. The last commit is `4e2ff9a` from 11 September; the entire library, the app,
the docs and the tooling are unstaged. Commit early.
