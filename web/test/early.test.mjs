import assert from "node:assert/strict";
import { test } from "node:test";

import { classifyEarly, earlyKey, fetchEarlyLogs, handleEarly } from "../api/_early.mjs";
import { memoryStore } from "../api/_store.mjs";

const TOKEN = "0xaaaa000000000000000000000000000000000001";
const ZERO = "0x0000000000000000000000000000000000000000";
const DEV = "0xdddd000000000000000000000000000000000001";
const CURVE = "0xcccc000000000000000000000000000000000001";
const A = "0x1111000000000000000000000000000000000001";
const B = "0x2222000000000000000000000000000000000002";
const C = "0x3333000000000000000000000000000000000003";
const D = "0x4444000000000000000000000000000000000004";
const E = "0x5555000000000000000000000000000000000005";
const LATE = "0x6666000000000000000000000000000000000006";

const topic = (address) => `0x${address.slice(2).padStart(64, "0")}`;
const word = (value) => `0x${BigInt(value).toString(16).padStart(64, "0")}`;
const transfer = (block, from, to, whole, index = 0) => ({
  transaction_hash: `0x${block}${index}`, block_number: block, log_index: index, address: TOKEN,
  topic1: topic(from), topic2: topic(to), data: word(BigInt(whole) * 10n ** 18n),
});
const block = (number, timestamp) => ({ number, timestamp });

const LAUNCH = 1000;
const logs = [
  transfer(LAUNCH, ZERO, CURVE, 1_000_000, 0),
  transfer(LAUNCH, CURVE, DEV, 50_000, 1),
  transfer(LAUNCH + 1, CURVE, B, 20_000, 3),
  transfer(LAUNCH + 1, CURVE, A, 10_000, 1),
  transfer(LAUNCH + 5, DEV, C, 5_000, 0),
  transfer(LAUNCH + 50, CURVE, A, 10_000, 0),
  transfer(LAUNCH + 300, CURVE, C, 1_000, 0),
  transfer(LAUNCH + 300, CURVE, D, 1_000, 1),
  transfer(LAUNCH + 300, CURVE, E, 1_000, 2),
  transfer(LAUNCH + 300, A, B, 500, 3),
  transfer(LAUNCH + 900, CURVE, LATE, 100_000, 0),
];
const blocks = [block(LAUNCH, 1_700_000_000), block(LAUNCH + 1, 1_700_000_001), block(LAUNCH + 5, 1_700_000_002), block(LAUNCH + 50, 1_700_000_015), block(LAUNCH + 300, 1_700_000_090), block(LAUNCH + 900, 1_700_000_270)];

test("snipers are the first wallets served by the curve, in log order, never the creator", () => {
  const found = classifyEarly({ logs, blocks, creator: DEV.toUpperCase() });
  assert.equal(found.launchBlock, LAUNCH);
  assert.equal(found.creator, DEV);
  assert.deepEqual(found.snipers.map((row) => row.address), [A, B]);
  assert.equal(found.snipers[0].block, LAUNCH + 1);
  assert.equal(found.snipers[0].time, 1_700_000_001_000);
  assert.equal(found.snipers[0].amount, 20_000);
  assert.equal(found.snipers[0].share, 0.02);
  assert.equal(found.snipers[1].amount, 20_000);
  assert.ok(Math.abs(found.totals.snipers - 0.04) < 1e-9);
});

test("a bundle is one block where one sender filled three or more wallets", () => {
  const found = classifyEarly({ logs, blocks, creator: DEV });
  assert.equal(found.bundles.length, 1);
  assert.deepEqual(found.bundles[0], { block: LAUNCH + 300, time: 1_700_000_090_000, wallets: [C, D, E], amount: 3_000, share: 0.003 });
  const twoOnly = classifyEarly({ logs: logs.filter((log) => log.topic2 !== topic(E)), blocks, creator: DEV });
  assert.equal(twoOnly.bundles.length, 0);
});

test("insiders are the creator and whoever the creator sent to", () => {
  const found = classifyEarly({ logs, blocks, creator: DEV });
  assert.deepEqual(found.insiders, [
    { address: DEV, via: "creator", amount: 50_000, share: 0.05 },
    { address: C, via: "from-creator", amount: 5_000, share: 0.005 },
  ]);
  assert.ok(Math.abs(found.totals.insiders - 0.055) < 1e-9);
});

test("without nad.fun the first mint's recipient is the creator, and with no mint the peak balance is the supply", () => {
  const found = classifyEarly({ logs: [transfer(7, ZERO, DEV, 100), transfer(8, DEV, A, 40), transfer(9, A, B, 10)], blocks: [block(7, 1)] });
  assert.equal(found.creator, DEV);
  assert.equal(found.launchBlock, 7);
  assert.equal(found.supply, 100);
  assert.equal(found.insiders[1].share, 0.4);
  const unminted = classifyEarly({ logs: [transfer(7, CURVE, A, 60), transfer(8, CURVE, B, 20)], blocks: [], creator: DEV });
  assert.equal(unminted.supply, 60);
  assert.deepEqual(unminted.snipers.map((row) => row.share), [1, 1 / 3]);
  assert.deepEqual(classifyEarly({ logs: [], blocks: [] }).snipers, []);
});

test("decimals scale amounts and shares survive a six-decimal token", () => {
  const six = (block, from, to, whole) => ({ ...transfer(block, from, to, 0), data: word(BigInt(whole) * 10n ** 6n) });
  const found = classifyEarly({ logs: [six(1, ZERO, CURVE, 1_000), six(2, CURVE, A, 250)], blocks: [], creator: DEV, decimals: 6 });
  assert.equal(found.supply, 1_000);
  assert.equal(found.snipers[0].amount, 250);
  assert.equal(found.snipers[0].share, 0.25);
});

test("the scan follows pages until the window after launch is covered", async () => {
  const queries = [];
  const hypersync = {
    async height() { return 50_000; },
    async raw(query) {
      queries.push(query);
      if (query.from_block === 0) return { logs: [transfer(LAUNCH, ZERO, CURVE, 1)], blocks: [block(LAUNCH, 1)], nextBlock: 2_000 };
      if (query.from_block === 2_000) return { logs: [transfer(2_500, CURVE, A, 1)], blocks: [block(2_500, 2)], nextBlock: 3_001 };
      return { logs: [], blocks: [], nextBlock: 50_000 };
    },
  };
  const scan = await fetchEarlyLogs(hypersync, TOKEN.toUpperCase());
  assert.equal(scan.launchBlock, LAUNCH);
  assert.equal(scan.logs.length, 2);
  assert.equal(scan.blocksScanned, 2_000);
  assert.equal(queries.length, 2);
  assert.equal(queries[0].to_block, undefined);
  assert.equal(queries[0].logs[0].address[0], TOKEN);
  assert.equal(queries[1].to_block, LAUNCH + 2_001);
});

function recorder() {
  const out = { status: null, body: null, headers: {} };
  const res = {
    status(code) { out.status = code; return res; },
    json(body) { out.body = body; return out; },
    setHeader(key, value) { out.headers[key] = value; },
  };
  return { res, out };
}

const nadfun = async () => ({ ok: true, json: async () => ({ token_info: { created_at: 1_700_000_000, creator: { account_id: DEV.toUpperCase() } } }) });

test("the handler answers unsupported off Monad and 400 for a bad address", async () => {
  const other = recorder();
  await handleEarly({ query: { chainIndex: "1", address: TOKEN } }, other.res, { hypersync: null, store: null });
  assert.equal(other.out.status, 200);
  assert.equal(other.out.body.status, "unsupported");
  assert.deepEqual(other.out.body.snipers, []);
  assert.equal(other.out.headers["Cache-Control"], "no-store");
  const bad = recorder();
  await handleEarly({ query: { chainIndex: "143", address: "0x123" } }, bad.res, { hypersync: null, store: null });
  assert.equal(bad.out.status, 400);
});

test("the handler assembles the answer, reads balances, and caches it for an hour", async () => {
  const store = memoryStore();
  const hypersync = {
    async height() { return 5_000; },
    async raw() { return { logs, blocks, nextBlock: 5_000 }; },
  };
  const chain = {
    balances: async (token, wallets) => new Map(wallets.map((wallet) => [wallet, wallet === A ? 15_000n * 10n ** 18n : 0n])),
    contracts: async () => new Set(),
  };
  const meta = async () => ({ symbol: "T", decimals: 18 });
  const { res, out } = recorder();
  await handleEarly({ query: { chainIndex: "143", address: TOKEN } }, res, { hypersync, store, fetchImpl: nadfun, chain, meta });
  assert.equal(out.status, 200);
  assert.equal(out.body.status, "ready");
  assert.equal(out.body.createdAt, 1_700_000_000);
  assert.equal(out.body.creator, DEV);
  assert.equal(out.body.launchBlock, LAUNCH);
  assert.equal(out.body.blocksScanned, 2_000);
  assert.equal(out.body.snipers[0].holdsNow, 0.015);
  assert.equal(out.body.insiders[0].holdsNow, 0);
  assert.equal(out.body.bundles.length, 1);
  assert.equal(out.headers["Cache-Control"], "public, s-maxage=300, stale-while-revalidate=3600");
  assert.equal(JSON.parse(store.values.get(earlyKey(TOKEN))).status, "ready");

  const again = recorder();
  await handleEarly({ query: { chainIndex: "143", address: `0x${TOKEN.slice(2).toUpperCase()}` } }, again.res, { hypersync: null, store, fetchImpl: nadfun });
  assert.equal(again.out.body.status, "ready");
});

test("contracts are never snipers, bundle members or insiders, and the next wallet takes the seat", async () => {
  const hypersync = { async height() { return 5_000; }, async raw() { return { logs, blocks, nextBlock: 5_000 }; } };
  const chain = { balances: async () => { throw new Error("rpc down"); }, contracts: async () => new Set([A, C]) };
  const { res, out } = recorder();
  await handleEarly({ query: { chainIndex: "143", address: TOKEN } }, res, { hypersync, store: null, fetchImpl: nadfun, chain, meta: async () => null });
  assert.equal(out.body.status, "ready");
  assert.deepEqual(out.body.snipers.map((row) => row.address), [B]);
  assert.equal(out.body.snipers[0].holdsNow, null);
  assert.deepEqual(out.body.bundles, []);
  assert.deepEqual(out.body.insiders.map((row) => row.via), ["creator"]);
  assert.equal(classifyEarly({ logs, blocks, creator: DEV, limit: 1 }).snipers.length, 1);
});

test("a rate-limited HyperSync means indexing, any other failure unavailable", async () => {
  const limited = { async height() { throw new Error("hypersync 429"); } };
  const { res, out } = recorder();
  await handleEarly({ query: { chainIndex: "143", address: TOKEN } }, res, { hypersync: limited, store: null, fetchImpl: nadfun, meta: async () => null });
  assert.equal(out.body.status, "indexing");
  assert.equal(out.headers["Cache-Control"], "no-store");
  const broken = { async height() { throw new Error("hypersync 500"); } };
  const down = recorder();
  await handleEarly({ query: { chainIndex: "143", address: TOKEN } }, down.res, { hypersync: broken, store: null, fetchImpl: nadfun, meta: async () => null });
  assert.equal(down.out.body.status, "unavailable");
  const none = recorder();
  await handleEarly({ query: { chainIndex: "143", address: TOKEN } }, none.res, { hypersync: null, store: null });
  assert.equal(none.out.body.status, "unavailable");
});
