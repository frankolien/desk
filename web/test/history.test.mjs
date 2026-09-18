// node --test web/test/history.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  TOPICS, applyEvent, decodeEvent, describe, emptyRecord, indexHistory, leaders, mergeTrades, score, shardKey,
  shardOf, statistics, tradesKey,
} from "../api/_history.mjs";
import { memoryStore } from "../api/_store.mjs";
import { createHandler } from "../api/traders.mjs";

const BTC = { id: 1, name: "BTC", config: { price_decimals: 1, size_decimals: 5 } };
const markets = new Map([[1, BTC]]);
const word = (value) => (BigInt.asUintN(256, BigInt(value))).toString(16).padStart(64, "0");
const log = (kind, words, block = 100) => ({ topic0: TOPICS[kind], block_number: block, data: `0x${words.map(word).join("")}` });

// perp, account, type, leverage(hdths), deposit, pnlCollat, price, lots, insFee, protFee, residue
const opened = (account, long, price, block, lev = 500) => log("opened", [1, account, long ? 0 : 1, lev, 100_000_000, 0, price, 100_000, 0, 0, 0], block);
// perp, account, type, price, deltaPnl, funding
const closed = (account, long, price, pnl, block) => log("closed", [1, account, long ? 0 : 1, price, pnl, 0], block);
// perp, account, type, startDep, endDep, startLot, endLot, deltaPnl, funding
const decreased = (account, long, pnl, block) => log("decreased", [1, account, long ? 0 : 1, 0, 0, 0, 0, pnl, 0], block);

test("position events decode with signed PnL, the account and the side", () => {
  const times = new Map([[100, 1_700_000_000]]);
  const event = decodeEvent(closed(3901, false, 650_000, -12_500_000, 100), times);
  assert.deepEqual([event.kind, event.account, event.isLong, event.pnl, event.time], ["closed", "3901", false, -12.5, 1_700_000_000]);
  assert.equal(decodeEvent({ topic0: "0xdead", data: "0x" }, times), null);
});

test("a round trip folds partial closes into one trade with hold time, market and streaks", () => {
  const record = emptyRecord();
  const times = new Map([[1, 1000], [2, 1600], [3, 4600], [4, 5000], [5, 5100]]);
  const fold = (entry) => applyEvent(record, decodeEvent(entry, times), BTC);
  assert.equal(fold(opened(7, true, 600_000, 1)), null);
  assert.equal(fold(decreased(7, true, 5_000_000, 2)), null);
  const trade = fold(closed(7, true, 610_000, 10_000_000, 3));
  assert.deepEqual(trade, [4600, "BTC", 1, 60_000, 61_000, 15, 3600, 5, 0]);
  fold(opened(7, false, 610_000, 4));
  fold(closed(7, false, 620_000, -20_000_000, 5));
  const stats = statistics(record);
  assert.equal(stats.trades, 2);
  assert.equal(stats.winRate, 0.5);
  assert.equal(stats.realised, -5);
  assert.equal(stats.maxDrawdown, 20);
  assert.equal(stats.averageHoldSeconds, 1850);
  assert.equal(stats.worstStreak, 1);
  assert.deepEqual(stats.bestMarket, null);
  assert.equal(stats.worstMarket.symbol, "BTC");
});

test("scores need trades and real money behind them, and liquidations cost", () => {
  const steady = { ...emptyRecord(), n: 40, w: 28, l: 12, gp: 900, gl: 300, dd: 120, liq: 0,
    vol: 80_000, markets: { BTC: [600, 20], ETH: [300, 20] } };
  const dust = { ...steady, gp: 0.02, gl: 0.01, dd: 0, vol: 40 };
  const lucky = { ...steady, n: 3, w: 3, l: 0, gl: 0 };
  assert.ok(score(steady) > 60);
  assert.ok(score(dust) < 5);
  assert.ok(score(lucky) < score(steady));
  assert.equal(score({ ...steady, liq: 2 }), score(steady) - 10);
  assert.equal(score(emptyRecord()), null);

  // A perfect record on one market, with little notional behind it, is the cheap shape to
  // manufacture. It must not outrank a real one.
  const thin = { ...emptyRecord(), n: 20, w: 20, l: 0, gp: 300, gl: 0, dd: 0, vol: 1_200,
    markets: { BTC: [300, 20] } };
  assert.ok(score(thin) < score(steady));
  assert.ok(score(thin) < 20);
});

test("a replayed block range does not count twice", () => {
  const market = { name: "BTC", config: { price_decimals: 1, size_decimals: 5 } };
  const open = { block: 10, logIndex: 0, time: 100, perp: 1, isLong: true, kind: "opened", priceRaw: 600_000n, lotsRaw: 100_000n, leverage: 5 };
  const close = { block: 11, logIndex: 3, time: 400, perp: 1, isLong: true, kind: "closed", priceRaw: 610_000n, pnl: 25, funding: 0 };

  const once = emptyRecord();
  applyEvent(once, open, market);
  applyEvent(once, close, market);

  const twice = emptyRecord();
  applyEvent(twice, open, market);
  applyEvent(twice, close, market);
  // The pipeline that writes the shards and the cursor is not a transaction, so the same
  // range can be read again after a partial write.
  applyEvent(twice, open, market);
  applyEvent(twice, close, market);

  assert.equal(twice.n, once.n);
  // Two real events in the same block are still two events.
  const sameBlock = emptyRecord();
  applyEvent(sameBlock, { ...open, block: 20, logIndex: 1 }, market);
  applyEvent(sameBlock, { ...close, block: 20, logIndex: 2 }, market);
  assert.equal(sameBlock.n, 1);
  assert.equal(twice.gp, once.gp);
  assert.equal(twice.cum, once.cum);
  assert.equal(twice.vol, once.vol);
});

test("a market this build has never seen counts the trade but not its prices", () => {
  const record = emptyRecord();
  applyEvent(record, { block: 5, logIndex: 0, time: 10, perp: 99, isLong: true, kind: "opened", priceRaw: 600_000n, lotsRaw: 100_000n, leverage: 5 }, undefined);
  const trade = applyEvent(record, { block: 6, logIndex: 1, time: 20, perp: 99, isLong: true, kind: "closed", priceRaw: 610_000n, pnl: 5, funding: 0 }, undefined);
  assert.equal(record.n, 1);
  assert.equal(record.vol, 0);
  assert.equal(trade[3], null);
  assert.equal(trade[4], null);
});

test("tags and the sentence come only from the figures", () => {
  const record = { ...emptyRecord(), n: 10, w: 7, l: 3, gp: 500, gl: 100, dd: 50, hold: 10 * 300, holdN: 10, lev: 120, levN: 10,
    longs: 9, shorts: 1, markets: { ETH: [420, 8], BTC: [-20, 2] }, liq: 1 };
  const stats = statistics(record);
  assert.deepEqual(stats.tags, ["Scalper", "High leverage", "ETH specialist", "Long-biased", "Liquidated once"]);
  assert.equal(describe(stats), "Scalper holding about 5 min at 12.0× on average. Wins 70% of 10 closed trades, best on ETH. Keeps drawdowns small. Has been liquidated once.");
});

test("recent trades stay newest first and bounded", () => {
  const merged = mergeTrades([[3], [2]], [[4], [5]]);
  assert.deepEqual(merged.map((trade) => trade[0]), [5, 4, 3, 2]);
  assert.equal(mergeTrades([], Array.from({ length: 30 }, (_, i) => [i])).length, 20);
});

test("indexing pages through HyperSync, writes shards, trades, leaders and the cursor", async () => {
  const store = memoryStore();
  await store.set("hist:cursor", "90");
  const pages = [
    { logs: [opened(5201, true, 600_000, 95)], blocks: [{ number: 95, timestamp: "0x64" }], nextBlock: 110 },
    { logs: [closed(5201, true, 612_000, 25_000_000, 120)], blocks: [{ number: 120, timestamp: "0xc8" }], nextBlock: 180 },
  ];
  const hypersync = { height: async () => 200, query: async () => pages.shift() };
  const report = await indexHistory({ store, hypersync, markets, deadline: Date.now() + 5_000 });
  assert.deepEqual([report.events, report.accounts, report.to, report.behind], [2, 1, 180, 0]);
  assert.equal(await store.get("hist:cursor"), "180");
  const shard = JSON.parse(await store.get(shardKey(shardOf("5201"))));
  assert.equal(shard["5201"].n, 1);
  assert.deepEqual(JSON.parse(await store.get(tradesKey("5201")))[0], [200, "BTC", 1, 60_000, 61_200, 25, 100, 5, 0]);
  assert.deepEqual(JSON.parse(await store.get("hist:leaders")), []);
});

test("leaders need five trades and rank by score", () => {
  const good = { ...emptyRecord(), n: 30, w: 20, l: 10, gp: 600, gl: 200, dd: 80 };
  const few = { ...good, n: 4 };
  const rows = leaders([{ 1: good, 2: few }, { 3: { ...good, w: 12, l: 18 } }]);
  assert.deepEqual(rows.map((row) => row.account), ["1", "3"]);
});

function recorder() {
  const out = { status: null, body: null, headers: {} };
  return { status(code) { out.status = code; return this; }, json(value) { out.body = value; return out; }, setHeader(k, v) { out.headers[k] = v; } };
}

test("a profile's history is looked up by address, with trades and a grounded summary", async () => {
  const store = memoryStore();
  const record = { ...emptyRecord(), n: 6, w: 4, l: 2, gp: 300, gl: 50, dd: 30, hold: 6 * 7200, holdN: 6, lev: 30, levN: 6,
    longs: 3, shorts: 3, markets: { BTC: [250, 6] } };
  await store.set(shardKey(shardOf("42")), JSON.stringify({ 42: record }));
  await store.set(tradesKey("42"), JSON.stringify([[1_700_000_000, "BTC", 1, 60_000, 61_000, 50, 7200, 5, 0]]));
  await store.set("hist:leaders", JSON.stringify([{ account: "42", score: 70, trades: 6, winRate: 0.66, realised: 250 }]));
  const chain = {
    accountByAddress: async () => ({ accountId: 42n }),
    accountById: async () => ({ accountAddr: "0x95D2602d30DA1179fd13274839e60345857ca648" }),
  };
  const handler = createHandler({ chain, store, fetchImpl: async () => { throw new Error("no network"); } });

  const history = await handler({ method: "GET", query: { view: "history", address: "0x95D2602d30DA1179fd13274839e60345857ca648" } }, recorder());
  assert.equal(history.status, 200);
  assert.equal(history.body.stats.trades, 6);
  assert.equal(history.body.summarySource, "figures");
  assert.match(history.body.summary, /Day trader holding about 2 h at 5\.0×/);
  assert.deepEqual(history.body.trades[0], { time: 1_700_000_000, market: "BTC", side: "long", entry: 60_000, exit: 61_000, pnl: 50, holdSeconds: 7200, leverage: 5, liquidated: false });

  const scores = await handler({ method: "GET", query: { view: "scores" } }, recorder());
  assert.equal(scores.body.traders[0].address, "0x95D2602d30DA1179fd13274839e60345857ca648");
  const bad = await handler({ method: "GET", query: { view: "history", address: "nope" } }, recorder());
  assert.equal(bad.status, 400);
});
