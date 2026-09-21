# Runbook

Everything below is run from `web/`. Nothing here needs a key from the phone: the server
holds no key that can trade or withdraw for anyone.

## Deploy

```sh
vercel deploy --prod --yes
```

Vercel Hobby allows 12 serverless functions; `api/` holds exactly 12 non-underscore
files. Adding a function means folding one first (relay-status lives inside relay-quote
as `?view=status`, reached through a rewrite in `vercel.json`).

## Roll back

```sh
vercel rollback            # interactive: pick the previous production deployment
vercel rollback <url>      # or name it
```

## Rotate a key

1. `vercel env rm NAME production` then `vercel env add NAME production` (paste the new value; never commit it).
2. `vercel deploy --prod --yes` — functions read env at cold start, so a redeploy is required.
3. The worker on Railway reads the same Redis and Hypersync keys: `railway variables --set NAME=value`, then `railway redeploy -y`.

Key names live in `vercel env ls`; the third parties each one talks to are listed in the
repository's `docs/` notes. The faucet key must never be one that holds anything on mainnet.

## Restart the worker

```sh
railway redeploy -y
```

The worker writes `wl:heartbeat` to Redis once per loop. Health turns `warn` when the
heartbeat is over 4 minutes old and `fail` past 10. A redeploy clears both within a minute.

## Health checks: `GET /api/v1/health` (page: `/status`)

| Check | Means | When it fails |
| --- | --- | --- |
| `redis:responseTime` | A `GET` against Upstash answered (critical) | Check Upstash status and `KV_REST_API_URL`/`KV_REST_API_TOKEN` in Vercel env. Every function that caches, limits or indexes depends on it. |
| `worker:heartbeatAge` | Seconds since the Railway worker last wrote `wl:heartbeat` (critical) | `railway logs`, then `railway redeploy -y`. If Redis is down this fails too; fix Redis first. |
| `monad-rpc:responseTime` | `eth_blockNumber` on `rpc.monad.xyz` (warn only) | Set `MONAD_MAINNET_RPC` to another provider and redeploy. Traders and wallets go stale until then. |
| `perpl:responseTime` | Perpl's public context endpoint (warn only) | Nothing to do on our side; the market list is cached for 10 minutes, then trader views answer 502. |
| `cron:lastRunAge` | Seconds since the last successful alerts scan (`alerts:lastScan`) | `warn` past 15 min, `fail` past 2 h, `unknown` if it never ran. Check the scheduler that calls `/api/alerts?job=scan` and `CRON_SECRET`. |

`fail` on a critical check answers 503; the report is memoised in Redis for 10 seconds
(`health:cache`), so probes cannot be used to load the upstreams.

## Logs

- Vercel functions: `vercel logs <deployment-url>` or the project's Logs tab. Runtime errors also show under Observability.
- Worker: `railway logs` (or the Railway service's Deployments tab).
- Redis: Upstash console shows commands per second and memory; there is no per-request log.
- Public API usage: `GET /api/v1/stats` (requests per day, tracked wallets, subscriptions — no addresses).
