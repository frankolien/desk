# Submission form · Description

Plain text for the form's Description field (limit 8,000 characters). Keep it in step with
`submission.md`; paste as is.

---

Desk is a native iPhone app for trading perpetuals on Monad where your face is the trading key, with the same account open in a browser at trydesk.trade. Every trade runs on Perpl, AUSD is the only money you see, and a Mera passkey is the only credential.

THE PROBLEM

Trading perps from a phone still means a seed phrase, a wallet app, an extension, and a web page wrapped in a shell. Copy-trading products are bots you cannot inspect: you learn whether they work by losing money. And the people worth following are visible on chain but hard to find, score and act on while you are in a trade. Stablecoin collateral should make all of this simpler, and mostly it has not.

THE SOLUTION

Sign in with Face ID. One passkey derives both the wallet that holds your AUSD and the key that signs your orders. The wallet key is derived again for each transaction and never stored. The order key, which cannot withdraw, is sealed to Face ID on this iPhone and leaves memory when Desk locks. No server can trade for anyone, including ours: the server pushes notifications, reads public chain data and indexes history, and never holds a key.

What you can do:

- Trade perps on Perpl mainnet. The ticket reads like a checkout: margin, liquidation price, fee, total and the price Perpl's live order book would fill you at. Hold to confirm, Face ID, filled. Market orders are immediate-or-cancel within a slippage limit, so they fill at once or not at all.
- Stay on the chart. Your position sits under it, your whole desk slides up over it, and other traders open as sheets over whatever you were doing.
- Follow traders who are actually winning. The leaderboard is read off the Perpl exchange contract; trade history and scores are indexed from the chain's own position events through Envio HyperSync. Each trader is scored out of 100 on win rate, profit factor and drawdown, weighted by the money actually at risk, so dust scalpers do not outrank real traders.
- Copy them, or fade them: shadow or live, fixed or conviction sizing, a leverage cap, price protection, stops and take profits placed on Perpl itself, a daily loss limit, per-market exposure caps and baskets of the leaderboard's best. Shadow fills at the real mainnet mark with real fees in the arithmetic and sends nothing, so a strategy is proven before money moves. Every copy records time to fill and slippage.
- Hear it the moment they trade. Push alerts with Copy Trade, View Trader and Mute on the notification; Copy Trade opens Desk on a filled-in ticket. A Live Activity in the Dynamic Island, widgets, a Control Center toggle and Siri phrases.
- Trade tokens too, bought with MON, with token pages that show holders, the live tape and who got in first. Tap a buyer and follow the wallet: Desk tells you when it swaps again, over a size you choose, and about every move it makes on Perpl. EVM only.
- Swap both ways: MON for AUSD to fund the desk, AUSD back to MON when a token buy needs gas, checked on Monad before Face ID signs and approving at most the amount typed.
- Read the market: news that mentions a market opens as a page inside Desk, and each market has a chat room.
- Take the money out with a receipt for every step on Monad's explorer.

The same desk in a browser. trydesk.trade/app signs in with the same passkey through WebAuthn's PRF extension and derives the same wallet and trading key in the tab. It shows the live order book beside the chart, your positions, and a portfolio that includes the AUSD held in your desk at the exchange. You can set up trading in the browser, place and close orders through a relay that forwards your signed requests and cannot sign, follow traders from a drawer over the page, and turn on browser push alerts: the browser is a seat in the same alerts scan as the phone. Keys live in memory for the tab and are wiped on lock, idle or close.

WHAT MAKES IT USEFUL

- No seed phrase, ever, and nothing to install beyond the app. The passkey is the account on the phone and in the browser.
- Honest numbers. Every figure that cannot be read says so instead of showing a stale value or a zero. An unreadable position book is never treated as an empty one. Every figure rounds the way that costs you.
- Copying you can see through. Shadow first, measured on every fill, protected on the venue rather than in the app.
- Real. Everything in the demo video happens on Monad mainnet with real money: deposit, trade, close, follow, swap, withdraw.
- Native. Swift 6 and SwiftUI on iOS 18.4+, Apple's own controls, Liquid Glass on iOS 26, haptics and hold-to-confirm on every order. Not a website in a shell.

HOW IT IS BUILT

A SwiftUI app and a local Swift package with seven targets whose boundaries carry meaning: the money arithmetic has no network by construction, chain, auth, Perpl and the copy engine are separate. The server is eleven Vercel functions and one Railway worker: market data, swaps, trader indexing, alerts to phones through Apple and to browsers through their push services. 542 Swift tests and 265 Node tests. Secrets exist only in the server's environment; nothing sensitive ships in the app. The repository is public; the TestFlight build is open.

Built for Monad Metropolis for Agora's Best Mobile Trading App on Monad, Perpl's Best Use of Perpl's API, and Mera, with passkeys as the only credential.

---

# Submission form · Go-to-market and user acquisition

Plain text for the form's "go-to-market and user acquisition strategy" field. Paste as is.

---

FIRST USERS

Three groups, in order. First, the traders already on Perpl's leaderboard. Desk reads every one of them off the exchange contract, scores them on their own record and lets other people follow and copy them. Nobody has to submit anything to appear, so the product has something to say to each of them on day one: here is your record, ranked. Second, the people who follow those traders on X and Discord, and Monad-native traders who want perps on a phone without a seed phrase, a wallet app or an extension. Third, people already holding AUSD or MON who have not traded perps because the setup was the obstacle: Face ID, one deposit, and the desk is open.

HOW WE REACH THEM

The trader loop. Each leaderboard trader gets a message with their own numbers, specific and respectful: where they rank this week, on what, with no ask beyond a look. Winning traders share a page that says they are winning. Their followers install Desk, follow them, copy them in shadow, and produce share cards: any open position renders a card over the user's own photo with a QR that opens Desk. Every card is an ad that a trader posted, not us. Per-trader public pages with a live record and a Copy on Desk button are the next build, and the loop is designed around them.

Perpl's community. Desk is not a competing exchange; it is a native mobile client and a discovery and copy layer that sends orders to Perpl and brings it new traders, which makes a repost from Perpl rational. Perpl's points snapshot lands weekly, so a weekly "what Desk sees on Perpl" post with live numbers from our public API is a natural cadence. Perpl's X replies and tournament threads are where the first twenty traders to contact are found, five a day, by hand.

Monad's channels. Monad Ecosystem and Monad Developers amplify working apps with a native clip and a TestFlight link, so the launch post is a thirty-second recording of the real thing: Face ID, a fill on mainnet, a trader copied in shadow. A tester request in the developer Discord, under its rules. A listing on the Monad App Hub. A newsletter pitch once there is tester evidence to show.

The browser as the front door. trydesk.trade needs no install: the live leaderboard, the order book and a trader's page are a link away, which is what gets shared and what search finds. The same passkey signs in there, and browser push alerts make the site a retention channel of its own: follow a trader in the browser, and the browser hears when they trade. A QR on the site hands off to the phone.

WHAT WE MEASURE

TestFlight installs from people who trade, completed shadow-copy sessions, share cards posted by real testers, and reposts from Monad or Perpl. Followers and impressions are diagnostics, not goals.

THE LINES WE KEEP

Perps are leveraged, so nothing we post implies returns: "copy the traders who are winning" describes a leaderboard, not a promise. A shadow result is always called a shadow result. No fabricated testimonials, no paid engagement, no cards with someone's photo unless they posted it themselves. Regions Perpl does not serve are not targeted.

SEQUENCE

During Metropolis: the TestFlight build, the launch thread, the first trader outreach, and the demo recorded on mainnet with real money. Through judging: weekly Perpl snapshots, cards from testers, the App Hub listing. After: App Store release, per-trader public pages, and the share-card loop running on its own.

---

# Agora bounty · Describe the core features of your trading app

Plain text for the Agora field (limit 8,000 characters). The brief asks how the app integrates
Mera passkeys, an AUSD balance and Perpl execution.

---

Desk is a native iPhone app for perpetuals on Monad, with the same account open in a browser at trydesk.trade. The three things the bounty asks about are not features bolted on; they are the whole shape of the app.

MERA: THE PASSKEY IS THE ACCOUNT

Create account is one tap and Face ID. A passkey is created on the device and its PRF output is the seed of everything: a fixed salt turns it into entropy, from which Desk derives the wallet that holds your AUSD (secp256k1, the standard Ethereum path) and the key that signs your orders (Ed25519, the key type Perpl's API expects). Nothing is typed, backed up or copied; there is no seed phrase, no wallet app and no extension.

The two keys are handled differently on purpose. The wallet key, which can move AUSD, is derived again for each transaction and never stored. The order key, which can place and close orders but cannot withdraw, is sealed in the keychain to the current Face ID enrolment of this iPhone and leaves memory when Desk locks or the phone locks. Signing is hold-to-confirm plus Face ID on every order. No server can trade for anyone, including ours: the server never holds a key.

Because the passkey lives in iCloud Keychain, the same account opens on the user's other Apple devices and in a browser. trydesk.trade/app signs in with the same passkey through WebAuthn's PRF extension against the app's relying party, which names trydesk.trade as a related origin, derives the same wallet and the same trading key in the tab, and wipes them on lock, idle or close. One credential, phone and browser, and the browser shows the same address, the same positions and the same AUSD.

Onboarding says the hard truth in plain words: lose the phone and its iCloud backup and the funds are gone.

AUSD: THE ONLY MONEY YOU SEE

The balance is AUSD, and only AUSD. Desk reads the wallet's AUSD from the token contract and what is in trading from the Perpl exchange account, and shows both: Wallet, In trading, and the total. The user can show the figure in nineteen currencies, dollars, euros, naira, cedi and more, through a rates function; trading itself stays in AUSD. Every figure rounds the way that costs the user, and any figure that cannot be read says so instead of showing a stale number or a zero.

Funding is a guided screen, not a list of links. Receive gives the address and a QR. Swap MON for AUSD quotes a route through 0x, simulates it on Monad and only then asks for Face ID; nothing is approved and only the MON sent can move. The swap runs the other way too, AUSD back to MON when a token buy needs gas, approving exactly the typed amount and nothing more. Open desk then sets up the Perpl account under one Face ID: approve the AUSD, create the account with the deposit, and allow the order key to forward orders. Deposit alerts tell the user the moment AUSD lands in the wallet. Withdraw moves AUSD back out with a receipt for every step on Monad's explorer. On testnet, Desk fetches test MON and claims 10,000 test AUSD from Agora's faucet contract itself, so a new tester is trading in a minute.

PERPL: WHERE EVERY TRADE RUNS

Orders are signed on the device with the passkey-derived key, which is enrolled with Perpl by an EIP-712 registration the wallet signs, and sent over Perpl's websocket. Each one is tracked frame by frame to a terminal phase: settled, rejected with a reason in plain words, or expired. A market order is immediate-or-cancel within a slippage limit, so it fills at once or not at all. The ticket reads like a checkout before anything is signed: margin, liquidation price, fee, total, and the price Perpl's live order book would fill at. Positions update live with the distance to liquidation; closing is a checkout too, with the AUSD coming back. The user's position sits under the chart and the whole desk slides up over it, so nothing takes a trader off the market.

Perpl is also the data. The leaderboard is read off the exchange contract. Trade history and a score out of 100 are indexed from the chain's own position events through Envio HyperSync, weighted by the money at risk so dust scalpers do not outrank real traders. Follow a trader and Desk pushes an alert the moment they open, add, trim or close, with Copy Trade on the notification. Copy them or fade them, in shadow first, with fixed or conviction sizing, a leverage cap, price protection, stops and take profits placed on Perpl itself, daily loss limits and per-market exposure caps. A websocket on Monad's RPC watches the exchange contract's position events, so a copy wakes as soon as the trader's block lands. Each market has its order book, its crowd of holders, its news read inside the app, and a chat room.

AROUND IT

Tokens on Monad and other EVM chains, bought with MON, with live tapes, holders and wallet profiles you can follow with alert thresholds. Home and Lock Screen widgets, a Live Activity in the Dynamic Island with a working pause, a Control Center toggle and Siri phrases. Swift 6 and SwiftUI on iOS 18.4+, Apple's own controls, Liquid Glass on iOS 26. 542 Swift tests and 265 server tests. Everything in the demo video happens on Monad mainnet with real money.

---

# Judge access instructions (private)

Plain text for the optional field. Passkeys are per device, so there is no shared login to hand
over; the steps below create a judge's own account in about a minute.

---

IPHONE

1. Install Desk from TestFlight: https://testflight.apple.com/join/zjQdZzMX (iOS 18.4 or later, iPhone).
2. Open Desk and tap "New here? Create an account". Face ID creates a passkey and the wallet on your device. There is no password and no seed phrase, so there are no test credentials to share; every judge gets their own account this way.
3. Pick a network in Settings > Network. Monad testnet is free: the Fund screen fetches test MON for fees and claims 10,000 test AUSD from Agora's faucet for you, then Open desk sets up the Perpl account under one Face ID. Monad mainnet ("Use real funds") works the same way with real AUSD: send at least 10 AUSD, or MON to swap in the app, to the address shown.
4. Trade: Home > any market > Long or Short, type an amount, set leverage, hold to confirm, Face ID. The position appears under the chart and in Your desk (the briefcase); close it from there.
5. Follow and copy: Signals > Top traders. Open a trader, Follow, then Auto-Copy with Shadow selected. Shadow copies price at the real mark and send nothing.
6. Everything else is on the tabs: tokens and wallets on Search, alerts and copying on Signals, balance, Add funds and Withdraw on Profile.

BROWSER

https://trydesk.trade/app needs no account to browse: markets with the live order book, the leaderboard, trader pages and token pages. To sign in, use Safari on a Mac signed into the same iCloud account as the iPhone (the passkey is there), or "Create an account" in the browser for a fresh one. Trading in the browser runs on Monad mainnet only.

CODE AND TESTS

Repository: https://github.com/frankolien/desk. Swift tests: swift test --package-path DeskKit (542 tests, no simulator needed). Server tests: cd web && node --test (265 tests). Build the app with xcodegen generate && open Desk.xcodeproj, scheme Desk. The public API is listed at https://trydesk.trade/api/v1.

The demo video was recorded on Monad mainnet with real money; the explorer links for its trades are in docs/submission.md in the repository.
