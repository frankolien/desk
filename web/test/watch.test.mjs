// node --test web/test/watch.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { memoryStore } from "../api/_store.mjs";
import { newestMarker, seenKey, walletEvents, walletPayload } from "../api/_watch.mjs";
import { createHandler, parseSubscription, scan, subscriptionId } from "../api/alerts.mjs";

const WHALE = "0x06b6000000000000000000000000000000006911";
const GRIZZLE = "0xaaaa000000000000000000000000000000000001";
const CHOG = "0xbbbb000000000000000000000000000000000002";
const MOYAKI = "0xcccc000000000000000000000000000000000003";
const INSTALL = "ab".repeat(32);
const TOKEN = "cd".repeat(32);
const MIN = 60_000;

test("alert markers preserve case-sensitive Solana wallet keys", () => {
  const solana = "Fw1ETanDZafof7xEULsnq9UY6o71Tpds89tNwPkWLb1v";
  assert.equal(seenKey(solana), `alerts:seen:${solana}`);
  assert.equal(seenKey(WHALE.toUpperCase().replace("0X", "0x")), `alerts:seen:${WHALE}`);
});

let hashes = 0;
const trade = (time, token, symbol, side, amount, value, gain = null) =>
  ({ time, hash: `0x${(hashes += 1).toString(16).padStart(4, "0")}`, token, symbol, side, amount, price: value / amount, value, gain });
const ledger = (trades, positions = {}) => ({ address: WHALE, trades, positions });
const kinds = (events) => events.map((event) => event.kind);

const history = () => [
  trade(10 * MIN, GRIZZLE, "GRIZZLE", "buy", 12_400, 310),
  trade(30 * MIN, GRIZZLE, "GRIZZLE", "buy", 4_100, 102),
  trade(50 * MIN, GRIZZLE, "GRIZZLE", "sell", 8_000, 1_900, 412),
  trade(70 * MIN, GRIZZLE, "GRIZZLE", "sell", 8_500, 7_950, 4_200),
];

function fakeAPNs(result = { status: 200, environment: "sandbox" }) {
  const sent = [];
  return { sent, async send(record, payload, options) { sent.push({ record, payload, options }); return result; }, close() {} };
}

function recorder() {
  const out = { status: null, body: null };
  return { status(code) { out.status = code; return this; }, json(value) { out.body = value; return out; } };
}

const subscribe = (overrides = {}) => ({ install: INSTALL, token: TOKEN, environment: "sandbox", traders: [], ...overrides });

test("a buy that opens a position is a first buy, a sell that empties one is a close", () => {
  const open = ledger(history(), { [GRIZZLE]: { holding: 8_500 } });
  assert.deepEqual(kinds(walletEvents(null, open, { minUsd: 0 })), ["first", "buy", "sell", "sell"]);
  const flat = ledger(history(), { [GRIZZLE]: { holding: 0 } });
  assert.deepEqual(kinds(walletEvents(null, flat, { minUsd: 0 })), ["first", "buy", "sell", "close"]);
  // Only the newest sell may read the position; the earlier one cannot know what was left.
  assert.equal(walletEvents(null, flat, { minUsd: 0 })[2].kind, "sell");
});

test("the seen marker hides everything already announced, by hash and then by time", () => {
  const trades = history();
  const flat = ledger(trades, { [GRIZZLE]: { holding: 0 } });
  const marker = { time: trades[1].time, hash: trades[1].hash };
  assert.deepEqual(kinds(walletEvents(marker, flat, { minUsd: 0 })), ["sell", "close"]);
  assert.deepEqual(walletEvents(newestMarker(flat), flat, { minUsd: 0 }), []);
  assert.deepEqual(kinds(walletEvents({ time: 60 * MIN, hash: "0xgone" }, flat, { minUsd: 0 })), ["close"]);
  assert.deepEqual(newestMarker({ trades: [] }), { time: 0, hash: null });
});

test("small trades are dropped below the minimum, but a close always gets through", () => {
  const flat = ledger(history(), { [GRIZZLE]: { holding: 0 } });
  assert.deepEqual(kinds(walletEvents(null, flat, { minUsd: 250 })), ["first", "sell", "close"]);
  assert.deepEqual(kinds(walletEvents(null, flat, { minUsd: 10_000 })), ["close"]);
  assert.deepEqual(kinds(walletEvents(null, flat, { minUsd: 0, firstBuysOnly: true })), ["first", "close"]);
});

test("a burst of the same trade inside five minutes is one event with a count", () => {
  const trades = [
    trade(0, CHOG, "CHOG", "buy", 1_000, 100),
    trade(60 * MIN, CHOG, "CHOG", "buy", 2_000, 400),
    trade(62 * MIN, CHOG, "CHOG", "buy", 2_000, 400),
    trade(64 * MIN, CHOG, "CHOG", "buy", 2_000, 400),
    trade(70 * MIN, CHOG, "CHOG", "buy", 2_000, 400),
    trade(71 * MIN, MOYAKI, "MOYAKI", "sell", 10, 300, 20),
    trade(72 * MIN, MOYAKI, "MOYAKI", "sell", 10, 300, null),
  ];
  const events = walletEvents({ time: 0, hash: trades[0].hash }, ledger(trades, { [MOYAKI]: { holding: 1 } }), { minUsd: 0 });
  assert.deepEqual(events.map((event) => [event.kind, event.count, event.value, event.gain]), [
    ["buy", 3, 1_200, null], ["buy", 1, 400, null], ["sell", 2, 600, 20],
  ]);
  assert.equal(events[0].amount, 6_000);
});

test("an alert reads like a sentence, and the four shapes are exact", () => {
  const wallet = { address: WHALE, name: null };
  const body = (event) => walletPayload({}, wallet, event).aps.alert.body;
  assert.equal(body({ kind: "first", symbol: "GRIZZLE", amount: 12_400, value: 310, count: 1 }), "🐋 bought 12.4K GRIZZLE ($310) · first buy");
  assert.equal(body({ kind: "buy", symbol: "CHOG", amount: 4_100, value: 102, count: 1 }), "🎯 added 4.1K CHOG ($102)");
  assert.equal(body({ kind: "buy", symbol: "CHOG", amount: 6_000, value: 1_200, count: 3 }), "🎯 bought CHOG 3× ($1.2K total)");
  assert.equal(body({ kind: "sell", symbol: "MOYAKI", amount: 60_000, value: 1_900, gain: 412, count: 1 }), "📤 sold 60.0K MOYAKI ($1.9K) · +$412 realized");
  assert.equal(body({ kind: "sell", symbol: "MOYAKI", amount: 60_000, value: 1_900, gain: null, count: 1 }), "📤 sold 60.0K MOYAKI ($1.9K)");
  assert.equal(body({ kind: "close", symbol: "GRIZZLE", amount: 8_500, value: 7_950, gain: 4_200, count: 1 }), "✅ closed GRIZZLE · +$4.2K (+112%)");
  assert.equal(body({ kind: "close", symbol: "GRIZZLE", amount: 8_500, value: 600, gain: -400, count: 1 }), "✅ closed GRIZZLE · −$400 (−40%)");

  const payload = walletPayload({}, wallet, { kind: "first", token: GRIZZLE, symbol: "GRIZZLE", amount: 12_400, value: 310, gain: null, count: 1 });
  assert.equal(payload.aps.alert.title, "0x06b6…6911");
  assert.equal(payload.aps["thread-id"], `wallet-${WHALE}`);
  assert.equal(payload.aps.category, "desk.wallet");
  assert.deepEqual([payload.desk.type, payload.desk.event, payload.desk.wallet, payload.desk.chainIndex, payload.desk.valueUsd], ["wallet", "first", WHALE, "143", 310]);
  assert.equal(walletPayload({}, { address: WHALE, name: "Whale" }, { kind: "first", symbol: "X", amount: 1, value: 1 }).aps.alert.title, "Whale");

  const digest = walletPayload({}, null, { kind: "digest", count: 4 });
  assert.equal(digest.aps.alert.title, "Tracked wallets");
  assert.equal(digest.aps.alert.body, "4 tracked wallets traded in the last 15 min");
  assert.equal(digest.desk.event, "digest");
});

test("a subscription may track wallets, each with a name, a floor and a first-buys switch", () => {
  const parsed = parseSubscription(subscribe({ wallets: [
    { address: WHALE.toUpperCase().replace("0X", "0x"), name: " The Whale ", minUsd: 500, firstBuysOnly: true },
    { address: GRIZZLE },
    { address: WHALE, name: "duplicate" },
  ] }));
  assert.deepEqual(parsed.record.wallets, [
    { address: WHALE, name: "The Whale", minUsd: 500, firstBuysOnly: true },
    { address: GRIZZLE, name: null, minUsd: 250, firstBuysOnly: false },
  ]);
  assert.deepEqual(parseSubscription(subscribe()).record.wallets, []);
  assert.ok(parseSubscription(subscribe({ wallets: "nope" })).error);
  assert.ok(parseSubscription(subscribe({ wallets: [{ address: "0x123" }] })).error);
  assert.ok(parseSubscription(subscribe({ wallets: [{ address: WHALE, minUsd: -1 }] })).error);
  assert.ok(parseSubscription(subscribe({ wallets: [{ address: WHALE, minUsd: "250" }] })).error);
  assert.ok(parseSubscription(subscribe({ wallets: [{ address: WHALE, firstBuysOnly: "yes" }] })).error);
  assert.ok(parseSubscription(subscribe({ wallets: Array(26).fill({ address: WHALE }) })).error);
});

test("tracking a wallet asks the worker to index it, and a wallet-only subscription is still a subscription", async () => {
  const store = memoryStore();
  const apns = fakeAPNs();
  const handler = createHandler(() => ({ store, apns, chain: {}, markets: async () => new Map(), secret: "s3cret", sleep: async () => {} }));
  const on = await handler({ method: "POST", query: {}, body: subscribe({ wallets: [{ address: WHALE, name: "Whale" }] }) }, recorder());
  assert.deepEqual(on.body, { traders: 0, wallets: 1, confirmed: true });
  assert.equal(apns.sent[0].payload.aps.alert.title, "Wallet alerts are on");
  assert.equal(apns.sent[0].payload.aps.alert.body, "You'll hear when Whale trades on Monad.");
  assert.deepEqual(await store.smembers("wl:tracked"), [WHALE]);
  assert.deepEqual(await store.smembers("wl:urgent"), [WHALE]);
  assert.equal(await store.scard("alerts:subs"), 1);
  const off = await handler({ method: "POST", query: {}, body: subscribe({ wallets: [] }) }, recorder());
  assert.equal(off.body.traders, 0);
  assert.equal(await store.scard("alerts:subs"), 0);
});

async function tracking(store, wallets) {
  const id = subscriptionId(INSTALL);
  await store.set(`alerts:sub:${id}`, JSON.stringify(parseSubscription(subscribe({ wallets })).record));
  await store.sadd("alerts:subs", id);
  return id;
}

test("the first scan sets a baseline, the next one pushes the new trade, and the marker moves on", async () => {
  const store = memoryStore();
  const apns = fakeAPNs();
  await tracking(store, [{ address: WHALE, name: "Whale" }]);
  const trades = [trade(10 * MIN, GRIZZLE, "GRIZZLE", "buy", 12_400, 310)];
  const scanArgs = { store, chain: {}, apns, markets: new Map(), now: 100 * MIN };

  const unindexed = await scan(scanArgs);
  assert.deepEqual(unindexed.wallets, { watched: 1, events: 0, sent: 0 });
  assert.equal(await store.get(`alerts:seen:${WHALE}`), null);

  await store.set(`wl:${WHALE}`, JSON.stringify(ledger(trades, { [GRIZZLE]: { holding: 12_400 } })));
  const baseline = await scan(scanArgs);
  assert.deepEqual(baseline.wallets, { watched: 1, events: 0, sent: 0 });
  assert.deepEqual(JSON.parse(await store.get(`alerts:seen:${WHALE}`)), { time: trades[0].time, hash: trades[0].hash });

  trades.push(trade(40 * MIN, CHOG, "CHOG", "buy", 4_100, 402));
  await store.set(`wl:${WHALE}`, JSON.stringify(ledger(trades, { [GRIZZLE]: { holding: 12_400 }, [CHOG]: { holding: 4_100 } })));
  const pushed = await scan(scanArgs);
  assert.deepEqual(pushed.wallets, { watched: 1, events: 1, sent: 1 });
  assert.equal(pushed.sent, 1);
  assert.equal(apns.sent[0].payload.aps.alert.title, "Whale");
  assert.equal(apns.sent[0].payload.aps.alert.body, "🐋 bought 4.1K CHOG ($402) · first buy");
  assert.equal(apns.sent[0].record.token, TOKEN);
  assert.deepEqual(JSON.parse(await store.get(`alerts:seen:${WHALE}`)), { time: trades[1].time, hash: trades[1].hash });

  const quiet = await scan(scanArgs);
  assert.deepEqual(quiet.wallets, { watched: 1, events: 0, sent: 0 });
  assert.equal(apns.sent.length, 1);
});

test("twenty pushes an hour per subscription, then one digest every fifteen minutes", async () => {
  const store = memoryStore();
  const apns = fakeAPNs();
  const id = await tracking(store, [{ address: WHALE }]);
  await store.set(`alerts:seen:${WHALE}`, JSON.stringify({ time: 0, hash: null }));
  const token = (index) => `0x${String(index + 1).padStart(40, "0")}`;
  const trades = Array.from({ length: 25 }, (_, index) => trade((index + 1) * MIN, token(index), `T${index}`, "buy", 100, 300));
  await store.set(`wl:${WHALE}`, JSON.stringify(ledger(trades)));
  const scanArgs = { store, chain: {}, apns, markets: new Map(), now: 100 * MIN };

  const flood = await scan(scanArgs);
  assert.deepEqual(flood.wallets, { watched: 1, events: 25, sent: 21 });
  assert.equal(apns.sent.filter((entry) => entry.payload.desk.event === "digest").length, 1);
  assert.equal(apns.sent.at(-1).payload.aps.alert.body, "1 tracked wallet traded in the last 15 min");
  assert.equal(await store.get(`alerts:wcount:${id}:${Math.floor((100 * MIN) / 3_600_000)}`), "25");

  trades.push(trade(90 * MIN, CHOG, "CHOG", "buy", 100, 300));
  await store.set(`wl:${WHALE}`, JSON.stringify(ledger(trades)));
  const capped = await scan(scanArgs);
  assert.deepEqual(capped.wallets, { watched: 1, events: 1, sent: 0 });
  assert.equal(apns.sent.length, 21);
});
