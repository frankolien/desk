# Desk — marketing brief

*For an agent with web access. Do the research, return links, and draft the copy. Do not
invent facts about the product; everything true about it is in this file, and anything not
in this file should be asked about rather than assumed.*

## The product, in the words we use

Desk is a native iPhone app for trading perpetual futures on Monad, through the Perpl
exchange. Face ID is the trading key: a passkey derives the wallet and the signing key on
demand, nothing is stored, there is no seed phrase and no wallet app.

The hook is not Face ID. The hook is: **copy the traders who are actually winning.** Desk
reads every trader off Perpl's exchange contract — nobody submits a record — ranks them
on what survives (win rate, profit factor, drawdown, weighted by money at risk), and copies
their moves in the same block they happen, under rules you set. Shadow mode copies with no
money so a strategy can be proven first.

Other things it does, all real and shipped: a live crowd view (long vs short on every
market), push alerts with a Copy button on the notification, Home Screen widgets
(Portfolio, Watchlist, Auto-Copy), a Live Activity in the Dynamic Island with a working
pause, spot trading on trending tokens, and a share card for any position — your result
over your own photo with a QR that opens Desk.

- Site: https://trydesk.trade (live; ticker and figures on it are read from the exchange)
- App Store name: *Desk: Trade Perps on Monad* — on TestFlight now, **testnet build**
- Code: https://github.com/frankolien/desk (public)
- Chain: Monad. Exchange: Perpl (https://perpl.xyz). Collateral: AUSD. Passkeys: Mera.
- Hackathon: Monad Metropolis, closes **14 October 2026, 04:59 GMT+1**. Bounties targeted:
  Agora's *Best Mobile Trading App on Monad* and Perpl's *Best Use of Perpl's API*.

## What we are trying to get

In the next three weeks, in this order:

1. **TestFlight installs** from people who trade, not from people who click.
2. **Share cards in the wild** — every closed position can produce one; each one is an ad
   with a QR on it.
3. **Retweets from the Monad and Perpl accounts** — during Metropolis they amplify builders;
   that is the biggest free reach available.
4. **Judges seeing traction** before the deadline: installs, cards, and real people copying.

Vanity metrics (followers, impressions) are not goals. Installs and cards are.

## Lines we do not cross

- Perps are leveraged. **Never imply returns.** "Copy the traders who are winning" describes
  a leaderboard, not a promise. No "make money", no "passive income", no APY language.
- It is a **testnet build** right now. Say so where it matters. Nothing in it is real money.
- No fabricated testimonials, no fake follower counts, no paid engagement.
- Do not tag or DM anyone from a list you did not verify is real and active this month.
- The share card contains a person's photo. Only post cards from people who posted them
  themselves or gave permission.

## What already exists to post

- Six product recordings, 640px, ~10 s each, mp4: welcome (Face ID sign-in), home,
  signals leaderboard, auto-copy activity, crowd feed, Face ID capture. In the repo under
  `web/public/shots/`. They can be recut to any ratio.
- Device captures: Lock Screen with the Live Activity and an alert, Home Screen with the
  widgets, the alerts primer, the spot screen, a share card.
- The site, which renders well as a screenshot at 1440 and on a phone.
- The live API: `https://trydesk.trade/api/traders` (leaderboard, addresses, PnL, open
  positions) and `?view=crowd` (long/short per market). Real numbers, refreshed on request,
  quotable in posts as "right now on Perpl: …".

Coming this week: per-trader public pages — `trydesk.trade/t/<address>` — with a live OG
card showing that trader's PnL and positions and a "Copy on Desk" button. These are the
things we tag traders with.

## The loop we are building

1. A trader on Perpl's leaderboard gets a page that says they are winning.
2. We tag them with it. They share it, because it says they are winning.
3. Their followers install, copy them, and produce share cards.
4. The cards carry the QR back to the site.

Everything below feeds that loop.

## Research to do — return links

For each item: the link, why it matters, and what specifically to post or say there.
Verify each is active in September 2026; skip anything dormant.

### A. Where Monad people are
- Monad's official X account and the account that amplifies ecosystem builders during
  Metropolis. What are they retweeting this month, and in what format?
- Monad Discord: the builder channels, the Metropolis channel, and the rules on
  self-promotion.
- Monad's Farcaster channel(s), Telegram groups, and any Metropolis-specific community
  space (Agora's, if one exists).
- The Metropolis hackathon page: judging criteria, whether public traction is scored, and
  any showcase / demo-day slot we should apply for. Deadlines for each.

### B. Where Perpl people are
- Perpl's X account, Discord, docs, and any "built on Perpl" showcase.
- Who on X talks about trading on Perpl? Find 20 accounts that have posted a Perpl trade,
  PnL, or leaderboard screenshot in the last 60 days. Handle, follower count, what they
  posted. These are the first people to tag with trader pages.
- Does Perpl publish a leaderboard or weekly recap we can be part of?

### C. Who to reach
- 10–15 accounts in the Monad ecosystem with 5k–100k followers who cover new apps
  (not paid promoters — people who post about things they tried). What kind of post from
  us would they share?
- Any Monad ecosystem newsletters, "what's new on Monad" threads, or Dune-style
  dashboards that list apps.
- App-review-style accounts for mobile crypto apps, if any exist that are not pay-to-play.

### D. What works right now
- Five recent examples (last 90 days) of a small crypto app launching on X and getting
  real engagement. Link the thread. What was the structure — clip per tweet? one demo?
  a stat? Which got the ecosystem account's retweet?
- The current best-practice specs for X video: length, ratio, size, captions on or off,
  first-frame rules.
- What hashtags or phrases the Monad and Perpl communities actually use (not what a
  guide says).

### E. Hackathon-specific
- Past Monad hackathon winners in the trading category: what did their launch look like?
  What did they post, and when relative to the deadline?
- Any Metropolis "builder spotlight" form, submission of demo videos, or community vote.

## Drafts to write

Use the product language above. Short sentences. No emoji walls. Every claim must be one
that appears in this brief.

1. **X account setup** — three handle options if @desk / @trydesk are taken; a bio under
   160 characters; what the header image should show (I will render it); pinned post.
2. **Launch thread** — eight tweets, one recording each, in this order: the hook (copy the
   traders who are winning, with the leaderboard clip), Face ID sign-in, the crowd view,
   an alert landing on the Lock Screen, Auto-Copy pausing from the Dynamic Island, the
   widgets, the share card, the TestFlight link. Each tweet under 200 characters.
3. **Trader tag post** — the template for tagging a leaderboard trader with their page.
   Respectful, specific ("you're #3 on Desk this week, +$3.1K on ETH"), no ask beyond a look.
4. **Discord post** — for a builder channel: what it is, what's real, the TestFlight link,
   a request for testers. Under 120 words. Follows whatever self-promotion rule you found.
5. **Reply templates** — for "is this real money" (no, testnet, here's why), "where's the
   key" (in memory, never stored, here's the doc), "Android?" (no, iPhone, here's why).
6. **A daily post calendar for 21 days** — one post a day, alternating: a trader page, a
   product clip, a live number from the API, a share card someone posted. Each entry:
   day, format, the asset, the one-line caption.
7. **The submission blurb** — 100 words for the Metropolis form, and a 30-second demo
   video script (the long script is in `docs/demo-video.md`; this is the cut for X).

## What I need back

A single markdown document with the research sections A–E (links inline, one line of
"why" each) and the drafts 1–7. Flag anything you could not verify rather than filling
it in. If a community's rules forbid what we planned, say so and propose what they allow.
