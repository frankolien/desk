# A wallet is a resource, and its history is a ledger

`GET /api/activity?view=wallet&address=0x…[&chainIndex=&contract=]` answers everything
the app shows about a wallet: identity, holdings on every chain OKX reads, and a trade
ledger on Monad with realised and unrealised PnL. The app has one model for it. The
sources behind it can change without the app changing.

## What the ledger is

Every ERC-20 Transfer touching the wallet, read from HyperSync and grouped by transaction:

| Movement | Meaning | Priced? |
|---|---|---|
| tokens in and out, any sender | swap | yes, both legs at the minute |
| tokens in, wallet sent the tx | buy (paid in MON) | yes |
| tokens out, wallet sent the tx, not a plain `transfer()` | sell for MON | yes |
| tokens in, someone else sent the tx | received | no — held, excluded from PnL |
| tokens out, plain `transfer()` or to Perpl / faucet / Relay | sent, deposit | no |

Prices come from the OKX candle covering the minute (then hour, then day), cached by
hour in Redis. Cost basis is weighted average, as Codex does. A sell realises against
it; tokens without a basis leave first and never touch PnL, as Zerion does. Win rate
is sells at or above basis over all decided sells, and over 7 and 30 days.

The ledger keeps a block cursor. The first look at a wallet indexes 45 days on demand,
within the function's budget; the worker continues from the cursor and keeps every
opened wallet at the tip.

## Where it runs

- **Vercel** answers the resource and does the first index when it fits in the budget.
- **Railway** (`web/worker/index.mjs`, Dockerfile in `web/`) is the person at the back:
  every wallet in `wl:tracked` is brought to the tip, round after round. It prices
  through Desk's own `token-details?view=candle` so the OKX key stays on Vercel.
- **Upstash Redis** holds ledgers (`wl:<address>`), token metadata (`tk:`), hourly
  prices (`px:`) and the tracked set. All three share it.

## Limits, plainly

- Monad only. Other chains show balances and the live window, not history.
- Wallets that never send a transaction (contracts, relayed embedded wallets) show
  received tokens as held, not bought. Swaps still price because both legs move.
- A token OKX has no candle for is held unpriced. It shows in holdings, not in PnL.
- HyperSync's free tier rate-limits when the worker, the on-demand index and the alerts
  index overlap. The worker backs off and leaves fresh wallets alone; the page says
  "still indexing" rather than nothing.
- 45 days of history. Older buys have no basis, so a sale of them is excluded rather
  than counted as pure profit.

## If it grows

The same code runs the same way with more wallets; the knobs are the worker's round
pause and per-wallet budget. Past a few thousand tracked wallets, shard the tracked set
across workers by address prefix. A paid HyperSync tier removes the rate limit.

## Solana

A Solana wallet has the same ledger, written only by the worker. It reads the public
RPC: each new signature's transaction, the wallet's own token balances before and after,
and the lamports it paid or received. SOL, wrapped SOL, USDC and USDT legs say which way
money went and are never positions; the asset leg is priced from the OKX candle as on
Monad. After each transaction the position is reconciled to the balance the chain
reports, so tokens bought before Desk looked are held without a basis, and a sale of
them is recorded with its value and no gain. The cursor is the last signature applied.
The first look takes the newest page of signatures, not the wallet's whole life.

`SOLANA_RPC` on the worker overrides the public endpoint.
