# Server-side copying: system design

Status: design, branch `server-copy`, not shipped. This replaces section B of
[away-copying.md](away-copying.md) with a design detailed enough to build from.

## What it does

Auto-Copy keeps copying when the phone is off, the app is closed, iOS has killed it, or the
battery is dead. A server watches the traders a person copies, applies that person's rules
and guards, places the copy on their Perpl account, places its stops, closes it with the
trader, and sends a notification for every result. The app becomes the remote control and
the record, not the engine.

## The promise, restated

Today: *no server can trade for anyone.* With this on: *no server can trade for anyone who
did not turn this on, and no server can ever move money out.* Three facts carry that:

1. **The server's key can only trade.** It is a Perpl API key with scope 3 (read and trade).
   Withdrawals are `withdrawCollateral` calls signed by the wallet key, which is derived from
   the passkey on the phone, used for one action, and wiped. Perpl's key scopes cannot
   authorise a transfer out.
2. **Nobody holds the server's key, including Desk.** It is generated inside AWS KMS
   (`ECC_NIST_EDWARDS25519`) and never leaves it. The server asks KMS to sign each request;
   KMS logs every signature. A breach of the server can place trades while the breach lasts,
   bounded by the guards below, and cannot copy the key out.
3. **The person can cut it off without Desk.** Revoking the key at `app.perpl.xyz/apikeys`
   ends it at the venue, and Perpl never re-enrols a revoked key. From the app, one tap stops
   the engine and disables the key in KMS.

It is opt-in, off by default, explained in those words before the Face ID that enables it.

## Shape

```
 iPhone (Desk)                         Desk server (EU)                         Perpl / Monad
 ─────────────                         ────────────────                         ─────────────
 Enable: Face ID ─ wallet signs ──▶ /api/copy  ── creates key ──▶ AWS KMS
   EIP-712 enrolment + Desk grant        │       ◀── public key ──┘
                                         ├── api-key/payload, api-key/enroll ──▶ Perpl gateway
 Rules, pause ── signed by device ──▶ /api/copy (Vercel fra1, stateless)
   key (Secure Enclave)                  │
                                         ▼
                                     Redis: copiers, rules, baselines, open copies,
                                            intents, log, audit
                                         ▲
                                         │
                          copyd (Railway, EU, one leader)
                            ├─ chain watcher: eth_subscribe position logs ◀─ wss://rpc.monad.xyz
                            ├─ book reader: getAccountByAddr / getPositionV2 ◀─ exchange contract
                            ├─ planner (port of CopyPlanner, same vectors as Swift)
                            ├─ executor: signed REST orders ──▶ Perpl  (KMS signs)
                            ├─ fills: one trading socket per copier ◀── mt:24 / mt:26 / mt:27
                            └─ notifier: APNs alert + Live Activity ──▶ iPhone
```

Vercel answers requests; it cannot run a loop. The engine (`copyd`) is a long-running Node
process on Railway, next to the existing `desk-worker`, built from the same Dockerfile and
sharing `api/_*.mjs`. It must run in an EU region: Perpl answers 451 to US addresses.

## Enabling it (one Face ID)

1. The app asks `/api/copy?action=prepare` for a server key. The server creates a KMS key for
   this account (alias `alias/desk-copy/<chain>/<address>/<n>`; a new key every enrolment,
   never reused, as Perpl refuses revoked keys and Hyperliquid's docs warn against reuse), and
   requests `api-key/payload` from Perpl for that public key with scope 3 and label
   `Desk Auto-Copy (server)`. It returns Perpl's `typed_data` and `mac` verbatim, plus the
   public key.
2. The app runs the existing `SigningGuard` checks on the typed data (signer is this wallet,
   statement, domain, no undeclared fields, `publicKey` equals the key the server reported)
   and shows the opt-in sheet.
3. One Face ID derives the wallet key once and signs two things:
   - Perpl's EIP-712 enrolment, as today.
   - A Desk grant (EIP-191): account, chain, the server key, the app's device key (a P-256
     key in the Secure Enclave, created for this), the hard caps, and an issue time. The
     device key is what signs every later request, so routine changes need no Face ID.
4. `/api/copy?action=enroll`: the server recomputes the EIP-712 digest itself (chainId and
   time hashed as integers), checks the wallet signature recovers the account, checks the
   grant, signs the proof of possession over the raw digest **with KMS** (Ed25519 PureEdDSA
   over 32 bytes, `ED25519_SHA_512`, `MessageType RAW`), and posts `api-key/enroll` with
   `typed_data` and `mac` spliced byte for byte. The API-key token comes back once; it is
   stored sealed (AES-256-GCM under `COPY_TOKEN_KEY`, shared by Vercel and copyd), though it
   signs nothing on its own.
5. Hand-over: the app sends its open copies and its baselines, stops its own engine for this
   account, and from then on shows the server's state. An account is copied by the app or by
   the server, never both: the server holds a per-account lease, and the app's `CopyTrader`
   runs only when it holds no server lease.

Disable: one tap, signed by the device key. The server stops, cancels nothing (stops on the
venue keep protecting open copies), disables the KMS key at once and schedules its deletion,
and the app offers the Perpl revoke page. Re-enabling enrols a new key.

## Requests from the app

`/api/copy/<action>` is served by the `alerts` function (`?job=copy`, `web/api/_copy.mjs`), for
the Hobby plan's twelve-function cap; one slot is left and stays spare. `prepare` and `enroll`
take JSON; every request after enrolment sends its body as `text/plain`, exactly the bytes it
signed, and carries:

```
X-Desk-Network: mainnet|testnet   X-Desk-Account: 0x…   X-Desk-Time: <ms>
X-Desk-Nonce: <16+ random bytes, b64url>
X-Desk-Signature: P-256 (DER or raw r‖s, b64url) over
  "desk-copy\n{chainId}\n POST\n/api/copy/{action}\n{time}\n{nonce}\n{sha256 hex of body}"
```

the same canonical shape as Perpl's, signed by the Secure Enclave device key registered in the
grant (65-byte X9.63 point, b64url). Window ±60 s, nonce single-use for 2 minutes in Redis.
Actions: `state` (rules, open copies, last 100 log rows, the engine's last sweep), `rules`
(replace followed traders and their rules, guards, time zone), `pause`, `resume` (also clears
the engine's own `copy:pause`), `close` (`copy:close:<id>`, acted on at the engine's next
refresh), `disable` (retires the KMS key; the engine drops the copier). Raising a hard cap needs
a fresh wallet-signed grant, which means Face ID; lowering one does not.

The grant is plain text, line for line, so the server reads back exactly what was signed:

```
Desk Auto-Copy grant
I let Desk's server copy trades for this account within these limits.
Account: 0x…
Network: testnet
Server key: 0x<ed25519, 64 hex>
Device key: <P-256, b64url>
Max margin per trade: 50 AUSD
Max leverage: 10x
Max open copies: 5
Max open notional: 1000 AUSD
Max daily loss: 100 AUSD
Max orders per hour: 30
Issued: 2026-10-16T12:00:00.000Z
```

Rules are checked against it: margin per trade (doubled under conviction sizing) and leverage
per trader, open copies, daily loss and per-market exposure in the guards. `prepare` is limited
to six an hour per account (each can cost a KMS key) and reuses its key for 20 minutes; a key
nobody enrolled is retired when the next is made.

Environment (Vercel): `COPY_AWS_ACCESS_KEY_ID`, `COPY_AWS_SECRET_ACCESS_KEY` (desk-copy-api's),
`COPY_AWS_REGION` (eu-north-1), `COPY_TOKEN_KEY` (32 bytes, base64; copyd needs the same).

Proved on testnet on 16 Oct 2026 with real KMS and Perpl, through the handler: `prepare` (KMS
key and Perpl's payload, 1.3 s), `enroll` (Perpl registered the key, 0.5 s), signed `wallet`
and `positions` reads with the KMS key (200), a device-signed `state`, and `disable` (key
retired). A wallet with no Perpl account gets 404 from `api-key/enroll`; the API says to
deposit first.

## The engine

### Detection: events first, reads as truth

- One persistent `eth_subscribe` on the exchange's five position topics (opened V2, closed,
  liquidated, increased V2, decreased), the same filter the app uses. The account id is data
  word 2. An event for a watched account schedules a book read for that trader within 100 ms.
- Event contents are a hint only. The truth is the trader's book read off the contract
  (`getAccountByAddr`, then `getPositionV2` per bit), exactly as `traders.mjs` reads it today.
- A sweep re-reads every watched trader every 15 s regardless, so a dropped socket or a missed
  log costs at most 15 s, not a missed copy.
- Reconnect with 1 s doubling to 30 s; the sweep covers the gap.

### Baselines are persisted

The app keeps baselines in memory, so moves made while it is down are lost. The server stores
the last book per trader (`copy:base:<trader>`), so after a restart it diffs against what it
last saw. A move found that way is only acted on if its age is within the same freshness the
planner already applies through `maxChaseBps` (a stale open has usually chased past it), and
closes are always acted on: a copy should never outlive its trader's position because the
server restarted.

The C1 rule stays: a whole book reading empty when it was not needs two consecutive empty
reads; an unreadable book is never an empty one.

### Deciding: the same planner, proven equal

`copyd/planner.mjs` is a line-for-line port of `CopyRules`, `CopyGuards`, `CopyPlanner`,
`ShadowFill` and the move diff from `DeskKit/Sources/DeskFlow/CopyTrading.swift`, in BigInt
where Swift uses `Int128`, with every rounding direction kept (sizes floor, fees ceil,
triggers never fire early). It is tested against the same cases as `CopyTradingTests.swift`
with the same numbers. A shared fixture file both suites read is the next step, so the two
can never drift apart silently.

Server differences from the app, each deliberate:

| App today | Server | Why |
|---|---|---|
| Daily loss resets at the phone's local midnight | At the midnight of the time zone stored with the rules | The server has no "local"; the app sends `TimeZone.current.identifier` |
| A failed close is never retried | Retried with backoff until it succeeds, the position is gone, or 10 minutes pass, then a notification | No one is watching the screen to fix it |
| Stop/take send failure loses track of a filled open | Every order is an intent written before sending; a filled open is always tracked | Audit-grade bookkeeping |
| Live mark has no freshness check | Mark from the trader read, or market-state stream younger than 5 s, or skip | The server cannot see a frozen chart |

### Executing: intents, then orders

1. Write an intent `copy:intent:<copier>:<id>` = {trader, symbol, plan, created, state:
   `planned`} before anything is sent. Every state change is written before the next step.
2. Send the order over **REST** (`POST /v1/trading/orders`, `mt:30`), signed with KMS. REST
   needs no long-lived signed session per order and survives socket churn.
3. Confirmation over one trading socket per active copier (sign-in signed by KMS once per
   connection, 4 connections per wallet are shared with the phone and browser; the server uses
   one): `mt:24` for the order's fate, `mt:26/27` for positions. The tracking rules are the
   app's `OrderTracker` rules, ported: first non-failure answer decides, `st:7` holds until
   the retry window passes.
4. Stops and takes linked to the opener's `rq` (`tr`), sized at the planned size, as the app does.
5. If the process dies between steps, restart walks open intents: an intent sent but
   unresolved is reconciled against the positions stream with the app's late-fill adoption
   rules (new position on this market and side, size within the plan, no hand order to
   explain it), never re-sent blindly.

Built in `web/copyd/executor.mjs`: the engine awaits `quote` (the account's free balance off
`/v1/trading/wallet`, the mark from the trader's read) before deciding, holds a live copy as
`pending` in the open list, then hands it over. Per order: the grant's caps again (margin,
leverage, open copies, open notional, today's loss) and an hourly order count in Redis; the
intent (`copy:intent:<copier>:<copy>:open|close`) written as `planned`, then `sent`, then its
fate; the lease and halt checked again (`runner.mayAct`) right before the KMS signature; opener
plus stop and take in one `mt:30` batch, the triggers linked by `tr`. The copier's trading
socket (signed in with the KMS key, closed after a quiet minute) decides by the tracker's rules;
if it is silent for 20 s, `/v1/trading/positions` decides. Closes use close types for the
copy's size, and the result is margin-free P&L from the fills less both fees. On restart,
`reconcile` settles `pending` and `closing` copies from the positions endpoint, never by sending
again.

Proved live on testnet on 16 Oct 2026 (review wallet, KMS key in eu-north-1): a 10 AUSD 2x BTC
long with a 25% stop filled at 82,165.5 in 2.0 s, confirmed on the socket; the close filled at
82,162.1 in 1.5 s (P&L −0.014 AUSD, the fees); then `disable` retired the key.

`rq` is per account and shared with the phone and browser. The server uses
`max(lfr + 1, last + 1, Date.now())`. The app must learn to reseed from `lfr` and retry once on
`sr: 32` (the browser already causes this today), a change worth making on `main` regardless.

### Guards, enforced twice

- The person's guards, as in the app: max open copies, daily loss limit (pauses and latches),
  per-market notional exposure, chase limit, the per-trader rules.
- Server hard caps from the grant, which the device key cannot raise: margin per trade, total
  open notional, orders per hour, daily loss. Checked again immediately before signing, outside
  the planner, so a planner bug cannot exceed them.
- A global halt (`copy:halt` in Redis, and an env flag) checked before every signature.
- Only `desk-copyd` can call `Sign`, only on keys tagged `desk:purpose=auto-copy`, and only
  with Ed25519; `desk-copy-api`, which creates and retires those keys, is denied `Sign`
  outright. See AWS below.

### One engine at a time

Two engines would double every copy. `copyd` takes a leader lease in Redis (`SET NX PX 15000`,
renewed every 5 s, fenced with a token checked on every intent write). A process that loses
the lease stops signing before it stops anything else. One that takes it back forgets what it
held and loads again before acting, since another engine may have acted in between.

### Memory first, Redis as the record

The leader keeps its working copy in memory: copiers, who follows whom, open copies, baselines,
today's realised result per copier. It loads them once on taking the lease, decides in memory,
and writes what changed in one pipeline afterwards. A decision has no `await` between reading a
copier's state and changing it, so two traders read at the same moment can't both take a
copier's last slot or both count against the same loss allowance. Reads of one trader never
overlap; an event that lands mid-read gets one more read after it. The sweep reads 16 traders
at a time, and chain events go straight to their trader instead of waiting behind a sweep.

The API owns `copy:copier:*` and names a changed copier in `copy:dirty`; the engine reloads
those each tick. The engine's own pause (the daily loss limit) is `copy:pause:<id>`, which the
API deletes on resume, so neither side overwrites the other's writes.

Measured on 16 Oct 2026 against mainnet, in shadow mode, with simulated copiers each following
5 of the 15-21 accounts trading at that moment (mostly bots: the heaviest load there is), the
store at a 3 ms round trip, and the public RPC:

| Copiers | Sweep | Move to decision, p50 / p95 / max | Before this design |
|---|---|---|---|
| 1,000 | 1.4-2.1 s | 0.11 / 0.77 / 1.8 s | sweeps 12-72 s and growing, 15 s per move |
| 5,000 | 1.6-3.1 s | 0.19 / 1.4 / 2.8 s | not run |

The tail is the RPC (reads p95 1.3-1.7 s on rpc.monad.xyz); production needs a paid endpoint.
Redis volume follows decisions, not copiers: about 1-2 commands per copier per decision. Copiers
who follow bots that trade every 30 s generate millions of commands a day, so the engine's Redis
should be one billed by size, not by command (Railway Redis next to copyd, or an Upstash fixed
plan).

## Notifications

The server already speaks APNs (`_apns.mjs`). With server copying on, the copier's install
receives:

- **Copied** "Copied 0x52…20A: Long BTC 10×, 25 AUSD margin" (alert, collapse per copy)
- **Closed** "Closed with 0x52…20A: Long BTC +3.12 AUSD"
- **Stop / take** "Your BTC copy hit its stop: −6.25 AUSD"
- **Couldn't copy** with the planner's own sentence, once per trader per hour at most
- **Paused** "Today's copy losses reached your 50 AUSD limit, so Auto-Copy paused"
- **Engine down** "Auto-Copy hasn't run for 5 minutes" if the health check sees the leader
  lease lapse (sent by the existing worker, so it does not depend on the thing that failed)

Later: Live Activity updates over APNs `liveactivity` pushes, so the Auto-Copy activity on the
Lock Screen stays current with the app closed.

## Storage

Redis for state and locks, behind a small interface so a database can replace it. The engine
reads it once on taking the lease and writes only what changed; sweeps don't touch it. Keys:

| Key | What |
|---|---|
| `copy:copier:<chain>:<addr>` | grant, device key, KMS key id, token (encrypted), rules, guards, tz, paused |
| `copy:copiers` | set of enabled copiers |
| `copy:followers:<trader>` | set of copiers following a trader |
| `copy:base:<trader>` | last book read, with time |
| `copy:open:<copier>` | open copies |
| `copy:intent:<copier>:<id>` | order intents and their states |
| `copy:log:<copier>` | the Recent list (capped at 400, as the app) |
| `copy:audit:<copier>` | append-only: every signature requested, its canonical string hash, its result |
| `copy:dirty` | copiers the API changed since the engine last looked |
| `copy:pause:<copier>` | why the engine paused a copier (the daily loss limit); the API deletes it on resume |
| `copy:lease` | the leader lease |
| `copy:halt` | global halt |

The Upstash free tier is already spent by the worker (`RUNBOOK.md`); this needs the paid tier.

## AWS

One AWS account, in **eu-north-1 (Stockholm)**: EU, as Perpl requires. It is an AWS "new
experience" project, so it sits in an AWS-managed organisation whose guardrails refuse other
regions outright. Two IAM users, made by `web/copyd/iam/setup.sh` from the policies beside it:

| Identity | Used by | Allowed | Refused |
|---|---|---|---|
| `desk-copy-api` | Vercel `/api/copy` | create Ed25519 `SIGN_VERIFY` keys tagged `desk:purpose=auto-copy` and `desk:stage=pending`, name them `alias/desk-copy/*`, sign with a **pending** key (the enrolment's proof of possession), change a pending key to `enrolled`, read public keys, disable and schedule deletion | signing with any key not pending, taking a key back to pending, untagged or non-Ed25519 keys, other regions, aliases outside `desk-copy/`, untagging, key policies |
| `desk-copyd` | Railway `copyd` | `Sign` with `ED25519_SHA_512` on **enrolled** Desk keys, read public keys | signing with a pending key, creating, tagging, naming, disabling, re-enabling or deleting any key |

A key is pending from `prepare` until Perpl has registered it: the API alone can sign with it,
and only the proof of possession needs that, since a key Perpl hasn't registered can't trade.
`enroll` then tags it enrolled, a change IAM lets the API make one way and nobody undo, and from
then only copyd can sign with it. (The first deploy denied the API every signature, so enrolment
failed in production: the proof of possession is a signature too.) Policies are applied as new
versions with `web/copyd/iam/update.sh`; the 16 Oct 2026 set passed 15 of 15 simulated cases.
Tagging a key as it is created needs `kms:TagResource` over every key in the account (KMS
can't condition it on tags the key doesn't have yet), so the API may tag any key `pending`
Desk key, except an enrolled one. The account must hold only Desk's keys: a key of anything
else's there could be tagged pending and then signed with by a compromised API.

Neither has a password, and access keys are made only at deploy, straight into each host's
environment. Checked on 16 Oct 2026 with IAM's policy simulator, 20 of 20 cases as intended,
and with a real key: `kms.mjs` created one, signed REST and socket sign-in messages that verify
as Ed25519 (0.2-0.5 s per signature from Lagos), found it again by alias, retired it, and a
retired key refused to sign.

The account is on AWS's Free plan: $100 of credits and a six-month window (to April 2027), no
card charges, and it closes when either runs out. Keys cost about $1 a month each. Upgrade to
the Paid plan, with a budget alert, before copiers depend on it.

## Order of work

1. **Pure core** (this branch, first): planner port with the Swift vectors; Perpl REST
   canonical signing with a pluggable signer, matching `CanonicalVectors.json` byte for byte;
   enrolment digest and splicing with the EIP-712 vectors. No network, no keys.
2. ~~KMS signer and enrolment end to end on **testnet**~~: done 16 Oct 2026, through
   `/api/copy` (see Requests from the app). The app's side (Face ID, device key) remains.
3. Engine in **shadow** only, one copier, for a week, its log compared with the app's.
   Deployed 16 Oct 2026: the API on Vercel production, copyd on Railway (service `copyd`, one
   replica in europe-west4). Proved from the app in the simulator against production on
   testnet: Turn On with one (stub) Face ID enrolled the review wallet, the key went from
   pending to enrolled, the server took the phone's rules and the signed caps, the Auto-Copy
   screen showed the server's state, and Turn Off retired the key and handed copying back to
   the phone.
4. Live on testnet, with the halt and the disable path exercised first.
5. App: the opt-in sheet, device key, server-state screens (built 16 Oct 2026); `sr: 32`
   reseed still to do.
6. Mainnet, opt-in, after a week's soak.

## Open questions to settle with Perpl

- Does `api-key/payload` accept `expires_at` or `ip_cidrs`? A server key pinned to the
  engine's egress IPs and expiring after 30 days would narrow a breach further.
- Is there an API to revoke a key, so the app's disable can end it at the venue too?
- Confirm `POST /v1/trading/orders` response shape, and whether the trading socket's `mt:26`
  reaches every session of an account (the phone would then see server copies live).
- A builder ID for Desk's server orders, if Perpl wants attribution.
