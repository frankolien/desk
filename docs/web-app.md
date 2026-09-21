# Desk on the web

`trydesk.trade/app` is the desk in a browser: the same Perpl markets, the same spot
discovery, the same traders and wallets as the iPhone app, read from the same functions.
The web does not sign. Every order still happens in the app with Face ID; the web hands
the order over with the market, side, size and leverage already chosen.

## Reference

The structure follows Nova (`nov.ag`), read from its shipped bundle:

| | Nova | Desk web |
|---|---|---|
| Text face | Manrope variable (self-hosted, 200–800) | Manrope variable, same file, `/fonts/manrope-variable-latin.woff2` |
| Numbers | SF Pro Rounded → Manrope | `ui-rounded` → Manrope |
| Mono | system mono | Geist Mono (already shipped) |
| Ground | `#000` | `#000` |
| Sidebar / rail | `#080808` | `#080808` |
| Card | `#0d0d0d`–`#121212` | `#0f0f0f` |
| Chip | `#1a1a1a` | `#181818` |
| Line | white at 8% | white at 8% |
| Primary pill | white on black | white on black |
| Brand | Solana teal/purple | Monad purple `#836EF9`, deep `#5B48D6` |
| Up / down | `#22c55e` / `#ef4444` | `#2FD67B` / `#FF5C5C` |
| Radii | 16 cards, 999 pills, 10 chips | same |
| Chrome | 184px sidebar, 64px top bar, 40px live ticker | same |

Chain is Monad, collateral is AUSD, and perps are the first page.

## Pages

| Route | Page | Source |
|---|---|---|
| `/app`, `/app/trade/:market` | Trade. Market list on the left, chart in the middle, ticket on the right. Below the chart: Crowd, Trades, Top traders. | `/api/v1/markets`, `/api/v1/markets/{m}/candles`, `/api/traders?view=crowd`, `?view=top`, `/api/market-snapshot` |
| `/app/markets` | Perps table and Trending spot table with sparklines, risk chip, Trade button. Right rail: Signals. Footer: crowd lean bar. | `/api/v1/markets`, `/api/token-discovery`, `/api/traders?view=signals`, `?view=crowd` |
| `/app/token/:chainIndex/:address` | Token page: header stats, chart, Trades and Holders with names and faces, Buy/Sell panel, Risk card. | `/api/token-details`, `?view=risk`, `/api/market-snapshot`, `/api/traders?view=identity` |
| `/app/traders` | Leaderboard with names, open positions, PnL; Follow opens the app. | `/api/traders?view=top`, `?view=identity` |
| `/app/wallet/:address`, `/app/portfolio` | The wallet page: Portfolio, PnL, Positions, Closed, Activity. Portfolio without an address asks for one, or reads the injected wallet's. | `/api/activity?view=wallet` |
| Search (`/` key) | Tokens on every chain and people (`.nad`, `.eth`, `@handle`, address). | `/api/token-discovery?q=`, `/api/traders?view=lookup&q=` |

## Ticket

Long/Short, AUSD margin, leverage up to the market's `maxLeverage`, quick chips
$25 $50 $100 $250. The sentence is the app's: `Long BTC 5× · 100 AUSD margin · ~500 AUSD
size · liq 77,220 (5.0% away)`. Maths is the app's `OrderQuote` in floating point:

- notional = margin × leverage
- fee = notional × takerFee / 1e6
- backing = margin − fee
- liquidation (long) = entry − backing / size + entry × 100 / maintenanceMargin
- liquidation (short) = entry + backing / size − entry × 100 / maintenanceMargin
- distance = 1 / leverage − 100 / maintenanceMargin

The confirm is **Trade in Desk**: on iPhone it opens the App Store listing, on desktop a
QR to it. Nothing on the web can move money.

## New server routes

`GET /api/v1/markets` — every open Perpl market, ten-second cache:
`{ id, name, mark, prev, change, volume24h, openInterest, tvl, fundingRate, fundingIntervalSec,
maxLeverage, priceDecimals, sizeDecimals, makerFee, takerFee, maintenanceMargin }`.
Prices are decimal numbers. `fundingRate` is per interval as a fraction. Fees are in micros.

`GET /api/v1/markets/{market}/candles?bar=1m|5m|15m|1H|4H|1D` — OKX exchange candles for
the market's instrument, ascending `{ time, open, high, low, close, volume }`, one-minute
cache. A market without an instrument answers 404.

## Files

```
web/public/app/
  index.html        shell: sidebar, top bar, ticker, view, search, QR sheet
  app.css           tokens and components
  app.js            router, fetch, formatting, identity cache, shell behaviour
  views/*.js        one module per page, default export mount(el, params) → unmount
  vendor/           lightweight-charts 4.2.3, qrcode-generator 1.4.4
```

No build step. Same-origin fetches only, so the page's CSP allows no outside script or
connection; token images come from the CDNs the app already trusts.
