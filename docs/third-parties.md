# Third parties Desk talks to

Every key lives in Vercel's environment and is used only by the functions in `web/api`.
The app never holds a secret; it talks to Desk's own functions and to public chain
endpoints. Sources are listed by what they are for.

## Trading venue

| Service | Used for | Where | Key |
|---|---|---|---|
| Perpl — `app.perpl.xyz`, `testnet.perpl.xyz` (REST context + trading/market websockets) | Markets, prices, order placement, positions, the mainnet leaderboard, trade history | App (trading), `traders.mjs`, `alerts.mjs`, `_history.mjs` | none |
| Monad RPC — `rpc.monad.xyz`, `testnet-rpc.monad.xyz` | Reading the Perpl exchange contract, balances, sending transactions | App, `traders.mjs`, `activity.mjs`, `faucet.mjs` | none (optional `MONAD_MAINNET_RPC`, `MONAD_TESTNET_RPC`) |
| Envio HyperSync — `143.hypersync.xyz` | Indexing Perpl fills for trader history and scores | `_history.mjs`, `alerts.mjs` | `HYPERSYNC_TOKEN` |
| Monad faucet — `faucet.monad.xyz` | Testnet gas for new accounts | `faucet.mjs` | `FAUCET_PRIVATE_KEY` (Desk's own testnet wallet) |

## Spot tokens

| Service | Used for | Where | Key |
|---|---|---|---|
| OKX DEX API — `web3.okx.com`, `wsdex.okx.com` | Trending tokens, token details, candles, holders, live trades, swap quotes | `token-discovery.mjs`, `token-details.mjs`, `market-snapshot.mjs`, `market-stream.mjs`, `swap-quote.mjs`, `_holdings.mjs` | `OKX_API_KEY`, `OKX_SECRET_KEY`, `OKX_PASSPHRASE` |
| 0x — `api.0x.org` | Swap quotes on chains OKX does not quote | `swap-quote.mjs` | `ZEROX_API_KEY` |
| Relay — `api.relay.link` | Cross-chain buys: quote, execute, status | `relay-quote.mjs`, `relay-status.mjs`, `activity.mjs` | optional `RELAY_API_KEY` |
| Public RPCs — Base, Optimism, Arbitrum, Polygon, BNB, Avalanche, Linea, Scroll, Mantle, Berachain, Sonic, Unichain, Ink, Abstract, Plasma, Tempo, Robinhood Chain, World Chain (Alchemy), Solana | Reading balances of tokens bought through Desk, on the token's own chain | `_chains.mjs`, `_holdings.mjs` | none |
| Etherscan v2 — `api.etherscan.io` | Wallet activity across chains | `activity.mjs` | `ETHERSCAN_API_KEY` |
| CoinGecko asset CDN — `assets.coingecko.com`, `coin-images.coingecko.com` | Token logo images only | App | none |
| Open Exchange Rates mirror — `open.er-api.com` | Currency conversion for the balance display | `fx.mjs` | none |

## Who a wallet is

| Service | Used for | Where | Key |
|---|---|---|---|
| Nad Name Service — `api.nad.domains` | `.nad` primary name and avatar | `_identity.mjs` | none |
| nad.fun — `api.nad.fun` | nad.fun profile: nickname, picture, bio | `_identity.mjs` | none |
| ENS via Ethereum mainnet RPC — `ethereum-rpc.publicnode.com` | ENS name, avatar, X handle | `_identity.mjs` | none (optional `ETHEREUM_RPC`) |
| Neynar — `api.neynar.com` | Farcaster account by verified address | `_identity.mjs` | `NEYNAR_API_KEY` |

## Push, storage, AI

| Service | Used for | Where | Key |
|---|---|---|---|
| Apple Push Notification service — `api.push.apple.com`, sandbox | Trade alerts and the silent wake for away copying | `_apns.mjs`, `alerts.mjs` | `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_TOPIC` |
| Upstash Redis (Vercel KV) | Alert subscriptions, trader history shards, identity and summary caches | `_store.mjs` | `KV_REST_API_URL`, `KV_REST_API_TOKEN` |
| Anthropic — `api.anthropic.com` (claude-haiku-4-5) | One-paragraph trading-style summary on a trader's Stats tab, cached a day; falls back to figures without it | `traders.mjs` | `ANTHROPIC_API_KEY` |

## Links only (no data read)

`monadvision.com`, `testnet.monadexplorer.com`, `relay.link`, `nad.fun`, `app.nad.domains`,
`app.ens.domains`, `warpcast.com`, `x.com` — opened in the browser from the app.

## Scheduling

`.github/workflows/scan.yml` calls `/api/alerts?job=scan` and `?job=index` with
`Authorization: Bearer $CRON_SECRET`. GitHub fires it every five minutes at best; an
external one-minute scheduler is the production answer.
