// node --test web/test/signals.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { WINDOWS, aggregateTokens, cachedSignals, computeSignals, isBot, scoreToken, sentence } from "../api/_signals.mjs";
import { memoryStore } from "../api/_store.mjs";
import { createHandler } from "../api/traders.mjs";

const H = 3_600_000;
const NOW = 1_000 * H;
const wallet = (n) => `0x${String(n).padStart(40, "a")}`;
const GRIZZLE = "0x1111000000000000000000000000000000000001";
const CHOG = "0x2222000000000000000000000000000000000002";
const WMON = "0x3333000000000000000000000000000000000003";
const DUST = "0x4444000000000000000000000000000000000004";

let hashes = 0;
const trade = (time, token, symbol, side, value, gain = null) =>
  ({ time, hash: `0x${(hashes += 1).toString(16)}`, token, symbol, side, amount: value, price: 1, value, gain });
const ledger = (address, trades, { wins = 0, losses = 0 } = {}) => ({ address, trades, positions: {}, wins, losses });

const quiet = { buyers: 0, netUsd: 0, firstBuyShare: 0, ageMs: Infinity, windowMs: WINDOWS["6h"], concentration: 0 };

test("the score adds buyers, inflow, first buys and freshness, and takes thirty off a one-wallet pump", () => {
  assert.equal(scoreToken({ ...quiet, buyers: 3 }), 30);
  assert.equal(scoreToken({ ...quiet, buyers: 6 }), 40);
  assert.equal(scoreToken({ ...quiet, netUsd: 499 }), 0);
  assert.equal(scoreToken({ ...quiet, netUsd: -2_000 }), 0);
  assert.equal(scoreToken({ ...quiet, netUsd: 500 }), 5);
  assert.equal(scoreToken({ ...quiet, netUsd: 5_000 }), 15);
  assert.equal(scoreToken({ ...quiet, netUsd: 50_000 }), 25);
  assert.equal(scoreToken({ ...quiet, netUsd: 5_000_000 }), 25);
  assert.equal(scoreToken({ ...quiet, firstBuyShare: 1 }), 15);
  assert.equal(scoreToken({ ...quiet, firstBuyShare: 0.4 }), 6);
  assert.equal(scoreToken({ ...quiet, ageMs: 0 }), 20);
  assert.equal(scoreToken({ ...quiet, ageMs: WINDOWS["6h"] / 2 }), Math.round(20 / Math.E));
  assert.equal(scoreToken({ ...quiet, buyers: 6, ageMs: 0, concentration: 0.8 }), 30);
  assert.equal(scoreToken({ ...quiet, buyers: 6, ageMs: 0, concentration: 0.7 }), 60);
  assert.equal(scoreToken({ ...quiet, buyers: 6, netUsd: 50_000, firstBuyShare: 1, ageMs: 0 }), 100);
  assert.equal(scoreToken({ ...quiet, concentration: 0.9 }), 0);
});

test("a signal is one sentence, and money leaving is said plainly", () => {
  assert.equal(sentence({ symbol: "GRIZZLE", buyers: 3, netUsd: 4_200, window: "1h" }), "3 top traders bought GRIZZLE in the last hour · +$4.2K net");
  assert.equal(sentence({ symbol: "CHOG", buyers: 2, netUsd: 310, window: "6h" }), "2 top traders bought CHOG in the last 6 hours · +$310 net");
  assert.equal(sentence({ symbol: "CHOG", buyers: 2, netUsd: -1_500, window: "24h" }), "Smart money is leaving CHOG · −$1.5K net in the last 24 hours");
});

test("per token: distinct buyers, net inflow, first-buy share, freshness and concentration", () => {
  const ledgers = new Map([
    [wallet(1), ledger(wallet(1), [
      trade(NOW - 20 * H, GRIZZLE, "GRIZZLE", "buy", 500),
      trade(NOW - 2 * H, GRIZZLE, "GRIZZLE", "buy", 1_000),
      trade(NOW - 1 * H, GRIZZLE, "GRIZZLE", "sell", 200, 50),
    ])],
    [wallet(2), ledger(wallet(2), [trade(NOW - 3 * H, GRIZZLE, "GRIZZLE", "buy", 3_000), trade(NOW - 3 * H, DUST, "DUST", "buy", 50)])],
    [wallet(3), ledger(wallet(3), [trade(NOW - 3 * H, DUST, "DUST", "buy", 50)])],
  ]);
  const rows = aggregateTokens(ledgers, { now: NOW, windowMs: WINDOWS["6h"] });
  const grizzle = rows.find((row) => row.token === GRIZZLE);
  assert.deepEqual(grizzle.buyers, [wallet(2), wallet(1)]);
  assert.equal(grizzle.netUsd, 3_800);
  assert.equal(grizzle.firstBuyShare, 0.5);
  assert.equal(grizzle.ageMs, 2 * H);
  assert.equal(grizzle.concentration, 0.75);
  // Buys under $100 are not buys; a token with none has no buyers and infinite age.
  const dust = rows.find((row) => row.token === DUST);
  assert.deepEqual([dust.buyers, dust.ageMs], [[], Infinity]);
  assert.equal(isBot(ledger(wallet(9), Array.from({ length: 201 }, (_, i) => trade(NOW - i * 60_000, DUST, "DUST", "buy", 1))), NOW), true);
  assert.equal(isBot(ledger(wallet(9), Array.from({ length: 200 }, (_, i) => trade(NOW - i * 60_000, DUST, "DUST", "buy", 1))), NOW), false);
});

async function seed(store) {
  await store.set("hist:leaders", JSON.stringify([
    { account: "1", address: wallet(1), score: 90 },
    { account: "2", address: wallet(2), score: 80 },
    { account: "3", address: null, score: 70 },
  ]));
  await store.set(`alerts:sub:${"f".repeat(64)}`, JSON.stringify({ token: "x", environment: "sandbox", traders: [], copying: [], names: {}, wallets: [{ address: wallet(4), name: null, minUsd: 250, firstBuysOnly: false }] }));
  await store.sadd("alerts:subs", "f".repeat(64));
  for (const n of [5, 6, 7]) await store.sadd("wl:tracked", wallet(n));

  const fresh = NOW - 10 * 60_000;
  await store.set(`wl:${wallet(1)}`, JSON.stringify(ledger(wallet(1), [
    trade(fresh, GRIZZLE, "GRIZZLE", "buy", 2_000), trade(fresh, WMON, "WMON", "buy", 5_000), trade(fresh, CHOG, "CHOG", "buy", 900),
  ])));
  await store.set(`wl:${wallet(2)}`, JSON.stringify(ledger(wallet(2), [
    trade(fresh, GRIZZLE, "GRIZZLE", "buy", 1_500), trade(fresh, WMON, "WMON", "buy", 5_000), trade(fresh, DUST, "DUST", "buy", 500),
  ])));
  // Row three has no address; wallet three's ledger must be ignored even though it exists.
  await store.set(`wl:${wallet(3)}`, JSON.stringify(ledger(wallet(3), [trade(fresh, DUST, "DUST", "buy", 5_000)])));
  await store.set(`wl:${wallet(4)}`, JSON.stringify(ledger(wallet(4), [trade(fresh, GRIZZLE, "GRIZZLE", "buy", 1_200), trade(fresh, CHOG, "CHOG", "buy", 60)])));
  // Tracked by nobody: qualifies only on its own record.
  const proven = Array.from({ length: 19 }, (_, i) => trade(NOW - 5 * 24 * H - i * H, DUST, "DUST", "sell", 100, 1));
  await store.set(`wl:${wallet(5)}`, JSON.stringify(ledger(wallet(5), [...proven, trade(fresh, GRIZZLE, "GRIZZLE", "buy", 800)], { wins: 11, losses: 9 })));
  await store.set(`wl:${wallet(6)}`, JSON.stringify(ledger(wallet(6), [...proven, trade(fresh, GRIZZLE, "GRIZZLE", "buy", 800)], { wins: 9, losses: 11 })));
  // A bot: hundreds of trades today.
  const churn = Array.from({ length: 250 }, (_, i) => trade(NOW - i * 60_000, CHOG, "CHOG", "buy", 900));
  await store.set(`wl:${wallet(7)}`, JSON.stringify(ledger(wallet(7), churn, { wins: 100, losses: 10 })));
}

test("signals come from leaders, tracked wallets and proven records, never from bots or stables", async () => {
  const store = memoryStore();
  await seed(store);
  const prices = async (chainIndex, tokens) => { assert.equal(chainIndex, "143"); return new Map(tokens.map((token) => [token, 0.01])); };
  const result = await computeSignals({ store, now: NOW, window: "1h", prices });
  assert.equal(result.window, "1h");
  assert.equal(result.observedAt, NOW);
  assert.deepEqual(result.signals.map((row) => row.symbol), ["GRIZZLE"]);
  const [grizzle] = result.signals;
  // Wallets 1, 2, 4 and 5: the leaders, the one someone tracks, and the proven one.
  assert.equal(grizzle.distinct, 4);
  assert.deepEqual(grizzle.buyers, [{ address: wallet(1) }, { address: wallet(2) }, { address: wallet(4) }]);
  assert.equal(grizzle.netUsd, 5_500);
  assert.equal(grizzle.firstBuyShare, 1);
  assert.equal(grizzle.chainIndex, "143");
  assert.equal(grizzle.price, 0.01);
  assert.equal(grizzle.warning, null);
  // 40 buyers + 15 inflow + 15 first buys + 20·e^(−1/3) freshness.
  assert.equal(grizzle.score, Math.round(70 + 20 * Math.exp(-1 / 3)));
  assert.equal(grizzle.strong, true);
  assert.equal(grizzle.summary, "4 top traders bought GRIZZLE in the last hour · +$5.5K net");
});

test("one buyer, or a low score, is not a signal; a lopsided one carries a warning", async () => {
  const store = memoryStore();
  const fresh = NOW - 60_000;
  await store.set("hist:leaders", JSON.stringify([1, 2, 3, 4].map((n) => ({ account: String(n), address: wallet(n) }))));
  // One whale and three small buyers: shown, but said to be mostly one wallet. CHOG has one buyer.
  await store.set(`wl:${wallet(1)}`, JSON.stringify(ledger(wallet(1), [trade(fresh, GRIZZLE, "GRIZZLE", "buy", 100_000), trade(fresh, CHOG, "CHOG", "buy", 50_000)])));
  for (const n of [2, 3, 4]) await store.set(`wl:${wallet(n)}`, JSON.stringify(ledger(wallet(n), [trade(fresh, GRIZZLE, "GRIZZLE", "buy", 1_000)])));
  const result = await computeSignals({ store, now: NOW, window: "6h", prices: async () => new Map() });
  assert.deepEqual(result.signals.map((row) => [row.symbol, row.warning, row.price]), [["GRIZZLE", "1 wallet is 97% of it", null]]);
  assert.equal(result.signals[0].score, Math.round(40 + 25 + 15 + 20 * Math.exp(-60_000 / (3 * H)) - 30));
  assert.equal(result.signals[0].strong, false);

  // Two small, stale buys: 20 + 0 + 15 + 20·e^(−5/3) is under fifty.
  for (const n of [1, 2]) await store.set(`wl:${wallet(n)}`, JSON.stringify(ledger(wallet(n), [trade(NOW - 5 * H, GRIZZLE, "GRIZZLE", "buy", 100)])));
  for (const n of [3, 4]) await store.del(`wl:${wallet(n)}`);
  const stale = await computeSignals({ store, now: NOW, window: "6h", prices: async () => new Map() });
  assert.deepEqual(stale.signals, []);
});

test("the result is cached for a minute per window", async () => {
  const store = memoryStore();
  await store.set("hist:leaders", "[]");
  const first = await cachedSignals({ store, window: "24h", now: NOW, prices: async () => new Map() });
  assert.deepEqual(first, { observedAt: NOW, window: "24h", signals: [] });
  assert.ok(store.values.has("signals:24h"));
  const again = await cachedSignals({ store, window: "24h", now: NOW + 1, prices: async () => new Map() });
  assert.equal(again.observedAt, NOW);
});

test("the view answers 503 without a store, and reads the cache with one", async () => {
  const recorder = () => {
    const out = { status: null, body: null, headers: {} };
    return { status(code) { out.status = code; return this; }, json(value) { out.body = value; return out; }, setHeader(name, value) { out.headers[name] = value; } };
  };
  const missing = await createHandler({ chain: {}, fetchImpl: async () => { throw new Error("no network"); } })({ method: "GET", query: { view: "signals" } }, recorder());
  assert.equal(missing.status, 503);

  const store = memoryStore();
  await store.set("signals:6h", JSON.stringify({ observedAt: 1, window: "6h", signals: [] }));
  const served = await createHandler({ chain: {}, store, fetchImpl: async () => { throw new Error("no network"); } })({ method: "GET", query: { view: "signals", window: "bogus" } }, recorder());
  assert.equal(served.status, 200);
  assert.deepEqual(served.body, { observedAt: 1, window: "6h", signals: [] });
  assert.equal(served.headers["Cache-Control"], "public, s-maxage=60, stale-while-revalidate=300");
});
