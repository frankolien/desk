# Runbook

Everything below is run from `web/`. Nothing here needs a key from the phone: the server
holds no key that can trade or withdraw for anyone.

## Deploy

```sh
vercel deploy --prod --yes
```

Vercel Hobby allows 12 serverless functions; `api/` holds 11 non-underscore files, so
one slot is free. Helpers start with `_` and do not count. A thirteenth function means
folding one into another first (relay-status lives inside relay-quote as `?view=status`,
reached through a rewrite in `vercel.json`).

## Roll back

```sh
vercel rollback            # interactive: pick the previous production deployment
vercel rollback <url>      # or name it
```

## Rotate a key

1. `vercel env rm NAME production` then `vercel env add NAME production` (paste the new value; never commit it).
2. `vercel deploy --prod --yes` — functions read env at cold start, so a redeploy is required.
3. The worker on Railway reads the same Redis and HyperSync keys, plus `HYPERSYNC_INDEX_TOKEN` for the trader index (it falls back to `HYPERSYNC_TOKEN`): `railway variables --set NAME=value`, then `railway redeploy -y`.

Key names live in `vercel env ls`; the third parties each one talks to are listed in the
repository's `docs/` notes. The faucet key must never be one that holds anything on mainnet.

## Restart the worker

```sh
railway redeploy -y
```

The worker runs four loops: the wallet rotation (`WORKER_PAUSE_MS`, default 90 s), the
fast lane for wallets with pushes (`WORKER_FAST_MS`, 12 s), the alerts scan
(`WORKER_SCAN_MS`, 60 s) and the trader index (`WORKER_INDEX_MS`, 15 min). The index runs
again after 15 s while it is catching up, and waits 1, 2, 4 and up to 30 minutes after
failures in a row. Nothing else schedules the scan or the index; GitHub's `scan.yml` only
reads health once an hour and turns red when something has stalled.

The rotation writes `wl:heartbeat` to Redis once per round. Health turns `warn` when the
heartbeat is over 4 minutes old and `fail` past 10. A redeploy clears both within a minute.

To run the index once by hand while the worker is down:

```sh
curl -fsS -H "Authorization: Bearer $CRON_SECRET" "https://trydesk.trade/api/alerts?job=index"
```

## Redis budget

Upstash's free tier allows 500,000 commands a month. The worker is the main user. The
alerts scan, the wallet rotation and the trader index each cost commands per run, so the
intervals above are the knobs: doubling `WORKER_SCAN_MS` or `WORKER_PAUSE_MS` roughly
halves that loop's share. A `/status` tab left open polls health every 30 seconds, which
costs about ten commands a poll. The Upstash console shows commands per day.

## Health checks: `GET /api/v1/health` (page: `/status`)

| Check | Means | When it fails |
| --- | --- | --- |
| `redis:responseTime` | A `GET` against Upstash answered (critical) | Check Upstash status and `KV_REST_API_URL`/`KV_REST_API_TOKEN` in Vercel env. Every function that caches, limits or indexes depends on it. |
| `worker:heartbeatAge` | Seconds since the Railway worker last wrote `wl:heartbeat` (critical) | `railway logs`, then `railway redeploy -y`. If Redis is down this fails too; fix Redis first. |
| `monad-rpc:responseTime` | `eth_blockNumber` on `rpc.monad.xyz` (warn only) | Set `MONAD_MAINNET_RPC` to another provider and redeploy. Traders and wallets go stale until then. |
| `perpl:responseTime` | Perpl's public context endpoint (warn only) | Nothing to do on our side; the market list is cached for 10 minutes, then trader views answer 502. |
| `cron:lastRunAge` | Seconds since the last successful alerts scan (`alerts:lastScan`) | `warn` past 15 min, `fail` past 2 h, `unknown` if it never ran. The worker calls `/api/alerts?job=scan` every minute: check `railway logs` and that `CRON_SECRET` is the same on Railway and Vercel. |
| `trader-index:lastAdvanceAge` | Seconds since the trader index last moved forward (`hist:advanced`), with the `block` it reached and how far `behind` it was (warn only) | `warn` past 45 min, `fail` past 3 h. `railway logs` shows `trader index failed` with the reason. A 429 means HyperSync is rate-limiting: set `HYPERSYNC_INDEX_TOKEN` to a token of its own. |

`fail` on a critical check answers 503; the report is memoised in Redis for 10 seconds
(`health:cache`), so probes cannot be used to load the upstreams.

## Logs

- Vercel functions: `vercel logs <deployment-url>` or the project's Logs tab. Runtime errors also show under Observability.
- Worker: `railway logs` (or the Railway service's Deployments tab).
- Redis: Upstash console shows commands per second and memory; there is no per-request log.
- Public API usage: `GET /api/v1/stats` (requests per day, tracked wallets, subscriptions — no addresses).

## Moderation

People report a room message (`POST /api/activity?view=chat-report`) or a Desk profile
(`POST /api/traders?view=profile-report`) from the app. Three distinct phones reporting the
same message hide it; three hidden messages from one poster in a day block that poster from
the rooms; three phones reporting a profile hide its Desk name and picture. Review and act
with the cron secret:

```
curl -H "Authorization: Bearer $CRON_SECRET" "https://trydesk.trade/api/activity?view=moderation"
curl -H "Authorization: Bearer $CRON_SECRET" -H "content-type: application/json" \
  -d '{"action":"unhide-message","id":"<id>"}' "https://trydesk.trade/api/activity?view=moderation"
```

Actions: `block-who` / `unblock-who` (`who`), `hide-message` / `unhide-message` (`id`),
`hide-profile` / `unhide-profile` (`address`). Look at the reports list once a day while the
rooms are open to the public; App Review expects action within 24 hours.

