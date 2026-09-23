import { hypersyncClient } from "../api/_history.mjs";
import { HEARTBEAT_KEY, TRACKED_KEY, URGENT_KEY, WATCHED_KEY, indexWallet, ledgerKey } from "../api/_ledger.mjs";
import { SOLANA, indexSolanaWallet, isSolanaAddress, solanaMetaReader, solanaRpc } from "../api/_solana.mjs";
import { redisStore } from "../api/_store.mjs";
import { metaReader, priceReader } from "../api/_wallet.mjs";
import { selectWallets } from "./queue.mjs";

/// The person at the back, running three loops on Railway with Vercel's env names:
/// - the fast lane keeps every wallet someone has pushes for at the chain tip, every
///   few seconds, so a tracked wallet's buy is known within a block or two;
/// - the rotation brings every other opened wallet up in bounded rounds, newly followed
///   ones first, without starving the rest;
/// - the scan calls the alert endpoint, which reads followed traders' books, marks and
///   ledgers and sends what changed. Nothing waits for an outside scheduler.

const ROUND_PAUSE_MS = Number(process.env.WORKER_PAUSE_MS || 90_000);
const FAST_PAUSE_MS = Number(process.env.WORKER_FAST_MS || 12_000);
const SCAN_PAUSE_MS = Number(process.env.WORKER_SCAN_MS || 15_000);
const PER_WALLET_BUDGET_MS = 20_000;
const FAST_BUDGET_MS = 8_000;
const BACKFILL_BLOCKS = 45 * 216_000;
/// A wallet brought to the tip this recently is left alone by the rotation; HyperSync's
/// free tier is shared with the alerts index and rate-limits when asked too often.
const FRESH_MS = 5 * 60_000;
const FAST_FRESH_MS = 10_000;
const BACKOFF_MS = 60_000;
let queueCursor = 0;

const store = redisStore();
const hypersync = hypersyncClient();
const solana = solanaRpc();
if (!store || !hypersync) {
  console.error("worker: KV_REST_API_URL, KV_REST_API_TOKEN and HYPERSYNC_TOKEN are required");
  process.exit(1);
}
if (!process.env.CRON_SECRET) console.error("worker: CRON_SECRET is missing, so alerts will not be scanned");

/// Candles come through Desk's own API rather than OKX directly, so the OKX key lives in
/// one place. The shared price cache in Redis means most lookups never leave this box.
const DESK_API = process.env.DESK_API || "https://web-lovat-nine-49.vercel.app";
const bearer = { authorization: `Bearer ${process.env.CRON_SECRET ?? ""}` };
async function fetchCandles(path, params) {
  const query = new URLSearchParams({ view: "candle", chainIndex: params.chainIndex, contract: params.tokenContractAddress, bar: params.bar, after: params.after });
  const response = await fetch(`${DESK_API}/api/token-details?${query}`, { headers: bearer });
  if (!response.ok) throw new Error(`candles ${response.status}`);
  return (await response.json()).rows;
}

let stopping = false;
process.on("SIGTERM", () => { stopping = true; });
process.on("SIGINT", () => { stopping = true; });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

function indexOne(wallet, budgetMs) {
  return exclusive(() => (isSolanaAddress(wallet)
    ? indexSolanaWallet(wallet, { store, rpc: solana, price: readers.solPrice, meta: readers.solMeta, paceMs: 250, deadline: Date.now() + budgetMs })
    : indexWallet(wallet, { store, hypersync, price: readers.price, meta: readers.meta, backfillBlocks: BACKFILL_BLOCKS, deadline: Date.now() + budgetMs })));
}

let backoffUntil = 0;
function noteFailure(wallet, error) {
  console.error(`worker: ${wallet} ${error.message}`);
  if (/429/.test(error.message)) backoffUntil = Date.now() + BACKOFF_MS;
}

async function rotation() {
  const [allWallets, urgent] = await Promise.all([store.smembers(TRACKED_KEY), store.smembers(URGENT_KEY)]);
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
      await store.srem(URGENT_KEY, wallet);
      continue;
    }
    try {
      const result = await indexOne(wallet, PER_WALLET_BUDGET_MS);
      indexed += 1;
      if (!result.complete) behind += 1;
      if (result.complete) await store.srem(URGENT_KEY, wallet);
    } catch (error) {
      noteFailure(wallet, error);
    }
  }
  console.log(`worker: ${indexed}/${wallets.length} selected of ${allWallets.length} wallets, ${behind} still behind`);
  // The health endpoint reads this to say whether the indexer is alive.
  await store.set(HEARTBEAT_KEY, JSON.stringify({ at: Date.now(), wallets: allWallets.length, indexed, behind }), { ex: 3600 }).catch(() => {});
}

async function fastLane() {
  const raw = await store.get(WATCHED_KEY).catch(() => null);
  const watched = raw ? JSON.parse(raw) : [];
  if (watched.length === 0) return;
  const stored = await store.mget(watched.map(ledgerKey));
  let indexed = 0;
  for (const [index, wallet] of watched.entries()) {
    if (stopping || Date.now() < backoffUntil) break;
    const known = stored[index] ? JSON.parse(stored[index]) : null;
    if (known && Date.now() - known.indexedAt < FAST_FRESH_MS) continue;
    try {
      await indexOne(wallet, FAST_BUDGET_MS);
      indexed += 1;
    } catch (error) {
      noteFailure(wallet, error);
    }
  }
  if (indexed) console.log(`worker: fast lane ${indexed}/${watched.length}`);
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

async function loop(name, work, pauseMs) {
  while (!stopping) {
    const started = Date.now();
    try {
      await work();
    } catch (error) {
      console.error(`worker: ${name} failed: ${error.message}`);
    }
    await sleep(Math.max(1_000, pauseMs - (Date.now() - started)));
  }
}

await Promise.all([
  loop("rotation", rotation, ROUND_PAUSE_MS),
  loop("fast lane", fastLane, FAST_PAUSE_MS),
  loop("scan", scanAlerts, SCAN_PAUSE_MS),
]);
console.log("worker: stopped");
