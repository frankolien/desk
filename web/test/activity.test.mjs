// node --test web/test/activity.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { createHandler, followingFeed, formatUnits, normalize } from "../api/activity.mjs";
import { memoryStore } from "../api/_store.mjs";
import { ledgerKey, TRACKED_KEY, URGENT_KEY } from "../api/_ledger.mjs";

const ME = "0x82ec56aaf7aa35c6ac62b598e6c964a4b186f775";
const PERPL = "0x34b6552d57a35a1d042ccae1951bd1c370112a6f";
const OTHER = "0x1111111111111111111111111111111111111111";
const SOLANA = "Fw1ETanDZafof7xEULsnq9UY6o71Tpds89tNwPkWLb1v";

function recorder() {
  const out = { status: null, body: null };
  return {
    status(code) { out.status = code; return this; },
    json(value) { out.body = value; return out; },
    setHeader() {},
  };
}

test("units keep every digit and drop trailing zeros", () => {
  assert.equal(formatUnits("10000000000", 6), "10000");
  assert.equal(formatUnits("1500000", 6), "1.5");
  assert.equal(formatUnits("1", 18), "0.000000000000000001");
  assert.equal(formatUnits("abc", 6), null);
});

test("transfers are directed, labelled and ordered newest first", () => {
  const entries = normalize({
    address: "0x82EC56aaf7aA35C6ac62B598E6C964a4B186f775",
    nativeSymbol: "MON",
    native: [
      { hash: "0xa", timeStamp: "100", from: OTHER, to: ME, value: "200000000000000000", isError: "0" },
      { hash: "0xfailed", timeStamp: "300", from: ME, to: OTHER, value: "5", isError: "1" },
      { hash: "0xcall", timeStamp: "310", from: ME, to: PERPL, value: "0", isError: "0" },
    ],
    tokens: [
      { hash: "0xb", timeStamp: "200", from: ME, to: PERPL, value: "10000000", tokenSymbol: "AUSD", tokenDecimal: "6", contractAddress: "0xA9" },
      { hash: "0xc", timeStamp: "50", from: OTHER, to: OTHER, value: "1", tokenSymbol: "X", tokenDecimal: "0", contractAddress: "0xb" },
    ],
  });
  assert.deepEqual(entries.map((entry) => entry.hash), ["0xb", "0xa"]);
  assert.equal(entries[0].direction, "sent");
  assert.equal(entries[0].label, "perpl");
  assert.equal(entries[0].amount, "10");
  assert.equal(entries[1].direction, "received");
  assert.equal(entries[1].amount, "0.2");
  assert.equal(entries[1].time, 100_000);
});

test("the handler needs a key, and an empty history is an answer", async () => {
  const query = { address: ME, network: "mainnet" };
  const unconfigured = await createHandler(fetch, () => undefined)({ method: "GET", query }, recorder());
  assert.equal(unconfigured.status, 503);
  const empty = async () => ({ json: async () => ({ status: "0", message: "No transactions found", result: [] }) });
  const result = await createHandler(empty, () => "k")({ method: "GET", query }, recorder());
  assert.deepEqual(result.body, { entries: [] });
  const broken = async () => ({ json: async () => ({ status: "0", result: "Max rate limit reached" }) });
  assert.equal((await createHandler(broken, () => "k")({ method: "GET", query }, recorder())).status, 502);
  assert.equal((await createHandler(empty, () => "k")({ method: "GET", query: { address: "0x1", network: "mainnet" } }, recorder())).status, 400);
});

test("following feed sorts indexed buys and sells, and queues missing wallets", async () => {
  const store = memoryStore();
  const now = Date.now();
  await store.set(ledgerKey(ME), JSON.stringify({ trades: [
    { time: now - 20_000, hash: "0x1", token: OTHER, symbol: "ONE", side: "buy", amount: 2, value: 30 },
    { time: now - 10_000, hash: "0x2", token: OTHER, symbol: "ONE", side: "sell", amount: 1, value: 20, gain: 5 },
    { time: now - 15 * 86_400_000, hash: "0xold", token: OTHER, symbol: "ONE", side: "buy", value: 10 },
  ] }));
  const result = await followingFeed(store, [ME, OTHER], now);
  assert.deepEqual(result.events.map((event) => event.hash), ["0x2", "0x1"]);
  assert.equal(result.events[0].gain, 5);
  assert.deepEqual(result.pending, [OTHER]);
  assert.deepEqual(await store.smembers(TRACKED_KEY), [OTHER]);
  assert.deepEqual(await store.smembers(URGENT_KEY), [ME, OTHER]);
  assert.equal(result.sync.workerDelayed, true);
  assert.equal(result.sync.pushDelayed, true);
  const response = await createHandler(fetch, () => undefined, { store })(
    { method: "GET", query: { view: "feed", addresses: `${ME},${OTHER}` } }, recorder());
  assert.equal(response.status, 200);
  assert.equal(response.body.events.length, 2);
  const invalid = await createHandler(fetch, () => undefined, { store })(
    { method: "GET", query: { view: "feed", addresses: "0xbad" } }, recorder());
  assert.equal(invalid.status, 400);
});

test("following feed reports stale indexing and keeps Solana ledger keys case-sensitive", async () => {
  const store = memoryStore();
  const now = Date.now();
  assert.equal(ledgerKey(SOLANA), `wl:${SOLANA}`);
  await store.set(ledgerKey(SOLANA), JSON.stringify({ indexedAt: now - 11 * 60_000, trades: [] }));
  const result = await followingFeed(store, [SOLANA], now);
  assert.deepEqual(result.stale, [SOLANA]);
  assert.deepEqual(result.pending, []);
  assert.deepEqual(await store.smembers(URGENT_KEY), [SOLANA]);
});

test("following feed distinguishes healthy indexing and push scans from a missing timeline", async () => {
  const store = memoryStore();
  const now = Date.now();
  await store.set("wl:heartbeat", JSON.stringify({ at: now - 30_000 }));
  await store.set("alerts:lastScan", new Date(now - 60_000).toISOString());
  await store.set(ledgerKey(SOLANA), JSON.stringify({ indexedAt: now - 30_000, trades: [] }));
  const feed = await followingFeed(store, [SOLANA], now);
  assert.deepEqual(feed.sync, { workerDelayed: false, pushDelayed: false });
  assert.deepEqual(feed.pending, []);
  assert.deepEqual(feed.stale, []);
});
