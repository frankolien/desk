# Desk on the web

`trydesk.trade/app` is the desk in a browser: the same Perpl markets, the same spot
discovery, the same traders and wallets as the iPhone app, read from the same functions.
Signed in with the passkey, it trades: the browser derives the same keys the phone does,
signs every Perpl request itself and sends it through the API's relay, which forwards it
unchanged and cannot sign. Without a passkey session the web is read-only, and the ticket
hands the order to the app with the market, side, size and leverage already chosen.

## Sign in

The passkey is the account, on the web as in the app. **Sign in with your passkey** runs the
WebAuthn ceremony against the app's relying party, `desk-trading-opia.vercel.app`, with the PRF
extension evaluated over Mera's salt; the 32 bytes that come back are BIP-39 entropy, the
wallet is secp256k1 at `m/44'/60'/0'/0/0` and the trading key is Ed25519 at
`m/44'/501'/{index}'/0'` by SLIP-10, exactly as `DeskAuth` derives them (`web/test/keys.test.mjs`
pins both to the same vectors). `trydesk.trade` may use that relying party because it publishes
`/.well-known/webauthn` naming this origin (WebAuthn related origins); a browser without that
support is sent to the relying party's own origin, where the same page runs.

The keys live in memory for the tab and nothing else: fifteen minutes idle, closing the tab or
**Lock** in the wallet menu wipes them, and the pill's dot shows which state they are in. The
address stays known so the page still reads as that wallet while locked. **Create an account**
makes the passkey here; on an iPhone with the same iCloud account the app then signs in with it.

The cryptography (`@noble`, `@scure`, a slice of viem) is bundled once into
`public/app/vendor/desk-crypto.js` from `tools/crypto-entry.mjs`; the command is in that file.

## Trading

The big button says what it will do. Without a wallet: **Connect wallet**. With a watched or
browser wallet: **Long BTC in Desk**, the app handoff. With a passkey account whose keys left
the tab: **Unlock to trade**. Unlocked but this browser has no Perpl key yet: **Set up trading
here**, which asks the chain whether the wallet has an account; with one, a single public
enrolment signed by the wallet and the trading key follows, nothing deposited. Without one
Perpl will not enrol a key, so the desk card opens instead: **Open your desk**.
Otherwise **Long BTC**.

An order is a market order, immediate-or-cancel within 50 basis points (or the market's cap),
built the way `OrderBuilder.market` builds it: `t` 1 or 2, `p` 0, `fl` 4, `lv` in hundredths,
`lb` 0, `ms` the bound, `rq` one past the account's last forwarded id. It is signed with the
trading key over `[143, POST, /v1/trading/orders, timestamp, nonce, sha256(body)]` and posted
through `/api/v1/perpl/trading/orders`. Perpl answers accepted or refused at once; the page
then reads `/v1/trading/positions` once a second for up to twelve seconds and reports the fill
it finds, or says that none has shown. Closes use types 3 and 4 with leverage 100 and the
position's whole size. While the keys are in the tab the Positions tab reads the desk's own
positions from Perpl with a **Close** on each, and the line under the title uses them too.

The desk card under the ticket shows the account's collateral, the wallet's AUSD and **Add
funds** (approve if the allowance is short, then `depositCollateral`). Without an account it
is the opening form: approve, `createAccount(deposit)`, `allowOrderForwarding(true)`, then the
key enrolment, each step with its receipt. Transactions are signed by the wallet key in the
tab and sent to `rpc.monad.xyz` with DeskChain's gas policy (estimate padded 7.5%, never
doubled). Withdrawals stay in the app for now.

The API key: `POST /v1/api-key/payload` with the trading key's public key, scope 3 and the
label "Desk on the web"; the typed data and mac come back and go into `/v1/api-key/enroll`
byte for byte, with the wallet's EIP-712 signature and the trading key's proof of possession
over the same digest. The token is kept in this browser per wallet, the way the phone keeps
its own in the keychain, and is useless without the trading key. Perpl never re-enrols a
revoked key, so a refusal moves to the next derived index inside the session.

The relay, `GET|POST /api/v1/perpl/{path}`, forwards only `pub/context`, `trading/*` and
`api-key/*`, copies the four signed headers and the body as received (the page sends it as
`text/plain` so nothing re-parses it), returns Perpl's status and body as they came, and
caches nothing. Perpl refuses browser origins other than its own and answers its trading
endpoints with 451 from United States addresses, which is why the relay exists and why the
functions are pinned to Frankfurt (`regions` in `vercel.json`).

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
| `/app`, `/app/trade/:market` | Trade. Market list on the left (watched markets first), chart in the middle, ticket on the right with the order book under it (nine levels a side, spread and mid, a depth bar behind each level) and News below that. The ticket's Est. fill walks the book for the size typed. Below the chart: Positions (the connected or watched wallet's open Perpl positions, this market first, Manage in Desk on each row), Crowd, Top traders, Trades. When the wallet holds this market, a line under the title says so with the PnL. | `/api/v1/markets`, `/api/v1/markets/{m}/candles`, `/api/traders?view=trader`, `?view=crowd`, `?view=top`, `/api/market-snapshot`, `?view=news` |
| `/app/markets` | Perps table and Trending spot table with sparklines, risk chip, Trade button. Right rail: Signals. Footer: crowd lean bar. | `/api/v1/markets`, `/api/token-discovery`, `/api/traders?view=signals`, `?view=crowd` |
| `/app/token/:chainIndex/:address` | Token page: header stats, chart, Trades and Holders with names and faces, Buy/Sell panel, Risk card. | `/api/token-details`, `?view=risk`, `/api/market-snapshot`, `/api/traders?view=identity` |
| `/app/traders` | Leaderboard with names, open positions, PnL; Follow opens the app. Any person anywhere opens in a drawer over the current page (positions, closed trades, win rate, Follow, Full page); `?person=0x…` on any route opens one. | `/api/traders?view=top`, `?view=identity`, `?view=trader`, `?view=history` |
| `/app/wallet/:address`, `/app/portfolio` | The wallet page: PnL, Positions, Closed, Activity. Positions lists what the wallet holds and, as its own AUSD row, what Perpl holds for it in its desk, read from the exchange contract; In trading and Wallet AUSD cells sit above. Portfolio is the connected or watched wallet's own page, and asks to connect when there is none; another wallet's page is reached only by its address, from the drawer's Full page. | `/api/activity?view=wallet` |
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

An optional take profit and stop loss, as prices. Each is checked against the side and the
liquidation price before anything is shown (a long's stop sits below the mark and above
liquidation, its take profit above the mark); a valid one reads as the return on margin and the
move it needs, and both ride along in the sentence.

Keys work anywhere outside a field: `L` and `S` pick the side, `1`–`9` the leverage, `P` the
Positions tab.

The confirm is **Trade in Desk**: on iPhone it opens the App Store listing, on desktop a
QR to it. Nothing on the web can move money.

## New server routes

`GET /api/v1/markets` — every open Perpl market, ten-second cache:
`{ id, name, mark, prev, change, volume24h, openInterest, tvl, fundingRate, fundingIntervalSec,
maxLeverage, priceDecimals, sizeDecimals, makerFee, takerFee, maintenanceMargin }`.
Prices are decimal numbers. `fundingRate` is per interval as a fraction. Fees are in micros.

`GET /api/v1/markets/{market}/book?levels=1..100` — Perpl's public L2 snapshot with prices and
sizes in decimals: `{ market, at, bids: [{ price, size, orders }], asks: [...] }`, two-second cache.

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

## Live

Neither venue sells a socket the web can use: OKX's DEX websocket needs a paid market
subscription and Perpl's trading socket is sign-in only. So the page polls, and the CDN
answers most of it:

| What | Source | Every |
|---|---|---|
| Perp marks (ticker, Trade page, Live 10s sparks) | `/api/v1/markets/marks`, read off the exchange contract, 2 s CDN cache | 2 s |
| Spot prices for a table or a token | `/api/token-details?view=prices&tokens=…` (one OKX call for 20 tokens, 3 s cache) | 4 s |
| A token's tape | `/api/market-snapshot?…&limit=100`, 3 s cache | 5 s |
| Candles | `/api/v1/markets/{m}/candles`, `/api/market-snapshot` | 15 s, with the last bar following ticks in between |
| The order book | `/api/v1/markets/{m}/book?levels=9`, 2 s CDN cache. Perpl's market-data socket refuses browser origins other than its own, so the page tries it only as an upgrade | 2 s |
| The wallet's positions | `/api/traders?view=trader&address=…`, private cache | 10 s |
| News for the market | `/api/market-snapshot?view=news&symbols=…`, 5 min CDN cache | 5 min |

Faces on charts: the Token page draws the last 60 trades at their price and bar, buys
ringed green and sells red, with the trader's name and face where one is known; the
Trade page draws the top traders' entries the same way, entry blocks turned into times
with the head block and block time from `/api/v1/markets`.

Who got in first: `/api/token-details?view=early` reads a Monad token's launch from
HyperSync — snipers (first 20 buyers within 200 blocks), bundles (three or more wallets
funded from one sender in one block), insiders (the creator and everyone it sent tokens
to) — with what each still holds. Contracts (curve, pool, lockers) are filtered out.
