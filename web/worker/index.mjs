import { hypersyncClient, indexWithLock } from "../api/_history.mjs";
import { HEARTBEAT_KEY, TRACKED_KEY, URGENT_KEY, WATCHED_KEY, indexWallet, ledgerKey } from "../api/_ledger.mjs";
import { SOLANA, indexSolanaWallet, isSolanaAddress, solanaMetaReader, solanaRpc } from "../api/_solana.mjs";
import { redisStore } from "../api/_store.mjs";
import { metaReader, priceReader } from "../api/_wallet.mjs";
import { openMarkets } from "../api/traders.mjs";
import { indexBackoffMs, selectWallets } from "./queue.mjs";

const ROUND_PAUSE_MS = Number(process.env.WORKER_PAUSE_MS || 90_000);
const FAST_PAUSE_MS = Number(process.env.WORKER_FAST_MS || 12_000);
const SCAN_PAUSE_MS = Number(process.env.WORKER_SCAN_MS || 60_000);
const INDEX_PAUSE_MS = Number(process.env.WORKER_INDEX_MS || 15 * 60_000);
const PER_WALLET_BUDGET_MS = 20_000;
const FAST_BUDGET_MS = 8_000;
const BACKFILL_BLOCKS = 45 * 216_000;
/// The rotation skips a wallet brought to the tip this recently; HyperSync's free tier rate-limits.
const FRESH_MS = 5 * 60_000;
const FAST_QUIET_MS = 2 * 60_000;
const WATCHED_REFRESH_MS = 60_000;
const BACKOFF_MS = 60_000;
const INDEX_CATCHUP_BLOCKS = 1_500;
const INDEX_CATCHUP_MS = 15_000;
const INDEX_LOCK_S = 120;
let queueCursor = 0;

const store = redisStore();
const hypersync = hypersyncClient();
const solana = solanaRpc();
if (!store || !hypersync) {
  console.error("worker: KV_REST_API_URL, KV_REST_API_TOKEN and HYPERSYNC_TOKEN are required");
  process.exit(1);
}
const ownIndexToken = Boolean(process.env.HYPERSYNC_INDEX_TOKEN);
const indexHypersync = ownIndexToken ? hypersyncClient({ token: process.env.HYPERSYNC_INDEX_TOKEN }) : hypersync;
if (!process.env.CRON_SECRET) console.error("worker: CRON_SECRET is missing, so alerts will not be scanned");

const DESK_API = process.env.DESK_API || "https://web-lovat-nine-49.vercel.app";
const bearer = { authorization: `Bearer ${process.env.CRON_SECRET ?? ""}` };
async function fetchCandles(path, params) {
  const query = new URLSearchParams({ view: "candle", chainIndex: params.chainIndex, contract: params.tokenContractAddress, bar: params.bar, after: params.after });
  const response = await fetch(`${DESK_API}/api/token-details?${query}`, { headers: bearer });
  if (!response.ok) throw new Error(`candles ${response.status}`);
  return (await response.json()).rows;
}

let stopping = false;
const sleepers = new Set();
function stop() {
  stopping = true;
  for (const wake of [...sleepers]) wake();
}
process.on("SIGTERM", stop);
process.on("SIGINT", stop);

const sleep = (ms) => new Promise((resolve) => {
  const wake = () => { clearTimeout(timer); sleepers.delete(wake); resolve(); };
  const timer = setTimeout(wake, ms);
  sleepers.add(wake);
});

const readers = {
  price: priceReader({ store, fetchCandles }),
  meta: metaReader({ store }),
  solPrice: priceReader({ store, chainIndex: SOLANA, fetchCandles }),
  solMeta: solanaMetaReader({ store, api: DESK_API }),
};

// One indexer at a time: both lanes share HyperSync's and the RPC's patience.
let turn = Promise.resolve();
function exclusive(work) {
  const run = turn.then(work, work);
  turn = run.catch(() => {});
  return run;
}

function indexOne(wallet, budgetMs, quietMs = 0) {
  return exclusive(() => (isSolanaAddress(wallet)
    ? indexSolanaWallet(wallet, { store, rpc: solana, price: readers.solPrice, meta: readers.solMeta, paceMs: 250, deadline: Date.now() + budgetMs })
    : indexWallet(wallet, { store, hypersync, price: readers.price, meta: readers.meta, backfillBlocks: BACKFILL_BLOCKS, deadline: Date.now() + budgetMs, quietMs })));
}

let backoffUntil = 0;
function noteFailure(wallet, error) {
  console.error(`worker: ${wallet} ${error.message}`);
  if (/429/.test(error.message)) backoffUntil = Date.now() + BACKOFF_MS;
}

async function rotation() {
  const [allWallets, urgent] = await Promise.all([store.smembers(TRACKED_KEY), store.smembers(URGENT_KEY)]);
  const pending = new Set(urgent);
  const selected = selectWallets(allWallets, urgent, queueCursor);
  queueCursor = selected.nextCursor;
  const wallets = selected.wallets;
  let indexed = 0;
  let behind = 0;
  const stored = await store.mget(wallets.map(ledgerKey));
  for (const [index, wallet] of wallets.entries()) {
    if (stopping) break;
    if (Date.now() < backoffUntil) break;
    const known = stored[index] ? JSON.parse(stored[index]) : null;
    if (known && Date.now() - known.indexedAt < FRESH_MS) {
      if (pending.has(wallet)) await store.srem(URGENT_KEY, wallet);
      continue;
    }
    try {
      const result = await indexOne(wallet, PER_WALLET_BUDGET_MS);
      indexed += 1;
      if (!result.complete) behind += 1;
      if (result.complete && pending.has(wallet)) await store.srem(URGENT_KEY, wallet);
    } catch (error) {
      noteFailure(wallet, error);
    }
  }
  console.log(`worker: ${indexed}/${wallets.length} selected of ${allWallets.length} wallets, ${behind} still behind`);
  await store.set(HEARTBEAT_KEY, JSON.stringify({ at: Date.now(), wallets: allWallets.length, indexed, behind }), { ex: 3600 }).catch(() => {});
}

let watchedCache = { at: 0, wallets: [] };
async function watchedWallets() {
  if (Date.now() - watchedCache.at < WATCHED_REFRESH_MS) return watchedCache.wallets;
  const raw = await store.get(WATCHED_KEY).catch(() => undefined);
  if (raw === undefined) return watchedCache.wallets;
  watchedCache = { at: Date.now(), wallets: raw ? JSON.parse(raw) : [] };
  return watchedCache.wallets;
}

async function fastLane() {
  const watched = await watchedWallets();
  if (watched.length === 0) return;
  let written = 0;
  for (const wallet of watched) {
    if (stopping || Date.now() < backoffUntil) break;
    try {
      const result = await indexOne(wallet, FAST_BUDGET_MS, FAST_QUIET_MS);
      if (result.written !== false) written += 1;
    } catch (error) {
      noteFailure(wallet, error);
    }
  }
  if (written) console.log(`worker: fast lane wrote ${written}/${watched.length}`);
}

async function scanAlerts() {
  if (!process.env.CRON_SECRET) return;
  const response = await fetch(`${DESK_API}/api/alerts?job=scan&rounds=1`, { headers: bearer });
  if (response.status === 202) return;
  if (!response.ok) throw new Error(`scan ${response.status}`);
  const body = await response.json();
  const round = body.rounds?.[0];
  const sent = (round?.sent ?? 0) + (round?.wallets?.sent ?? 0) + (round?.prices?.sent ?? 0);
  if (sent) console.log(`worker: scan sent ${sent} (traders ${round.sent ?? 0}, wallets ${round.wallets?.sent ?? 0}, prices ${round.prices?.sent ?? 0})`);
}

let indexFailures = 0;
const INDEX_CATCHUP_RETRY_MS = 60_000;
async function traderIndex() {
  // Sharing the wallets' token means sharing their turn and their backoff too.
  if (!ownIndexToken && Date.now() < backoffUntil) return BACKOFF_MS;
  const before = await store.get("hist:cursor").catch(() => null);
  try {
    const markets = await openMarkets();
    const run = () => indexWithLock({ store, hypersync: indexHypersync, markets, budgetMs: ownIndexToken ? 50_000 : 20_000, lockSeconds: INDEX_LOCK_S });
    const report = await (ownIndexToken ? run() : exclusive(run));
    indexFailures = 0;
    if (report.skipped) return INDEX_LOCK_S * 1000;
    console.log(`worker: trader index ${report.events} events, ${report.accounts} accounts, ${report.behind} blocks behind`);
    return report.behind > INDEX_CATCHUP_BLOCKS ? INDEX_CATCHUP_MS : INDEX_PAUSE_MS;
  } catch (error) {
    // A run that saved pages before HyperSync refused is progress, not a failure to back off from.
    const after = await store.get("hist:cursor").catch(() => null);
    const advanced = after !== null && (before === null || Number(after) > Number(before));
    indexFailures = advanced ? 0 : indexFailures + 1;
    if (!ownIndexToken && /429/.test(error.message)) backoffUntil = Date.now() + BACKOFF_MS;
    const wait = advanced ? INDEX_CATCHUP_RETRY_MS : indexBackoffMs(indexFailures);
    console.error(`worker: trader index failed (${error.message}), trying again in ${Math.round(wait / 1000)} s`);
    return wait;
  }
}

async function loop(name, work, pauseMs) {
  while (!stopping) {
    const started = Date.now();
    let asked;
    try {
      asked = await work();
    } catch (error) {
      console.error(`worker: ${name} failed: ${error.message}`);
    }
    await sleep(typeof asked === "number" ? asked : Math.max(1_000, pauseMs - (Date.now() - started)));
  }
}

await Promise.all([
  loop("rotation", rotation, ROUND_PAUSE_MS),
  loop("fast lane", fastLane, FAST_PAUSE_MS),
  loop("scan", scanAlerts, SCAN_PAUSE_MS),
  loop("trader index", traderIndex, INDEX_PAUSE_MS),
]);
console.log("worker: stopped");
