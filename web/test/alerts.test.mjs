// node --test web/test/alerts.test.mjs
import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { test } from "node:test";

import { isDeadToken, providerToken, readPrivateKey } from "../api/_apns.mjs";
import { memoryStore } from "../api/_store.mjs";
import {
  alertPayload, compactDollars, createHandler, parseSubscription, readBook, scan, subscriptionId, tradeEvents,
} from "../api/alerts.mjs";

const ALICE = "0x95d2602d30da1179fd13274839e60345857ca648";
const INSTALL = "ab".repeat(32);
const TOKEN = "cd".repeat(32);
const ETH = { id: 20, name: "ETH", config: { is_open: true, price_decimals: 2, size_decimals: 0 } };
const markets = new Map([[20, ETH]]);

const row = (overrides) => ({
  accountId: 3901n, positionType: 0, depositCNS: 2_309_980_000n, pricePNS: 184_799n,
  lotLNS: 5n, entryBlock: 1n, pnlCNS: 3_047_920_000n, ...overrides,
});

function fakeChain(state) {
  return {
    async accountByAddress() {
      if (state.fail) throw new Error("rpc");
      if (state.noAccount) return null;
      return { accountId: 3901n, positions: { bank1: state.row ? 1n << 20n : 0n } };
    },
    async openPosition() { return state.row ? { row: state.row, mark: 244_722n } : null; },
  };
}

function fakeAPNs(result = { status: 200, environment: "sandbox" }) {
  const sent = [];
  return { sent, async send(record, payload, options) { sent.push({ record, payload, options }); return typeof result === "function" ? result(record) : result; }, close() {} };
}

function recorder() {
  const out = { status: null, body: null };
  return { status(code) { out.status = code; return this; }, json(value) { out.body = value; return out; } };
}

const subscribe = (overrides = {}) => ({ install: INSTALL, token: TOKEN, environment: "sandbox", traders: [ALICE], names: { [ALICE]: "Whale" }, ...overrides });

test("subscriptions are validated and keyed by the install secret, never the token", () => {
  const parsed = parseSubscription(subscribe({ traders: [ALICE, ALICE.toUpperCase().replace("0X", "0x")] }));
  assert.equal(parsed.id, subscriptionId(INSTALL));
  assert.notEqual(parsed.id, TOKEN);
  assert.deepEqual(parsed.record.traders, [ALICE]);
  assert.equal(parsed.record.names[ALICE], "Whale");
  assert.ok(parseSubscription(subscribe({ install: "short" })).error);
  assert.ok(parseSubscription(subscribe({ token: "not hex" })).error);
  assert.ok(parseSubscription(subscribe({ traders: Array(21).fill(ALICE) })).error);
  assert.ok(parseSubscription(subscribe({ traders: ["0x123"] })).error);
});

test("a book diff names opens, flips, meaningful adds and closes, and ignores trims", () => {
  const long = { market: "ETH", marketId: 20, side: "long", size: "5", value: "100" };
  assert.deepEqual(tradeEvents({}, { 20: long }).map((e) => e.kind), ["opened"]);
  assert.deepEqual(tradeEvents({ 20: long }, {}).map((e) => e.kind), ["closed"]);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, side: "short" } }).map((e) => e.kind), ["flipped"]);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, size: "6" } }).map((e) => e.kind), ["added"]);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, size: "5.2" } }), []);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, size: "2" } }), []);
});

test("an alert reads like a sentence and carries what the app needs to copy", () => {
  const position = { market: "ETH", marketId: 20, side: "long", size: "5", entry: "1847.99", value: "12236.1", pnl: "3047.92", leverage: 4 };
  const payload = alertPayload(ALICE, "Whale", { kind: "opened", position });
  assert.equal(payload.aps.alert.title, "Whale opened a long");
  assert.equal(payload.aps.alert.body, "ETH 4× at $1,847.99, $12K position. Tap to copy.");
  assert.deepEqual([payload.desk.market, payload.desk.side, payload.desk.leverage], ["ETH", "long", 4]);
  assert.equal(payload.aps.category, "desk.trade");
  assert.equal(alertPayload(ALICE, "Whale", { kind: "closed", position }).aps.category, "desk.trade.closed");
  assert.equal(alertPayload(ALICE, undefined, { kind: "closed", position }).aps.alert.title, "0x95d2…a648 closed their ETH long");
  assert.equal(compactDollars("-1234.5"), "−$1.2K");
});

test("an unreadable account is unknown, not empty", async () => {
  assert.equal(await readBook(fakeChain({ noAccount: true }), markets, ALICE), null);
  const book = await readBook(fakeChain({ row: row() }), markets, ALICE);
  assert.deepEqual([book[20].side, book[20].leverage, book[20].entry], ["long", 4, "1847.99"]);
});

test("the first scan sets a baseline, the next one pushes what changed to every follower", async () => {
  const store = memoryStore();
  const apns = fakeAPNs();
  const state = { row: row() };
  const handler = createHandler(() => ({ store, apns, chain: fakeChain(state), markets: async () => markets, secret: "s3cret", sleep: async () => {} }));

  const subscribed = await handler({ method: "POST", query: {}, body: subscribe() }, recorder());
  assert.equal(subscribed.status, 200);

  const first = await scan({ store, chain: fakeChain(state), apns, markets });
  assert.deepEqual([first.traders, first.sent], [1, 0]);

  state.row = row({ positionType: 1 });
  const second = await scan({ store, chain: fakeChain(state), apns, markets });
  assert.equal(second.sent, 1);
  assert.equal(apns.sent[0].payload.aps.alert.title, "Whale flipped short on ETH");
  assert.equal(apns.sent[0].record.token, TOKEN);

  // An RPC failure keeps the last book, so nothing is announced as closed.
  const failed = await scan({ store, chain: fakeChain({ fail: true }), apns, markets });
  assert.equal(failed.sent, 0);
  state.row = null;
  const closed = await scan({ store, chain: fakeChain(state), apns, markets });
  assert.equal(closed.sent, 1);
  assert.match(apns.sent[1].payload.aps.alert.title, /closed their ETH short/);
});

test("a dead token removes its subscription; a token of the other kind is remembered", async () => {
  const store = memoryStore();
  const id = subscriptionId(INSTALL);
  await store.set(`alerts:sub:${id}`, JSON.stringify(parseSubscription(subscribe()).record));
  await store.sadd("alerts:subs", id);
  await store.set(`alerts:snap:${ALICE}`, JSON.stringify({}));

  await scan({ store, chain: fakeChain({ row: row() }), apns: fakeAPNs({ status: 200, environment: "production" }), markets });
  assert.equal(JSON.parse(store.values.get(`alerts:sub:${id}`)).environment, "production");

  await store.set(`alerts:snap:${ALICE}`, JSON.stringify({}));
  await scan({ store, chain: fakeChain({ row: row() }), apns: fakeAPNs({ status: 410, reason: "Unregistered" }), markets });
  assert.equal(store.values.has(`alerts:sub:${id}`), false);
  assert.deepEqual(await store.smembers("alerts:subs"), []);
  assert.ok(isDeadToken({ status: 400, reason: "BadDeviceToken" }));
  assert.ok(!isDeadToken({ status: 429, reason: "TooManyRequests" }));
});

test("the scan needs the scheduler's secret and runs one at a time", async () => {
  const store = memoryStore();
  const handler = createHandler(() => ({ store, apns: fakeAPNs(), chain: fakeChain({}), markets: async () => markets, secret: "s3cret", sleep: async () => {} }));
  const denied = await handler({ method: "GET", query: { job: "scan" }, headers: { authorization: "Bearer wrong" } }, recorder());
  assert.equal(denied.status, 401);
  const res = await handler({ method: "GET", query: { job: "scan", rounds: "2" }, headers: { authorization: "Bearer s3cret" } }, recorder());
  // No subscribers: the first round says so and the rest are skipped.
  assert.equal(res.body.rounds.length, 1);
  await store.set("alerts:lock", "1");
  const skipped = await handler({ method: "GET", query: { job: "scan" }, headers: { authorization: "Bearer s3cret" } }, recorder());
  assert.equal(skipped.body.skipped, true);
});

test("the first switch-on sends one confirmation, and an empty list unsubscribes", async () => {
  const store = memoryStore();
  const apns = fakeAPNs();
  const handler = createHandler(() => ({ store, apns, chain: fakeChain({}), markets: async () => markets, secret: "x", sleep: async () => {} }));
  const on = await handler({ method: "POST", query: {}, body: subscribe({ confirm: true }) }, recorder());
  assert.deepEqual(on.body, { traders: 1, confirmed: true });
  assert.equal(apns.sent[0].payload.aps.alert.title, "Trade alerts are on");
  await handler({ method: "POST", query: {}, body: subscribe({ confirm: true }) }, recorder());
  assert.equal(apns.sent.length, 1);
  const off = await handler({ method: "POST", query: {}, body: subscribe({ traders: [] }) }, recorder());
  assert.equal(off.body.traders, 0);
  assert.deepEqual(await store.smembers("alerts:subs"), []);
});

test("the provider token is ES256 over the team and key", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" });
  const jwt = providerToken({ keyId: "ABC123DEFG", teamId: "YCKKUWB4WD", privateKey: pem }, 1_700_000_000_000);
  const [header, claims, signature] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url")), { iss: "YCKKUWB4WD", iat: 1_700_000_000 });
  assert.ok(verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")));
  assert.equal(readPrivateKey(pem.replace(/\n/g, "\\n")), pem);
  assert.equal(readPrivateKey(Buffer.from(pem).toString("base64")), pem);
});
