# The reference, read properly

Written 13 September, after shipping five screens that ignored it.

The NOVA screenshots were supplied as the target and I designed from
`03-screen-designs.md` instead — a document written before the screenshots existed. This
file is the reference read directly, so the argument stops being about my prose.

## What NOVA actually does

### Onboarding is a product, not a door

Six screens before the wallet exists, and every one of them sells something.

| Screen | What is on it |
|---|---|
| Hero | Amber gradient rising from the bottom edge, gold coin mark, heavy rounded headline "Your wallet, upgraded", one line of three benefits, blue pill CTA, quiet text button beneath. Behind it, feature words drift vertically — "Transparent Swap Fees", "Private Transfers", "Ledger Ready", "AI Shield" — most dimmed, one lit |
| Restore | A modal card over a dimmed parent. Title, one sentence, two stacked pills. Never a system alert |
| Terms | Shield mark, one instruction line, **three separate checkbox cards**, each a full sentence in plain English, and a CTA that stays disabled until all three are ticked |
| Carousel | Five pages, each a chip label, a short headline and a **device mockup of the real screen** |

The carousel pages are worth listing because the pattern is the lesson: a chip naming the
category, then a claim, then proof.

```
⚡ Native iOS      →  "Solana on iOS."
   Hyperliquid     →  "Leverage Perpetuals"
⇄ Cross-Chain      →  "Swap SOL for BTC."
   Wallet Profiles →  "Track Wallets. See Their P&L."
   Traders         →  "The Trader Feed."
```

### The empty state is designed

Perps with no position is not a blank screen. It is a large tinted glyph, **"No Open
Positions"** in heavy type, and **"Learn more about Perps ›"** underneath. One mark, one
sentence, one way forward. Desk currently has nothing here at all.

### Structure everywhere

- **Action tiles**: Deposit, Send, Swap, More as four rounded squares, icon over label
- **Rows are cards**: every token is its own rounded container, not a line in a list
- **Chips do work**: `All Networks ⌄`, `MAX 40x`, `Bridge 0%`, `Max`, `Normal $0.001`
- **Consequence rows are separate cards** — Position Size, Entry Price, Est. Liq. Price,
  Fee each in its own container, not one grouped block
- **A percentage slider** sits above the keypad on every amount screen
- **The CTA says what is missing**: "Enter Amount", "No balance", "Invalid Amount",
  "Select a token." — never a dead grey "Confirm"
- **A settings chip sits beside the CTA**, carrying the network cost. Not a row in the
  estimate

## What this changes

`03-screen-designs.md` says "dark means flat — one ground, no section containers, no
nested cards". Against the reference that rule is wrong for everything except the price
itself. It came from Recourse, a light money app with a different job. Corrected:

| Was | Is |
|---|---|
| Flat outside, carded inside sheets | **Carded almost everywhere.** The one flat thing is the hero figure — the mark price, the amount being typed |
| No onboarding beyond a sign-in button | **Hero, terms, carousel**, then the ceremony |
| Trading screen straight after sign-in | **Nobody with an empty account sees a trade screen.** Funding is the first screen, and it is a guided sequence |
| No empty states | Every screen that can be empty gets a mark, a sentence and one action |
| One green | A real palette: gradient hero, tinted glyphs, chips that carry state |

## What Desk does not copy

NOVA is a wallet with a trading tab; Desk is one market done properly. So: no token
list, no watchlist, no signals feed, no cross-chain swap, no five-tab bar. The
**craft** transfers — the onboarding, the card structure, the empty states, the chips,
the CTA that names what is missing. The **surface area** does not.

And one thing is deliberately opposite. NOVA's terms screen exists to disclaim liability
("Nova Shield is not liable and cannot help in any way"). Desk's equivalent screen has to
explain leverage before somebody uses it, which is a different job with a different tone.
