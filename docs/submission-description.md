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
