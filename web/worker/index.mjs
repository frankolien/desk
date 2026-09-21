import { hypersyncClient } from "../api/_history.mjs";
import { HEARTBEAT_KEY, TRACKED_KEY, indexWallet, ledgerKey } from "../api/_ledger.mjs";
import { SOLANA, indexSolanaWallet, isSolanaAddress, solanaMetaReader, solanaRpc } from "../api/_solana.mjs";
import { redisStore } from "../api/_store.mjs";
import { metaReader, priceReader } from "../api/_wallet.mjs";

/// The person at the back. Every wallet anyone has opened is in `wl:tracked`; this
/// loop brings each ledger up to the chain tip, round after round, so a page never
/// has to index on demand twice. Runs on Railway with the same env names as Vercel.

const ROUND_PAUSE_MS = Number(process.env.WORKER_PAUSE_MS || 90_000);
const PER_WALLET_BUDGET_MS = 20_000;
const BACKFILL_BLOCKS = 45 * 216_000;
/// A wallet brought to the tip this recently is left alone; HyperSync's free tier is
/// shared with the alerts index and rate-limits when asked too often.
const FRESH_MS = 5 * 60_000;
const BACKOFF_MS = 60_000;

const store = redisStore();
const hypersync = hypersyncClient();
const solana = solanaRpc();
if (!store || !hypersync) {
  console.error("worker: KV_REST_API_URL, KV_REST_API_TOKEN and HYPERSYNC_TOKEN are required");
  process.exit(1);
}

/// Candles come through Desk's own API rather than OKX directly, so the OKX key lives in
/// one place. The shared price cache in Redis means most lookups never leave this box.
const DESK_API = process.env.DESK_API || "https://web-lovat-nine-49.vercel.app";
async function fetchCandles(path, params) {
  const query = new URLSearchParams({ view: "candle", chainIndex: params.chainIndex, contract: params.tokenContractAddress, bar: params.bar, after: params.after });
  const response = await fetch(`${DESK_API}/api/token-details?${query}`, { headers: { authorization: `Bearer ${process.env.CRON_SECRET ?? ""}` } });
  if (!response.ok) throw new Error(`candles ${response.status}`);
  return (await response.json()).rows;
}

let stopping = false;
process.on("SIGTERM", () => { stopping = true; });
process.on("SIGINT", () => { stopping = true; });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function round() {
  const wallets = await store.smembers(TRACKED_KEY);
  const price = priceReader({ store, fetchCandles });
  const meta = metaReader({ store });
  const solPrice = priceReader({ store, chainIndex: SOLANA, fetchCandles });
  const solMeta = solanaMetaReader({ store, api: DESK_API });
  let indexed = 0;
  let behind = 0;
  const stored = await store.mget(wallets.map(ledgerKey));
  for (const [index, wallet] of wallets.entries()) {
    if (stopping) break;
    const known = stored[index] ? JSON.parse(stored[index]) : null;
    if (known && Date.now() - known.indexedAt < FRESH_MS) continue;
    try {
      const result = isSolanaAddress(wallet)
        ? await indexSolanaWallet(wallet, { store, rpc: solana, price: solPrice, meta: solMeta, deadline: Date.now() + PER_WALLET_BUDGET_MS })
        : await indexWallet(wallet, {
          store, hypersync, price, meta, backfillBlocks: BACKFILL_BLOCKS, deadline: Date.now() + PER_WALLET_BUDGET_MS,
        });
      indexed += 1;
      if (!result.complete) behind += 1;
    } catch (error) {
      console.error(`worker: ${wallet} ${error.message}`);
      if (/429/.test(error.message)) { await sleep(BACKOFF_MS); }
    }
  }
  console.log(`worker: ${indexed}/${wallets.length} wallets, ${behind} still behind`);
  // The health endpoint reads this to say whether the indexer is alive.
  await store.set(HEARTBEAT_KEY, JSON.stringify({ at: Date.now(), wallets: wallets.length, indexed, behind }), { ex: 3600 }).catch(() => {});
}

while (!stopping) {
  const started = Date.now();
  try {
    await round();
  } catch (error) {
    console.error(`worker: round failed: ${error.message}`);
  }
  const wait = Math.max(1_000, ROUND_PAUSE_MS - (Date.now() - started));
  await sleep(wait);
}
console.log("worker: stopped");
