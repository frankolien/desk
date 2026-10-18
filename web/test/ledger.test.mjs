import assert from "node:assert/strict";
import { test } from "node:test";

import {
  NATIVE, TRANSFER_TOPIC, applyMovement, decodeTransfer, emptyLedger, groupMovements, indexWallet, summarize,
} from "../api/_ledger.mjs";
import { memoryStore } from "../api/_store.mjs";

const ME = "0x95d2602d30da1179fd13274839e60345857ca648";
const POOL = "0x1111111111111111111111111111111111111111";
const ROUTER = "0x2222222222222222222222222222222222222222";
const FRIEND = "0x3333333333333333333333333333333333333333";
const FROGE = "0xaaaa000000000000000000000000000000000001";
const USDC = "0xbbbb000000000000000000000000000000000002";

const topic = (address) => `0x${address.slice(2).padStart(64, "0")}`;
const word = (value) => `0x${BigInt(value).toString(16).padStart(64, "0")}`;
const transfer = (hash, block, token, from, to, raw, index = 0) => ({
  transaction_hash: hash, block_number: block, log_index: index, address: token,
  topic1: topic(from), topic2: topic(to), data: word(raw),
});
const tx = (hash, { to = ROUTER, value = "0x0", input = "0x38ed1739" } = {}) => ({ hash, from: ME, to, value, input });
const block = (number, timestamp) => ({ number, timestamp });

const META = { [FROGE]: { symbol: "FROGE", decimals: 18 }, [USDC]: { symbol: "USDC", decimals: 6 }, [NATIVE]: { symbol: "MON", decimals: 18 } };
const meta = async (token) => META[token] ?? null;
const PRICES = { [FROGE]: { 1000: 0.001, 2000: 0.002, 3000: 0.0005 }, [USDC]: { 1000: 1, 2000: 1, 3000: 1 }, [NATIVE]: { 1000: 0.025 } };
const price = async (token, time) => PRICES[token]?.[time / 1000] ?? null;

test("ERC-721 transfers share the topic and are not balances", () => {
  assert.equal(decodeTransfer({ ...transfer("0x1", 1, FROGE, ME, POOL, 5n), data: "0x", topic3: word(7) }), null);
  assert.equal(decodeTransfer(transfer("0x1", 1, FROGE, ME, POOL, 5n)).raw, 5n);
});

test("movements are named by what the wallet sent and what moved", () => {
  const page = {
    logs: [
      transfer("0xa", 10, USDC, ME, POOL, 100_000_000n, 0), transfer("0xa", 10, FROGE, POOL, ME, 10n ** 23n, 1),
      transfer("0xb", 11, FROGE, POOL, ME, 10n ** 22n, 0),
      transfer("0xc", 12, FROGE, ME, POOL, 10n ** 22n, 0),
      transfer("0xd", 13, FROGE, ME, FRIEND, 10n ** 21n, 0),
      transfer("0xe", 14, FROGE, FRIEND, ME, 10n ** 21n, 0),
    ],
    transactions: [tx("0xa"), tx("0xb", { value: "0xde0b6b3a7640000" }), tx("0xc"), tx("0xd", { to: FROGE, input: "0xa9059cbb0000" })],
    blocks: [block(10, 1000), block(11, 2000), block(12, 3000), block(13, 3000), block(14, 3000)],
  };
  const kinds = Object.fromEntries(groupMovements(ME, page).map((m) => [m.hash, m.kind]));
  assert.deepEqual(kinds, { "0xa": "swap", "0xb": "buy", "0xc": "sell", "0xd": "sent", "0xe": "received" });

  const perpl = "0x34b6552d57a35a1d042ccae1951bd1c370112a6f";
  const custody = {
    logs: [transfer("0xf", 20, USDC, ME, perpl, 5_000_000n), transfer("0xg", 21, USDC, perpl, ME, 5_000_000n)],
    transactions: [tx("0xf", { to: perpl }), tx("0xg", { to: perpl })],
    blocks: [block(20, 4000), block(21, 4000)],
  };
  assert.deepEqual(groupMovements(ME, custody).map((m) => m.kind), ["sent", "received"]);
});

test("weighted-average cost basis: buys raise the basis, sells realise against it, transfers in never count", async () => {
  const ledger = emptyLedger(ME);
  const swap = { hash: "0xa", block: 10, time: 1000_000, kind: "swap", paidNative: 0n, in: [{ token: FROGE, raw: 10n ** 23n }], out: [{ token: USDC, raw: 100_000_000n }] };
  await applyMovement(ledger, swap, { price, meta });
  assert.equal(ledger.positions[FROGE].holding, 100_000);
  assert.equal(ledger.positions[FROGE].basis, 100);

  const buy = { hash: "0xb", block: 11, time: 2000_000, kind: "buy", paidNative: 10n ** 18n, in: [{ token: FROGE, raw: 10n ** 23n }], out: [] };
  await applyMovement(ledger, buy, { price, meta });
  assert.equal(ledger.positions[FROGE].holding, 200_000);
  assert.equal(ledger.positions[FROGE].basis, 300);

  const gift = { hash: "0xe", block: 12, time: 3000_000, kind: "received", paidNative: 0n, in: [{ token: FROGE, raw: 10n ** 23n }], out: [] };
  await applyMovement(ledger, gift, { price, meta });
  assert.equal(ledger.positions[FROGE].unpriced, 100_000);

  const sell = { hash: "0xc", block: 13, time: 3000_000, kind: "sell", paidNative: 0n, in: [], out: [{ token: FROGE, raw: 2n * 10n ** 23n }] };
  await applyMovement(ledger, sell, { price, meta });
  // The gifted 100k leaves first with no PnL; 100k priced tokens sell at 0.0005 against a 0.0015 average.
  assert.equal(ledger.positions[FROGE].unpriced, 0);
  assert.equal(ledger.positions[FROGE].holding, 100_000);
  assert.ok(Math.abs(ledger.realized - (-100)) < 1e-9);
  assert.equal(ledger.losses, 1);

  const summary = summarize(ledger, (token) => ({ [FROGE]: 0.002, [USDC]: 1 })[token] ?? null, { now: 3000_000 + 1000 });
  assert.ok(Math.abs(summary.unrealized - 50) < 1e-9);
  assert.equal(summary.winRate, 0);
  assert.equal(summary.last7d.trades, 3);
  assert.equal(summary.tokens[0].symbol, "FROGE");
  assert.equal(summary.trades[0].side, "sell");
});

test("indexing keeps a cursor and only appends the next time", async () => {
  const store = memoryStore();
  let calls = 0;
  const hypersync = {
    async height() { return 1_000_020; },
    async raw(query) {
      calls += 1;
      if (query.from_block >= 1_000_000) return { logs: [], transactions: [], blocks: [], nextBlock: 1_000_000 };
      return {
        logs: [transfer("0xa", 500, USDC, ME, POOL, 100_000_000n, 0), transfer("0xa", 500, FROGE, POOL, ME, 10n ** 23n, 1)],
        transactions: [tx("0xa")], blocks: [block(500, 1000)], nextBlock: 1_000_000,
      };
    },
  };
  const first = await indexWallet(ME, { store, hypersync, price, meta, backfillBlocks: 1_000_000, now: () => 5 });
  assert.equal(first.complete, true);
  assert.equal(first.ledger.positions[FROGE].holding, 100_000);
  assert.equal(first.ledger.cursor, 1_000_000);
  const second = await indexWallet(ME, { store, hypersync, price, meta, backfillBlocks: 1_000_000, now: () => 6 });
  assert.equal(second.ledger.positions[FROGE].holding, 100_000);
  assert.equal(second.complete, true);
  assert.equal(calls, 1);
});

test("a deadline stops between blocks and leaves the cursor on the first block not applied", async () => {
  const store = memoryStore();
  const hypersync = {
    async height() { return 1_000_020; },
    async raw() {
      return {
        logs: [transfer("0xa", 500, FROGE, POOL, ME, 10n ** 23n, 0), transfer("0xb", 600, FROGE, POOL, ME, 10n ** 23n, 0)],
        transactions: [tx("0xa", { value: "0x1" }), tx("0xb", { value: "0x1" })], blocks: [block(500, 1000), block(600, 2000)], nextBlock: 1_000_000,
      };
    },
  };
  let clock = 0;
  const slowPrice = async (token, time) => { clock += 10; return price(token, time); };
  const result = await indexWallet(ME, { store, hypersync, price: slowPrice, meta, backfillBlocks: 1_000_000, now: () => clock, deadline: 5 });
  assert.equal(result.complete, false);
  assert.equal(result.ledger.cursor, 600);
  assert.equal(result.ledger.positions[FROGE].holding, 100_000);
});

test("with a quiet window, a run that found nothing skips the write until the stored ledger ages out", async () => {
  const store = memoryStore();
  let writes = 0;
  const set = store.set.bind(store);
  store.set = async (...args) => { writes += 1; return set(...args); };
  let tip = 1_000_020;
  const hypersync = {
    async height() { return tip; },
    async raw(query) {
      if (query.from_block >= 1_000_000) return { logs: [], transactions: [], blocks: [], nextBlock: query.to_block };
      return {
        logs: [transfer("0xa", 500, USDC, ME, POOL, 100_000_000n, 0), transfer("0xa", 500, FROGE, POOL, ME, 10n ** 23n, 1)],
        transactions: [tx("0xa")], blocks: [block(500, 1000)], nextBlock: 1_000_000,
      };
    },
  };
  const run = (now) => indexWallet(ME, { store, hypersync, price, meta, backfillBlocks: 1_000_000, now: () => now, quietMs: 120_000 });
  assert.equal((await run(1_000)).written, true);
  assert.equal(writes, 1);

  tip += 30;
  const quiet = await run(60_000);
  assert.deepEqual([quiet.written, quiet.complete, writes], [false, true, 1]);
  assert.equal(JSON.parse(await store.get(`wl:${ME}`)).cursor, 1_000_000);

  assert.equal((await run(130_000)).written, true);
  assert.equal(writes, 2);
  assert.equal(JSON.parse(await store.get(`wl:${ME}`)).cursor, 1_000_030);
  assert.equal(JSON.parse(await store.get(`wl:${ME}`)).positions[FROGE].holding, 100_000);

  await indexWallet(ME, { store, hypersync, price, meta, backfillBlocks: 1_000_000, now: () => 131_000 });
  assert.equal(writes, 3);
});

test("a swap against a stable is priced from the stable leg when no candle covers the token", async () => {
  const PEPE = "0xcccc000000000000000000000000000000000003";
  const withPepe = async (token) => token === PEPE ? { symbol: "PEPE", decimals: 18 } : meta(token);
  const ledger = emptyLedger(ME);
  const swap = { hash: "0xa", block: 10, time: 1000_000, kind: "swap", paidNative: 0n, in: [{ token: PEPE, raw: 10n ** 23n }], out: [{ token: USDC, raw: 250_000_000n }] };
  await applyMovement(ledger, swap, { price, meta: withPepe });
  assert.equal(ledger.positions[PEPE].holding, 100_000);
  assert.equal(ledger.positions[PEPE].unpriced, 0);
  assert.equal(ledger.positions[PEPE].basis, 250);
  assert.equal(ledger.trades.length, 1);
  assert.equal(ledger.trades[0].side, "buy");
  assert.equal(ledger.trades[0].value, 250);
  assert.ok(Math.abs(ledger.trades[0].price - 0.0025) < 1e-12);

  // Selling half back for 200 USDC realises against the 250 paid, again without a candle.
  const sell = { hash: "0xb", block: 11, time: 2000_000, kind: "swap", paidNative: 0n, in: [{ token: USDC, raw: 200_000_000n }], out: [{ token: PEPE, raw: 5n * 10n ** 22n }] };
  await applyMovement(ledger, sell, { price, meta: withPepe });
  assert.ok(Math.abs(ledger.realized - 75) < 1e-9);
  assert.equal(ledger.trades[1].side, "sell");
  assert.equal(ledger.trades[1].value, 200);
  // The stable legs themselves are never trades.
  assert.equal(ledger.trades.length, 2);
});

test("money for money: buying MON with AUSD is a MON buy, stable for stable is nothing", async () => {
  const WMON = "0xdddd000000000000000000000000000000000004";
  const AUSD = "0xeeee000000000000000000000000000000000005";
  const metaMore = async (token) => ({ [WMON]: { symbol: "WMON", decimals: 18 }, [AUSD]: { symbol: "AUSD", decimals: 6 } })[token] ?? meta(token);
  const ledger = emptyLedger(ME);
  const buyMon = { hash: "0xa", block: 10, time: 1000_000, kind: "swap", paidNative: 0n, in: [{ token: WMON, raw: 4000n * 10n ** 18n }], out: [{ token: AUSD, raw: 100_000_000n }] };
  await applyMovement(ledger, buyMon, { price: async () => null, meta: metaMore });
  assert.equal(ledger.trades.length, 1);
  assert.equal(ledger.trades[0].symbol, "WMON");
  assert.equal(ledger.trades[0].side, "buy");
  assert.equal(ledger.trades[0].value, 100);
  assert.ok(Math.abs(ledger.trades[0].price - 0.025) < 1e-12);

  const stableSwap = { hash: "0xb", block: 11, time: 2000_000, kind: "swap", paidNative: 0n, in: [{ token: AUSD, raw: 100_000_000n }], out: [{ token: USDC, raw: 100_000_000n }] };
  await applyMovement(ledger, stableSwap, { price, meta: metaMore });
  assert.equal(ledger.trades.length, 1);
});

test("deposits, withdrawals, sends and receipts are moves; airdrop spam is not", async () => {
  const perpl = "0x34b6552d57a35a1d042ccae1951bd1c370112a6f";
  const SPAM = "0xffff000000000000000000000000000000000006";
  const metaMore = async (token) => token === SPAM ? { symbol: "FREE", decimals: 18 } : meta(token);
  const ledger = emptyLedger(ME);
  await applyMovement(ledger, { hash: "0xa", block: 10, time: 1000_000, kind: "sent", to: perpl, counterparty: perpl, paidNative: 0n, in: [], out: [{ token: USDC, raw: 500_000_000n }] }, { price, meta: metaMore });
  await applyMovement(ledger, { hash: "0xb", block: 11, time: 2000_000, kind: "received", to: null, counterparty: perpl, paidNative: 0n, in: [{ token: USDC, raw: 620_000_000n }], out: [] }, { price, meta: metaMore });
  await applyMovement(ledger, { hash: "0xc", block: 12, time: 3000_000, kind: "received", to: null, counterparty: FRIEND, paidNative: 0n, in: [{ token: SPAM, raw: 10n ** 24n }], out: [] }, { price, meta: metaMore });
  await applyMovement(ledger, { hash: "0xd", block: 13, time: 3000_000, kind: "sent", to: USDC, counterparty: FRIEND, paidNative: 0n, in: [], out: [{ token: USDC, raw: 20_000_000n }] }, { price, meta: metaMore });
  assert.deepEqual(ledger.moves.map((move) => [move.kind, move.value]), [["deposit", 500], ["withdraw", 620], ["sent", 20]]);
  assert.equal(ledger.moves[0].counterparty, perpl);
  assert.equal(ledger.moves[2].counterparty, FRIEND);
  // The spam still sits in the ledger as an unpriced holding, as before.
  assert.equal(ledger.positions[SPAM].unpriced, 1_000_000);
  assert.equal(ledger.trades.length, 0);
});

test("movements remember the counterparty and the contract called", () => {
  const page = {
    logs: [transfer("0xa", 10, USDC, ME, POOL, 100_000_000n, 0), transfer("0xa", 10, FROGE, POOL, ME, 10n ** 23n, 1), transfer("0xd", 13, FROGE, ME, FRIEND, 10n ** 21n, 0)],
    transactions: [tx("0xa"), tx("0xd", { to: FROGE, input: "0xa9059cbb0000" })],
    blocks: [block(10, 1000), block(13, 3000)],
  };
  const byHash = Object.fromEntries(groupMovements(ME, page).map((m) => [m.hash, m]));
  assert.equal(byHash["0xa"].to, ROUTER);
  assert.equal(byHash["0xa"].counterparty, POOL);
  assert.equal(byHash["0xd"].counterparty, FRIEND);
});
