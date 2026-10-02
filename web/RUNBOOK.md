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

The worker is a separate deploy. The Railway service `desk-worker` is not connected to
this repository, so a push to main does not redeploy it. Ship new worker code from `web/`,
which is linked to that service:

```sh
railway up --detach
```

It builds `Dockerfile` (named in `railway.json`), which copies only `api/` and `worker/`.
If `web/` is not linked on this machine, run `railway link` first and pick `desk-worker`.
`railway redeploy -y` restarts the build that is already there and does not pick up new
code. After a deploy, `railway logs` shows a `worker: … wallets` line for each rotation,
and `/status` shows the indexing worker and the trader index as pass.

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

This restarts the current build. New code needs `railway up` (see Deploy).

The worker runs four loops: the wallet rotation (`WORKER_PAUSE_MS`, default 90 s), the
fast lane for wallets with pushes (`WORKER_FAST_MS`, 12 s), the alerts scan
(`WORKER_SCAN_MS`, 60 s) and the trader index (`WORKER_INDEX_MS`, 15 min). The index runs
again after 15 s while it is catching up, and waits 1, 2, 4 and up to 30 minutes after
failures in a row. Nothing else schedules the scan or the index; GitHub's `scan.yml` only
reads health once an hour and turns red when the scan or the index has stalled or never
reported.

The rotation writes `wl:heartbeat` to Redis once per round. Health turns `warn` when the
heartbeat is over 4 minutes old and `fail` past 10. A redeploy clears both within a minute.

To run the index once by hand while the worker is down:

```sh
curl -fsS -H "Authorization: Bearer $CRON_SECRET" "https://trydesk.trade/api/alerts?job=index"
```

## Redis budget

Upstash's free tier allows 500,000 commands a month, about 16,000 a day. **At the default
intervals the worker alone uses several times that.** Upgrade the Upstash plan, or raise
the intervals as below and accept slower alerts.

What each loop costs, counted from `worker/index.mjs`, `api/alerts.mjs`, `api/_ledger.mjs`
and `api/_history.mjs`:

| Loop | Knob, default | Commands per run | Per day at the default |
| --- | --- | --- | --- |
| Wallet rotation | `WORKER_PAUSE_MS`, 90 s | 4, plus 2 for each wallet it indexes (up to 12 a round; each wallet at most once every 5 minutes) | 26,880 once 12 or more wallets are tracked |
| Fast lane | `WORKER_FAST_MS`, 12 s | 1 for each wallet with pushes, plus a write for it every 2 minutes; the list of those wallets is read once a minute | 1,440, plus about 7,900 for each wallet with pushes |
| Alerts scan | `WORKER_SCAN_MS`, 60 s | 5 with no subscriptions; otherwise 10, plus 1 per followed or copied trader whose position sizes changed (an unchanged one is rewritten every 5 minutes), plus 2 if any wallet has pushes, plus 1 read and 1 write per trader that moved, plus 1 for the deposit cursor when a deposit arrives (otherwise every 10 minutes) | 7,200 with no subscriptions |
| Trader index | `WORKER_INDEX_MS`, 15 min | about 10, plus 1 per shard it touched (up to 16) and 1 per account that closed a trade | roughly 2,000 to 4,000 |

Today `GET /api/v1/stats` reports 65 tracked wallets and one alert subscription. If that
subscription follows five traders and has pushes on for three wallets, the worker spends
about 74,000 commands a day: 26,880 rotation, 25,200 fast lane, 18,720 scan and about
3,000 index. That is about 2.2 million a month, over four times the free tier. A wallet
followed in Signals is also followed as a Perpl trader, so each one adds about 290 a day. With no
subscriptions at all it is still about 38,000 a day. While the trader index is catching up
(more than 1,500 blocks behind) it runs again 15 s after each run instead of every 15
minutes, which can cost more than everything else together until it reaches the tip.

To fit the free tier at that load, set:

```sh
railway variable set WORKER_PAUSE_MS=300000 WORKER_FAST_MS=600000 WORKER_SCAN_MS=600000 WORKER_INDEX_MS=1800000
```

Setting variables redeploys the worker. The same load then costs about 14,000 commands a
day, about 420,000 a month: 8,064 rotation, 1,008 fast lane, 2,448 scan and about 2,400
index. The price: trade alerts, wallet alerts and away-copying wakes can arrive up to 10
minutes late instead of 1, and the indexing worker check reads `warn` for about the last
minute of each 5-minute round. The scan and index checks stay `pass` (their warn lines are
15 and 45 minutes).

Everything else that uses Redis comes on top. Each `/api/v1` request costs 3 or 4 commands
for its rate limit and counter, and a `/status` tab left open polls health every 2 minutes
at about ten commands a poll, about 7,000 a day. So those values fit only while API traffic
stays low; upgrading the plan is the real fix. The Upstash console shows commands per day.

## HyperSync budget

The free tier allows 30 requests a minute, shared by the wallet rotation, the fast lane,
the trader index and deposit alerts. Deposit alerts make one query per network per scan,
and only while some subscription names its Desk wallet: two a minute at the default scan.
They read `HYPERSYNC_INDEX_TOKEN` (or `HYPERSYNC_TOKEN`) on Vercel. The cursor lives in
`alerts:rx`; when it is missing or over an hour old the next scan restarts at the tip with
one height request and sends nothing. A query that fails or takes over 8 s keeps the cursor,
skips deposits for that scan, and shows in `railway logs` as `worker: scan skipped receipts …`.

## Health checks: `GET /api/v1/health` (page: `/status`)

| Check | Means | When it fails |
| --- | --- | --- |
| `redis:responseTime` | A `GET` against Upstash answered (critical) | Check Upstash status and `KV_REST_API_URL`/`KV_REST_API_TOKEN` in Vercel env. Every function that caches, limits or indexes depends on it. |
| `worker:heartbeatAge` | Seconds since the Railway worker last wrote `wl:heartbeat` (critical) | `railway logs`, then `railway redeploy -y`. If Redis is down this fails too; fix Redis first. |
| `monad-rpc:responseTime` | `eth_blockNumber` on `rpc.monad.xyz` (warn only) | Set `MONAD_MAINNET_RPC` to another provider and redeploy. Traders and wallets go stale until then. |
| `perpl:responseTime` | Perpl's public context endpoint (warn only) | Nothing to do on our side; the market list is cached for 10 minutes, then trader views answer 502. |
| `cron:lastRunAge` | Seconds since the last successful alerts scan (`alerts:lastScan`) | `warn` past 15 min, `fail` past 2 h, `unknown` if it never ran. The worker calls `/api/alerts?job=scan` every minute: check `railway logs` and that `CRON_SECRET` is the same on Railway and Vercel. |
| `trader-index:lastAdvanceAge` | Seconds since the trader index last moved forward (`hist:advanced`), with the `block` it reached and how far `behind` it was (not critical) | `warn` past 45 min, `fail` past 3 h. `railway logs` shows `trader index failed` with the reason. A 429 means HyperSync is rate-limiting: set `HYPERSYNC_INDEX_TOKEN` to a token of its own. |

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

