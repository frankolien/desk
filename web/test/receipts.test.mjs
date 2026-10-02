import assert from "node:assert/strict";
import { test } from "node:test";

import { memoryStore } from "../api/_store.mjs";
import {
  AUSD, RX_KEY, ausdAmount, extractReceipts, faucetSender, monAmount, receiptDeliveries, receiptPayload, receiptQuery, receiptScan, skipList,
} from "../api/_receipts.mjs";
import { parseSubscription, scan, subscriptionId } from "../api/alerts.mjs";

const ME = "0x82ec56aaf7aa35c6ac62b598e6c964a4b186f775";
const STRANGER = "0xabcd000000000000000000000000000000001234";
const POOL = "0x5555000000000000000000000000000000005555";
const PERPL = "0x34b6552d57a35a1d042ccae1951bd1c370112a6f";
const AGORA_FAUCET = "0xd236c18d274e54faccc3dd9dda4b27965a73ee6c";
const DESK_FAUCET = "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf";
const INSTALL = "ab".repeat(32);
const TOKEN = "cd".repeat(32);
const ETHER = 10n ** 18n;

const topic = (address) => `0x${address.slice(2).padStart(64, "0")}`;
const word = (raw) => `0x${raw.toString(16).padStart(64, "0")}`;
const hash = (n) => `0x${String(n).padStart(64, "0")}`;
const tx = (n, { from = STRANGER, to = AUSD.mainnet, value = 0n, status = 1 } = {}) =>
  ({ block_number: 10 + n, hash: hash(n), from, to, value: `0x${value.toString(16)}`, status });
const log = (n, raw, { from = STRANGER, to = ME, index = 0, token = AUSD.mainnet } = {}) =>
  ({ block_number: 10 + n, transaction_hash: hash(n), log_index: index, address: token, topic1: topic(from), topic2: topic(to), topic3: null, data: word(raw) });
const skip = skipList([DESK_FAUCET]);
const extract = (page) => extractReceipts({ network: "mainnet", page, owners: [ME], skip });

function fakeAPNs() {
  const sent = [];
  return { sent, async send(record, payload, options) { sent.push({ record, payload, options }); return { status: 200, environment: "sandbox" }; }, close() {} };
}

function source(page, { height = 500 } = {}) {
  const calls = { height: 0, raw: [], signals: [] };
  return {
    calls,
    async height(options) { calls.height += 1; calls.signals.push(options?.signal); return height; },
    async raw(query, options) {
      calls.raw.push(query);
      calls.signals.push(options?.signal);
      if (page instanceof Error) throw page;
      return { logs: [], transactions: [], blocks: [], ...page };
    },
  };
}

const me = (networks = ["mainnet", "testnet"]) => ({ address: ME, networks });
const holder = (id = "sub", networks) => ({ id, record: { token: TOKEN, environment: "sandbox", me: me(networks) } });

test("the query asks for AUSD sent to every owner and every transaction to one, a thousand owners per filter", () => {
  const owners = Array.from({ length: 2_500 }, (_, index) => `0x${String(index).padStart(40, "0")}`);
  const query = receiptQuery(owners, "testnet", 77);
  assert.equal(query.from_block, 77);
  assert.equal(query.to_block, undefined);
  assert.deepEqual(query.logs.map((entry) => entry.topics[2].length), [1_000, 1_000, 500]);
  assert.deepEqual(query.transactions.map((entry) => entry.to.length), [1_000, 1_000, 500]);
  assert.deepEqual(query.logs[0].address, [AUSD.testnet]);
  assert.equal(query.logs[0].topics[2][1], topic(owners[1]));
  assert.ok(query.field_selection.transaction.includes("status"));
});

test("MON counts when someone else sends at least a cent's worth in a transaction that succeeded", () => {
  const found = extract({ transactions: [
    tx(1, { to: ME, value: 3n * ETHER / 2n }),
    tx(2, { to: ME, value: ETHER / 1000n }),
    tx(3, { to: ME, value: ETHER, status: 0 }),
    tx(4, { from: ME, to: ME, value: ETHER }),
    tx(5, { from: DESK_FAUCET, to: ME, value: ETHER / 10n }),
    tx(6, { to: POOL, value: ETHER }),
  ] });
  assert.deepEqual(found.map((receipt) => [receipt.token, receipt.amount, receipt.hash]), [["MON", "1.5", hash(1)]]);
  assert.equal(monAmount(12_345_678n * 10n ** 12n), "12.3456");
  assert.equal(monAmount(2n * ETHER), "2");
});

test("AUSD counts from a stranger, never from the venue, a faucet, the bridge or the person's own transaction", () => {
  const found = extract({
    logs: [
      log(1, 25_000_000n),
      log(2, 10_000_000n, { from: PERPL }),
      log(3, 10_000_000n, { from: PERPL }),
      log(4, 10_000_000n, { from: POOL }),
      log(5, 10_000_000n, { from: AGORA_FAUCET }),
      log(6, 10_000_000n),
      log(7, 10_000_000n, { from: "0x4cd00e387622c35bddb9b4c962c136462338bc31" }),
      log(8, 10_000_000n, { token: POOL }),
      log(9, 10_000_000n),
    ],
    transactions: [
      tx(1), tx(2, { from: ME }), tx(3, { from: "0x9999000000000000000000000000000000009999" }), tx(4, { from: ME, to: POOL }),
      tx(5, { from: DESK_FAUCET, to: AGORA_FAUCET }), tx(6, { from: DESK_FAUCET }), tx(7), tx(8),
    ],
  });
  assert.deepEqual(found.map((receipt) => [receipt.token, receipt.amount, receipt.from, receipt.index]), [["AUSD", "25.00", STRANGER, 0]]);
});

test("poisoning dust is ignored, and several AUSD logs in one transaction are one receipt", () => {
  const found = extract({
    logs: [
      log(1, 1n, { from: "0x82ec000000000000000000000000000000000775" }),
      log(2, 0n),
      log(3, 6_000n, { index: 4 }),
      log(3, 6_000n, { index: 7, from: POOL }),
    ],
    transactions: [tx(1, { from: "0x82ec000000000000000000000000000000000775" }), tx(2), tx(3)],
  });
  assert.equal(found.length, 1);
  assert.deepEqual([found[0].amount, found[0].index, found[0].hash], ["0.01", 4, hash(3)]);
  assert.equal(ausdAmount(1_234_567_891n), "1234.56");
});

test("a receipt reads as a sentence; a third one in a scan turns them into one summary", () => {
  const payload = receiptPayload({ network: "mainnet", token: "AUSD", amount: "1250.00", from: STRANGER, hash: hash(1), index: 3 });
  assert.equal(payload.aps.alert.title, "You received 1,250.00 AUSD");
  assert.equal(payload.aps.alert.body, "From 0xabcd…1234 on Monad mainnet.");
  assert.deepEqual([payload.aps.category, payload.aps["thread-id"]], ["desk.receipt", "receipt"]);
  assert.deepEqual(payload.desk, { type: "receipt", network: "mainnet", token: "AUSD", amount: "1250.00", from: STRANGER, hash: hash(1) });

  const mon = { network: "testnet", token: "MON", owner: ME, amount: "1.5", from: STRANGER, hash: hash(2), index: null };
  const ausd = { network: "testnet", token: "AUSD", owner: ME, amount: "25.00", from: STRANGER, hash: hash(3), index: 9 };
  const holders = new Map([[ME, [holder()]]]);
  const two = receiptDeliveries([mon, ausd], holders);
  assert.deepEqual(two.map((delivery) => delivery.collapseId), [`rx-${hash(2).slice(2, 18)}-n`, `rx-${hash(3).slice(2, 18)}-9`]);
  assert.equal(two[0].payload.aps.alert.title, "You received 1.5 MON");
  assert.equal(two[0].payload.aps.alert.body, "From 0xabcd…1234 on Monad testnet.");

  const three = receiptDeliveries([mon, ausd, { ...ausd, hash: hash(4) }], holders);
  assert.equal(three.length, 1);
  assert.equal(three[0].payload.aps.alert.title, "You received 3 deposits");
  assert.equal(three[0].payload.aps.alert.body, "MON and AUSD on Monad testnet.");
  assert.deepEqual(three[0].payload.desk, { type: "receipt", network: "testnet", summary: true });
  assert.equal(three[0].payload.aps.category, "desk.receipt");
  assert.equal(receiptDeliveries([ausd, ausd, ausd], holders)[0].payload.aps.alert.body, "AUSD on Monad testnet.");
  assert.deepEqual(receiptDeliveries([mon], new Map([[ME, [holder("sub", ["mainnet"])]]])), []);
});

test("a missing or hour-old cursor starts at the tip and sends nothing", async () => {
  const now = 10_000_000;
  for (const stored of [null, JSON.stringify({ mainnet: { block: 100, at: now - 3_600_001 } })]) {
    const mainnet = source({ transactions: [tx(1, { to: ME, value: ETHER })], nextBlock: 600 });
    const result = await receiptScan({ sources: { mainnet }, skip, subscribers: [holder("sub", ["mainnet"])], stored, now });
    assert.deepEqual([result.deliveries, mainnet.calls.height, mainnet.calls.raw.length], [[], 1, 0]);
    assert.deepEqual([result.due, result.next], [true, { mainnet: { block: 500, at: now } }]);
  }
});

test("a fresh cursor reads from where it stopped and moves to the next block", async () => {
  const now = 10_000_000;
  const mainnet = source({ transactions: [tx(1, { to: ME, value: ETHER })], nextBlock: 640 });
  const testnet = source({ nextBlock: 90 });
  const stored = JSON.stringify({ mainnet: { block: 600, at: now - 60_000 }, testnet: { block: 80, at: now - 60_000 } });
  const result = await receiptScan({ sources: { mainnet, testnet }, skip, subscribers: [holder()], stored, now });
  assert.equal(mainnet.calls.raw[0].from_block, 600);
  assert.equal(mainnet.calls.height, 0);
  assert.equal(result.deliveries.length, 1);
  assert.equal(result.deliveries[0].payload.desk.network, "mainnet");
  assert.deepEqual([result.due, result.next], [true, { mainnet: { block: 640, at: now }, testnet: { block: 90, at: now } }]);
});

test("a quiet cursor is saved every ten minutes, not every scan", async () => {
  const now = 10_000_000;
  const mainnet = source({ nextBlock: 700 });
  const subscribers = [holder("sub", ["mainnet"])];
  const quiet = await receiptScan({ sources: { mainnet }, skip, subscribers, stored: JSON.stringify({ mainnet: { block: 600, at: now - 60_000 } }), now });
  assert.equal(quiet.due, false);
  assert.equal(mainnet.calls.raw.length, 1);
  const due = await receiptScan({ sources: { mainnet }, skip, subscribers, stored: JSON.stringify({ mainnet: { block: 600, at: now - 10 * 60_000 } }), now });
  assert.deepEqual([due.due, due.next], [true, { mainnet: { block: 700, at: now } }]);
});

test("a failed query keeps the cursor and sends nothing for that network", async () => {
  const now = 10_000_000;
  const stored = JSON.stringify({ mainnet: { block: 600, at: now - 60_000 }, testnet: { block: 80, at: now - 60_000 } });
  const mainnet = source(new Error("hypersync 429"));
  const testnet = source({ transactions: [tx(1, { to: ME, value: ETHER })], nextBlock: 95 });
  const result = await receiptScan({ sources: { mainnet, testnet }, skip, subscribers: [holder()], stored, now });
  assert.deepEqual(result.errors, ["receipts mainnet: hypersync 429"]);
  assert.deepEqual(result.deliveries.map((delivery) => delivery.payload.desk.network), ["testnet"]);
  assert.deepEqual(result.next, { mainnet: { block: 600, at: now - 60_000 }, testnet: { block: 95, at: now } });

  const none = await receiptScan({ sources: { mainnet: source(new Error("down")) }, skip, subscribers: [holder("sub", ["mainnet"])], stored, now });
  assert.deepEqual([none.due, none.deliveries], [false, []]);

  const idle = source({});
  const nobody = await receiptScan({ sources: { mainnet: idle }, skip, subscribers: [{ id: "x", record: { me: null } }], stored: null, now });
  assert.deepEqual([idle.calls.height, idle.calls.raw.length, nobody.due], [0, 0, false]);
});

test("the scan saves the cursor before it sends, and a receipt failure never stops the rest", async () => {
  const now = Date.now();
  const store = memoryStore();
  const id = subscriptionId(INSTALL);
  const body = { install: INSTALL, token: TOKEN, environment: "sandbox", traders: [], prices: false, me: me(["mainnet"]) };
  await store.set(`alerts:sub:${id}`, JSON.stringify(parseSubscription(body).record));
  await store.sadd("alerts:subs", id);
  await store.set(RX_KEY, JSON.stringify({ mainnet: { block: 600, at: now - 60_000 } }));

  const order = [];
  const setMany = store.setMany.bind(store);
  store.setMany = async (entries, ...rest) => { if (entries.some(([key]) => key === RX_KEY)) order.push("cursor"); return setMany(entries, ...rest); };
  const apns = fakeAPNs();
  const send = apns.send.bind(apns);
  apns.send = async (...args) => { order.push("send"); return send(...args); };
  const mainnet = source({ logs: [log(1, 25_000_000n)], transactions: [tx(1)], nextBlock: 610 });
  const report = await scan({ store, chain: {}, apns, markets: new Map(), sources: { mainnet }, skip, now });
  assert.deepEqual(order, ["cursor", "send"]);
  assert.deepEqual(report.receipts, { events: 1, sent: 1 });
  assert.equal(apns.sent[0].record.token, TOKEN);
  assert.equal(apns.sent[0].payload.aps.alert.title, "You received 25.00 AUSD");

  const failing = await scan({ store, chain: {}, apns, markets: new Map(), sources: { mainnet: source(new Error("hypersync 503")) }, skip, now });
  assert.deepEqual(failing.errors, ["receipts mainnet: hypersync 503"]);
  assert.equal(JSON.parse(await store.get(RX_KEY)).mainnet.block, 610);
});

test("a scan that fails at its write keeps the deposit cursor, so the next scan finds the same deposit", async () => {
  const now = Date.now();
  const store = memoryStore();
  const id = subscriptionId(INSTALL);
  const body = { install: INSTALL, token: TOKEN, environment: "sandbox", traders: [], prices: false, me: me(["mainnet"]) };
  await store.set(`alerts:sub:${id}`, JSON.stringify(parseSubscription(body).record));
  await store.sadd("alerts:subs", id);
  await store.set(RX_KEY, JSON.stringify({ mainnet: { block: 600, at: now - 60_000 } }));
  const mainnet = source({ logs: [log(1, 25_000_000n)], transactions: [tx(1)], nextBlock: 610 });
  const setMany = store.setMany;
  store.setMany = async () => { throw new Error("redis pipeline"); };
  const apns = fakeAPNs();
  await assert.rejects(scan({ store, chain: {}, apns, markets: new Map(), sources: { mainnet }, skip, now }));
  assert.equal(apns.sent.length, 0);
  assert.equal(JSON.parse(await store.get(RX_KEY)).mainnet.block, 600);

  store.setMany = setMany;
  const report = await scan({ store, chain: {}, apns, markets: new Map(), sources: { mainnet }, skip, now: now + 60_000 });
  assert.equal(mainnet.calls.raw[1].from_block, 600);
  assert.deepEqual(report.receipts, { events: 1, sent: 1 });
  assert.equal(JSON.parse(await store.get(RX_KEY)).mainnet.block, 610);
});

test("a query that hangs past its time limit is an error for that network, which keeps its cursor", async () => {
  const now = 10_000_000;
  const stored = JSON.stringify({ mainnet: { block: 600, at: now - 60_000 }, testnet: { block: 80, at: now - 60_000 } });
  const hanging = { calls: { signals: [] }, height: () => new Promise(() => {}), raw(query, { signal }) { this.calls.signals.push(signal); return new Promise(() => {}); } };
  const testnet = source({ transactions: [tx(1, { to: ME, value: ETHER })], nextBlock: 95 });
  const started = Date.now();
  const result = await receiptScan({ sources: { mainnet: hanging, testnet }, skip, subscribers: [holder()], stored, now, timeoutMs: 30 });
  assert.ok(Date.now() - started < 1_000);
  assert.deepEqual(result.errors, ["receipts mainnet: timed out"]);
  assert.ok(hanging.calls.signals[0].aborted);
  assert.equal(testnet.calls.signals[0].aborted, false);
  assert.deepEqual(result.deliveries.map((delivery) => delivery.payload.desk.network), ["testnet"]);
  assert.deepEqual(result.next, { mainnet: { block: 600, at: now - 60_000 }, testnet: { block: 95, at: now } });

  const tip = await receiptScan({ sources: { mainnet: hanging }, skip, subscribers: [holder("sub", ["mainnet"])], stored: null, now, timeoutMs: 30 });
  assert.deepEqual(tip.errors, ["receipts mainnet: timed out"]);
});

test("the deposit query runs while trader books are read, and a slow one never holds back trader pushes", async () => {
  const ALICE = "0x95d2602d30da1179fd13274839e60345857ca648";
  const now = Date.now();
  const store = memoryStore();
  const id = subscriptionId(INSTALL);
  const body = { install: INSTALL, token: TOKEN, environment: "sandbox", traders: [ALICE], prices: false, me: me(["mainnet"]) };
  await store.set(`alerts:sub:${id}`, JSON.stringify(parseSubscription(body).record));
  await store.sadd("alerts:subs", id);
  await store.set(RX_KEY, JSON.stringify({ mainnet: { block: 600, at: now - 60_000 } }));
  await store.set(`alerts:snap2:${ALICE}`, JSON.stringify({ at: now - 60_000, book: { 20: { market: "ETH", marketId: 20, side: "long", size: "5", value: "100" } } }));

  let queried;
  const asked = new Promise((resolve) => { queried = resolve; });
  const mainnet = { height: async () => 600, raw() { queried(); return new Promise(() => {}); } };
  const chain = {
    async accountByAddress() {
      let timer;
      await Promise.race([asked, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("not concurrent")), 500); })])
        .finally(() => clearTimeout(timer));
      return { accountId: 1n, positions: { bank1: 0n } };
    },
    async openPosition() { return null; },
  };
  const apns = fakeAPNs();
  const report = await scan({ store, chain, apns, markets: new Map(), sources: { mainnet }, skip, now, receiptTimeoutMs: 50 });
  assert.deepEqual(apns.sent.map((entry) => entry.payload.desk.event), ["closed"]);
  assert.deepEqual(report.errors, ["receipts mainnet: timed out"]);
  assert.equal(JSON.parse(await store.get(RX_KEY)).mainnet.block, 600);
});

test("the faucet's sender is read from its key", () => {
  assert.equal(faucetSender(`0x${"0".repeat(63)}1`), DESK_FAUCET);
  assert.equal(faucetSender(undefined), null);
  assert.ok(skipList([DESK_FAUCET]).has(PERPL));
});
