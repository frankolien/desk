import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { test } from "node:test";

import { createPublicClient, custom, parseAbi } from "viem";

import { isDeadToken, providerToken, readPrivateKey } from "../api/_apns.mjs";
import { memoryStore } from "../api/_store.mjs";
import {
  MAX_TRADERS, NO_ACCOUNT, WAKE_CAP, alertPayload, compactDollars, createHandler, movesSentence, parseSubscription, readBook, scan,
  shareBudget, subscriptionId, summaryPayload, tradeEvents, withinWakeBudget,
} from "../api/alerts.mjs";
import { noAccount } from "../api/traders.mjs";

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
  assert.ok(parseSubscription(subscribe({ traders: Array(MAX_TRADERS + 1).fill(ALICE) })).error);
  assert.equal(parseSubscription(subscribe({ traders: Array(45).fill(ALICE) })).error, undefined);
  assert.ok(parseSubscription(subscribe({ copying: Array(21).fill(ALICE) })).error);
  assert.ok(parseSubscription(subscribe({ traders: ["0x123"] })).error);
});

test("a book diff names opens, flips, meaningful adds, trims of a quarter or more, and closes", () => {
  const long = { market: "ETH", marketId: 20, side: "long", size: "5", value: "100" };
  assert.deepEqual(tradeEvents({}, { 20: long }).map((e) => e.kind), ["opened"]);
  assert.deepEqual(tradeEvents({ 20: long }, {}).map((e) => e.kind), ["closed"]);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, side: "short" } }).map((e) => e.kind), ["flipped"]);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, size: "6" } }).map((e) => e.kind), ["added"]);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, size: "5.2" } }), []);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, size: "2" } }).map((e) => e.kind), ["reduced"]);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, size: "3.75" } }).map((e) => e.kind), ["reduced"]);
  assert.deepEqual(tradeEvents({ 20: long }, { 20: { ...long, size: "4" } }), []);
  assert.equal(tradeEvents({ 20: long }, { 20: { ...long, size: "2", value: "40" } })[0].previous.value, "100");
  assert.deepEqual(tradeEvents({ 20: { ...long, size: "0" } }, { 20: { ...long, size: "0" } }), []);
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
  assert.equal(apns.sent.length, 1);
  assert.equal(apns.sent[0].payload.desk.type, "confirmation");
  apns.sent.length = 0;

  const first = await scan({ store, chain: fakeChain(state), apns, markets });
  assert.deepEqual([first.traders, first.sent], [1, 0]);

  state.row = row({ positionType: 1 });
  const second = await scan({ store, chain: fakeChain(state), apns, markets });
  assert.equal(second.sent, 1);
  assert.equal(apns.sent[0].payload.aps.alert.title, "Whale flipped short on ETH");
  assert.equal(apns.sent[0].record.token, TOKEN);

  const failed = await scan({ store, chain: fakeChain({ fail: true }), apns, markets });
  assert.equal(failed.sent, 0);
  state.row = null;
  const closed = await scan({ store, chain: fakeChain(state), apns, markets });
  assert.equal(closed.sent, 1);
  assert.match(apns.sent[1].payload.aps.alert.title, /closed their ETH short/);
});

test("a subscription is only stored once Apple accepts a push for its token", async () => {
  const store = memoryStore();
  const refused = fakeAPNs({ status: 400, reason: "BadDeviceToken" });
  const handler = createHandler(() => ({ store, apns: refused, chain: fakeChain({}), markets: async () => markets, secret: "s3cret", sleep: async () => {} }));

  const rejected = await handler({ method: "POST", query: {}, body: subscribe() }, recorder());
  assert.equal(rejected.status, 400);
  assert.equal(await store.get(`alerts:sub:${subscriptionId(INSTALL)}`), null);
  assert.equal(await store.scard("alerts:subs"), 0);
});

test("a second sync while the first is still confirming waits for it instead of failing", async () => {
  const store = memoryStore();
  const id = subscriptionId(INSTALL);
  await store.set(`alerts:confirm:${id}`, "1", { ex: 60 });
  let naps = 0;
  const sleep = async () => {
    naps += 1;
    // The first request lands its subscription while the second waits.
    if (naps === 2) await store.set(`alerts:sub:${id}`, JSON.stringify({ traders: [] }));
  };
  const handler = createHandler(() => ({ store, apns: fakeAPNs(), chain: fakeChain({}), markets: async () => markets, secret: "s3cret", sleep }));
  const second = await handler({ method: "POST", query: {}, body: subscribe() }, recorder());
  assert.equal(second.status, 200);
  assert.equal(JSON.parse(await store.get(`alerts:sub:${id}`)).traders.length, 1);
});

test("a retry after Apple refused the confirmation says so, not that alerts are still being set up", async () => {
  const store = memoryStore();
  const handler = createHandler(() => ({ store, apns: fakeAPNs({ status: 400, reason: "BadDeviceToken" }), chain: fakeChain({}), markets: async () => markets, secret: "s3cret", sleep: async () => {} }));
  assert.equal((await handler({ method: "POST", query: {}, body: subscribe() }, recorder())).status, 400);
  const retry = await handler({ method: "POST", query: {}, body: subscribe() }, recorder());
  assert.equal(retry.status, 400);
  assert.match(retry.body.error, /couldn't be reached by Apple/);
});

test("the scan budget is shared between subscriptions, not taken first-come", () => {
  const flood = Array.from({ length: 30 }, (_, index) => `0x${String(index).padStart(40, "a")}`);
  const followers = new Map();
  for (const address of flood) followers.set(address, [{ id: "attacker", record: {} }]);
  followers.set(ALICE, [{ id: "victim", record: {} }]);

  const chosen = shareBudget(followers, 10);
  assert.equal(chosen.length, 10);
  assert.ok(chosen.includes(ALICE), "the second subscription's trader must still be scanned");
});

test("a dead token removes its subscription; a token of the other kind is remembered", async () => {
  const store = memoryStore();
  const id = subscriptionId(INSTALL);
  await store.set(`alerts:sub:${id}`, JSON.stringify(parseSubscription(subscribe()).record));
  await store.sadd("alerts:subs", id);
  await store.set(`alerts:snap2:${ALICE}`, JSON.stringify({ at: Date.now(), book: {} }));

  await scan({ store, chain: fakeChain({ row: row() }), apns: fakeAPNs({ status: 200, environment: "production" }), markets });
  assert.equal(JSON.parse(store.values.get(`alerts:sub:${id}`)).environment, "production");

  await store.set(`alerts:snap2:${ALICE}`, JSON.stringify({ at: Date.now(), book: {} }));
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
  assert.equal(res.body.rounds.length, 1);
  assert.ok(Date.parse(store.values.get("alerts:lastScan")) > 0);
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

test("a subscription may name the traders it copies, and a move on one wakes the app silently", async () => {
  const parsed = parseSubscription(subscribe({ traders: [], copying: [ALICE] }));
  assert.deepEqual(parsed.record.copying, [ALICE.toLowerCase()]);
  assert.ok(parseSubscription(subscribe({ copying: ["0x123"] })).error);

  const store = memoryStore();
  const apns = fakeAPNs();
  const state = { row: row() };
  const handler = createHandler(() => ({ store, apns, chain: fakeChain(state), markets: async () => markets, secret: "s3cret", sleep: async () => {} }));
  await handler({ method: "POST", query: {}, body: subscribe({ traders: [], copying: [ALICE] }) }, recorder());
  apns.sent.length = 0;
  await scan({ store, chain: fakeChain(state), apns, markets });
  state.row = row({ positionType: 1 });
  const second = await scan({ store, chain: fakeChain(state), apns, markets });
  assert.equal(second.sent, 1);
  assert.equal(apns.sent[0].payload.aps["content-available"], 1);
  assert.equal(apns.sent[0].payload.aps.alert, undefined);
  assert.equal(apns.sent[0].payload.desk.type, "wake");
  assert.equal(apns.sent[0].options.background, true);
  apns.sent.length = 0;
  state.row = row({ positionType: 1, lotLNS: BigInt(row().lotLNS) * 2n });
  const third = await scan({ store, chain: fakeChain(state), apns, markets });
  assert.equal(third.sent, 0);
  assert.equal(apns.sent.length, 0);
});

test("a phone is woken at most a dozen times an hour", async () => {
  const store = memoryStore();
  let allowed = 0;
  for (let i = 0; i < 15; i += 1) if (await withinWakeBudget(store, "sub", 1_000)) allowed += 1;
  assert.equal(allowed, WAKE_CAP);
  assert.equal(await withinWakeBudget(store, "sub", 1_000 + 3_600_000), true);
});

test("the waitlist takes an email once, refuses what is not one, and reads back to the scheduler", async () => {
  const store = memoryStore();
  const apns = fakeAPNs();
  const handler = createHandler(() => ({ store, apns, chain: {}, markets: async () => markets, secret: "s3cret", sleep: async () => {} }));
  const post = (email) => handler({ method: "POST", query: {}, headers: {}, body: { action: "waitlist", email } }, recorder());
  assert.equal((await post("Someone@Example.com")).status, 200);
  const again = await post("someone@example.com");
  assert.equal(again.status, 200);
  assert.equal(again.body.already, true);
  assert.equal((await post("not an email")).status, 400);
  const list = await handler({ method: "GET", query: { job: "waitlist" }, headers: { authorization: "Bearer s3cret" } }, recorder());
  assert.deepEqual(list.body.emails, ["someone@example.com"]);
  assert.equal((await handler({ method: "GET", query: { job: "waitlist" }, headers: {} }, recorder())).status, 401);
});

const BOB = "0xb0b0000000000000000000000000000000000b0b";
const ME = { address: BOB, networks: ["mainnet", "testnet"] };
const reverting = () => ({ async accountByAddress() { throw Object.assign(new Error("execution reverted"), { name: "ContractFunctionRevertedError" }); } });
const snapKey = `alerts:snap2:${ALICE}`;
const emptyBook = { async accountByAddress() { return { accountId: 3901n, positions: { bank1: 0n } }; }, async openPosition() { return null; } };

/// The real viem path: an RPC error comes back through readContract the way chainReader sees it.
function rpcChain(error) {
  const client = createPublicClient({ transport: custom({ async request() { throw error; } }, { retryCount: 0 }) });
  const abi = parseAbi(["function getAccountByAddr(address) view returns (uint256)"]);
  return { accountByAddress: (address) => client.readContract({ address: "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F", abi, functionName: "getAccountByAddr", args: [address] }) };
}

async function subscribed(store, overrides = {}) {
  const id = subscriptionId(INSTALL);
  await store.set(`alerts:sub:${id}`, JSON.stringify(parseSubscription(subscribe(overrides)).record));
  await store.sadd("alerts:subs", id);
  return id;
}

test("a subscription may name its own Desk wallet, and that alone keeps it alive", async () => {
  const parsed = parseSubscription(subscribe({ me: { address: BOB.replace("b0b0", "B0B0"), networks: ["testnet", "mainnet", "mainnet"] } }));
  assert.deepEqual(parsed.record.me, { address: BOB, networks: ["mainnet", "testnet"] });
  assert.equal(parseSubscription(subscribe()).record.me, null);
  assert.ok(parseSubscription(subscribe({ me: { address: "0x123", networks: ["mainnet"] } })).error);
  assert.ok(parseSubscription(subscribe({ me: { address: BOB, networks: ["devnet"] } })).error);
  assert.ok(parseSubscription(subscribe({ me: { address: BOB } })).error);
  assert.ok(parseSubscription(subscribe({ me: "me" })).error);

  const store = memoryStore();
  const apns = fakeAPNs();
  const handler = createHandler(() => ({ store, apns, chain: fakeChain({}), markets: async () => markets, secret: "x", sleep: async () => {} }));
  const meOnly = { traders: [], prices: false, me: { address: BOB, networks: ["mainnet", "testnet"] } };
  const on = await handler({ method: "POST", query: {}, body: subscribe(meOnly) }, recorder());
  assert.equal(on.status, 200);
  assert.equal(apns.sent[0].payload.aps.alert.title, "Deposit alerts are on");
  assert.equal(apns.sent[0].payload.aps.alert.body, "You'll hear when MON or AUSD lands in your Desk wallet.");
  assert.equal(await store.scard("alerts:subs"), 1);
  await handler({ method: "POST", query: {}, body: subscribe(meOnly) }, recorder());
  assert.equal(await store.scard("alerts:subs"), 1);
  await handler({ method: "POST", query: {}, body: subscribe({ traders: [], prices: false }) }, recorder());
  assert.equal(await store.scard("alerts:subs"), 0);
});

test("a trim reads as a sentence and carries the size it came from", () => {
  const position = { market: "BTC", marketId: 1, side: "long", size: "1", entry: "60000", value: "600", pnl: "0", leverage: 12 };
  const payload = alertPayload(ALICE, "Whale", { kind: "reduced", position, previous: { ...position, size: "2", value: "1200" } });
  assert.equal(payload.aps.alert.title, "Whale trimmed their BTC long");
  assert.equal(payload.aps.alert.body, "$1.2K → $600 at 12×.");
  assert.equal(payload.aps.category, "desk.trade.closed");
  assert.deepEqual([payload.desk.type, payload.desk.event, payload.desk.value, payload.desk.previousValue], ["trade", "reduced", "600", "1200"]);
});

test("more than four moves in one scan are three pushes and one summary", async () => {
  const at = (market, marketId) => ({ market, marketId, side: "long", size: "1", entry: "1", value: "1000", pnl: "0", leverage: 2 });
  const closes = ["BTC", "ETH", "SOL", "HYPE", "MON"].map((market, index) => ({ kind: "closed", position: at(market, index + 1) }));
  assert.equal(movesSentence([closes[1], closes[2], { kind: "opened", position: at("HYPE", 4) }]), "Closed ETH and SOL, opened HYPE.");
  assert.equal(movesSentence(closes), "Closed BTC, ETH, SOL, HYPE and more.");
  assert.equal(movesSentence([{ kind: "reduced", position: at("ETH", 2) }, { kind: "added", position: at("SOL", 3) }]), "Trimmed ETH, added to SOL.");

  const store = memoryStore();
  await subscribed(store, { moves: 2 });
  const now = Date.now();
  await store.set(snapKey, JSON.stringify({ at: now - 60_000, book: Object.fromEntries(closes.map(({ position }) => [position.marketId, position])) }));
  const apns = fakeAPNs();
  const report = await scan({ store, chain: emptyBook, apns, markets, now });
  assert.equal(report.sent, 4);
  assert.deepEqual(apns.sent.map((entry) => entry.payload.desk.event), ["closed", "closed", "closed", "summary"]);
  const summary = apns.sent[3];
  assert.equal(summary.payload.aps.alert.title, "Whale made 2 more moves");
  assert.equal(summary.payload.aps.alert.body, "Closed HYPE and MON.");
  assert.equal(summary.payload.aps.category, "desk.trade.closed");
  assert.deepEqual([summary.payload.desk.type, summary.payload.desk.trader, summary.payload.desk.count, summary.payload.desk.markets],
    ["trade", ALICE, 2, ["HYPE", "MON"]]);
  assert.equal(summaryPayload(ALICE, undefined, closes.slice(3)).aps.alert.title, "0x95d2…a648 made 2 more moves");
  assert.equal(JSON.parse(store.values.get(`alerts:moves:${ALICE}`)).length, 5);
});

test("a followed wallet with no Perpl account is an empty book, so its first position pushes an open", async () => {
  assert.equal(await readBook(reverting(), markets, ALICE), NO_ACCOUNT);
  const store = memoryStore();
  await subscribed(store);
  const apns = fakeAPNs();
  const baseline = await scan({ store, chain: reverting(), apns, markets });
  assert.equal(baseline.sent, 0);
  assert.deepEqual(JSON.parse(store.values.get(snapKey)).book, {});
  const opened = await scan({ store, chain: fakeChain({ row: row() }), apns, markets });
  assert.equal(opened.sent, 1);
  assert.equal(apns.sent[0].payload.aps.alert.title, "Whale opened a long");

  const held = store.values.get(snapKey);
  assert.equal((await scan({ store, chain: reverting(), apns, markets })).sent, 0);
  assert.equal(store.values.get(snapKey), held);

  const transient = memoryStore();
  await subscribed(transient);
  await scan({ store: transient, chain: fakeChain({ fail: true }), apns, markets });
  assert.equal(transient.values.has(snapKey), false);
});

test("a snapshot older than twenty minutes, or written before snapshots had a time, is a fresh baseline", async () => {
  const store = memoryStore();
  await subscribed(store);
  const now = Date.now();
  const apns = fakeAPNs();
  const chain = fakeChain({ row: row() });
  await store.set(snapKey, JSON.stringify({ at: now - 21 * 60_000, book: {} }));
  assert.equal((await scan({ store, chain, apns, markets, now })).sent, 0);
  assert.equal(JSON.parse(store.values.get(snapKey)).at, now);
  await store.set(snapKey, JSON.stringify({}));
  assert.equal((await scan({ store, chain, apns, markets, now })).sent, 0);
  await store.set(snapKey, JSON.stringify({ at: now - 19 * 60_000, book: {} }));
  assert.equal((await scan({ store, chain, apns, markets, now })).sent, 1);
});

test("an unchanged book is rewritten only every five minutes", async () => {
  const store = memoryStore();
  await subscribed(store);
  const now = Date.now();
  const chain = fakeChain({ row: row() });
  await scan({ store, chain, apns: fakeAPNs(), markets, now });
  await scan({ store, chain, apns: fakeAPNs(), markets, now: now + 60_000 });
  assert.equal(JSON.parse(store.values.get(snapKey)).at, now);
  await scan({ store, chain, apns: fakeAPNs(), markets, now: now + 5 * 60_000 });
  assert.equal(JSON.parse(store.values.get(snapKey)).at, now + 5 * 60_000);
});

test("a Redis failure in wallet deliveries still sends the trader's push, and the snapshot is already written", async () => {
  const store = memoryStore();
  await subscribed(store, { wallets: [{ address: BOB }] });
  await store.set(snapKey, JSON.stringify({ at: Date.now(), book: {} }));
  const mget = store.mget;
  store.mget = async (keys) => {
    if (keys.some((key) => key.startsWith("wl:"))) throw new Error("redis 500");
    return mget(keys);
  };
  const apns = fakeAPNs();
  const report = await scan({ store, chain: fakeChain({ row: row() }), apns, markets });
  assert.equal(apns.sent.length, 1);
  assert.equal(apns.sent[0].payload.aps.alert.title, "Whale opened a long");
  assert.deepEqual(report.errors, ["wallets: redis 500"]);
  assert.ok(JSON.parse(store.values.get(snapKey)).book[20]);
});

test("a scan cut off after sending does not send the same pushes again", async () => {
  const store = memoryStore();
  await subscribed(store);
  await store.set(snapKey, JSON.stringify({ at: Date.now(), book: {} }));
  const chain = fakeChain({ row: row() });
  const sent = [];
  const cutOff = { async send(record, payload) { sent.push(payload); throw new Error("function timed out"); }, close() {} };
  await assert.rejects(scan({ store, chain, apns: cutOff, markets }));
  assert.deepEqual(sent.map((payload) => payload.desk.event), ["opened"]);
  assert.ok(JSON.parse(store.values.get(snapKey)).book[20]);
  assert.equal(JSON.parse(store.values.get(`alerts:moves:${ALICE}`)).length, 1);
  const apns = fakeAPNs();
  assert.equal((await scan({ store, chain, apns, markets })).sent, 0);
  assert.equal(apns.sent.length, 0);
  assert.equal(JSON.parse(store.values.get(`alerts:moves:${ALICE}`)).length, 1);
});

test("a scan that fails before its snapshot write finds the same move next time", async () => {
  const store = memoryStore();
  await subscribed(store);
  await store.set(snapKey, JSON.stringify({ at: Date.now(), book: {} }));
  const chain = fakeChain({ row: row() });
  const setMany = store.setMany;
  store.setMany = async () => { throw new Error("redis pipeline"); };
  const apns = fakeAPNs();
  await assert.rejects(scan({ store, chain, apns, markets }));
  assert.equal(apns.sent.length, 0);
  assert.deepEqual(JSON.parse(store.values.get(snapKey)).book, {});
  store.setMany = setMany;
  assert.equal((await scan({ store, chain, apns, markets })).sent, 1);
  assert.equal(apns.sent[0].payload.desk.event, "opened");
});

test("each move is kept for the following feed, newest first, twenty at most", async () => {
  const store = memoryStore();
  await subscribed(store);
  const now = Date.now();
  const old = Array.from({ length: 20 }, (_, index) => ({ wallet: ALICE, venue: "perpl", time: now - (index + 1) * 60_000, kind: "closed", market: "ETH" }));
  await store.set(`alerts:moves:${ALICE}`, JSON.stringify(old));
  await store.set(snapKey, JSON.stringify({ at: now - 60_000, book: {} }));
  await scan({ store, chain: fakeChain({ row: row() }), apns: fakeAPNs(), markets, now });
  const rows = JSON.parse(store.values.get(`alerts:moves:${ALICE}`));
  assert.equal(rows.length, 20);
  assert.deepEqual(rows[0], {
    wallet: ALICE, venue: "perpl", time: now, kind: "opened", market: "ETH", marketId: 20, side: "long",
    leverage: 4, entry: "1847.99", value: rows[0].value, previousValue: null,
  });
  assert.equal(rows[1].time, now - 60_000);
});

test("a build that does not send moves: 2 gets no trims and no summary, only the first four other moves", async () => {
  const parsed = (moves) => parseSubscription(subscribe({ moves })).record.moves;
  assert.deepEqual([parsed(2), parsed(undefined), parsed("2"), parsed(2.5), parsed(-1)], [2, 0, 0, 0, 0]);
  const at = (market, marketId, size = "1") => ({ market, marketId, side: "long", size, entry: "1", value: "1000", pnl: "0", leverage: 2 });
  const book = Object.fromEntries(["BTC", "ETH", "SOL", "HYPE", "MON"].map((market, index) => [index + 1, at(market, index + 1)]));
  book[6] = at("DOGE", 6, "4");
  const now = Date.now();
  const trimmed = {
    async accountByAddress() { return { accountId: 3901n, positions: { bank1: 1n << 6n } }; },
    async openPosition() { return { row: row({ lotLNS: 1n }), mark: 244_722n }; },
  };
  const run = async (overrides) => {
    const store = memoryStore();
    await subscribed(store, overrides);
    await store.set(snapKey, JSON.stringify({ at: now - 60_000, book }));
    const apns = fakeAPNs();
    const report = await scan({ store, chain: trimmed, apns, markets: new Map([[6, { ...ETH, id: 6, name: "DOGE" }]]), now });
    return { store, report, events: apns.sent.map((entry) => entry.payload.desk.event) };
  };

  const older = await run({ me: ME });
  assert.equal(older.report.sent, 4);
  assert.deepEqual(older.events, ["closed", "closed", "closed", "closed"]);
  assert.equal(JSON.parse(older.store.values.get(`alerts:moves:${ALICE}`)).filter((entry) => entry.kind === "reduced").length, 1);

  assert.deepEqual((await run({ moves: 2 })).events, ["closed", "closed", "closed", "summary"]);
});

test("copyable moves go out first, closes next and trims last, so the summary holds the trims", async () => {
  const at = (market, marketId, size = "1") => ({ market, marketId, side: "long", size, entry: "1", value: "1000", pnl: "0", leverage: 2 });
  const now = Date.now();
  const store = memoryStore();
  await subscribed(store, { moves: 2 });
  await store.set(snapKey, JSON.stringify({ at: now - 60_000, book: {
    1: at("BTC", 1), 2: at("ETH", 2), 3: at("SOL", 3), 4: at("HYPE", 4, "4"), 5: at("MON", 5, "4"),
  } }));
  const chain = {
    async accountByAddress() { return { accountId: 3901n, positions: { bank1: (1n << 4n) | (1n << 5n) | (1n << 6n) } }; },
    async openPosition() { return { row: row({ lotLNS: 1n }), mark: 244_722n }; },
  };
  const named = new Map(["HYPE", "MON", "DOGE"].map((name, index) => [index + 4, { ...ETH, id: index + 4, name }]));
  const apns = fakeAPNs();
  await scan({ store, chain, apns, markets: named, now });
  assert.deepEqual(apns.sent.map((entry) => [entry.payload.desk.event, entry.payload.desk.market]),
    [["opened", "DOGE"], ["closed", "BTC"], ["closed", "ETH"], ["summary", undefined]]);
  assert.equal(apns.sent[3].payload.aps.alert.body, "Closed SOL, trimmed HYPE and MON.");
});

test("a book with positions survives reverting reads past twenty minutes, so the next good read opens nothing", async () => {
  const store = memoryStore();
  await subscribed(store, { moves: 2 });
  const start = Date.now();
  const apns = fakeAPNs();
  const chain = fakeChain({ row: row() });
  await scan({ store, chain, apns, markets, now: start });
  const held = store.values.get(snapKey);
  for (let minute = 1; minute <= 25; minute += 1) await scan({ store, chain: reverting(), apns, markets, now: start + minute * 60_000 });
  assert.equal(store.values.get(snapKey), held);
  assert.equal((await scan({ store, chain, apns, markets, now: start + 26 * 60_000 })).sent, 0);
  assert.equal((await scan({ store, chain, apns, markets, now: start + 27 * 60_000 })).sent, 0);
  assert.equal(apns.sent.length, 0);
  assert.equal(JSON.parse(store.values.get(snapKey)).at, start + 26 * 60_000);
});

test("snapshots live under a key the previous deployment never reads, and its old keys are left to expire", async () => {
  const store = memoryStore();
  await subscribed(store);
  const old = JSON.stringify({ at: Date.now(), book: {} });
  await store.set(`alerts:snap:${ALICE}`, old);
  assert.equal((await scan({ store, chain: fakeChain({ row: row() }), apns: fakeAPNs(), markets })).sent, 0);
  assert.ok(JSON.parse(store.values.get(snapKey)).book[20]);
  assert.equal(store.values.get(`alerts:snap:${ALICE}`), old);
});

test("only a real revert is a missing account; an internal RPC error is a failed read", async () => {
  const revert = rpcChain({ code: 3, message: "execution reverted", data: "0x03a0e277" });
  assert.equal(await readBook(revert, markets, ALICE), NO_ACCOUNT);
  assert.equal(await readBook(rpcChain({ code: -32603, message: "execution reverted" }), markets, ALICE), NO_ACCOUNT);
  const internal = rpcChain({ code: -32603, message: "internal error" });
  const error = await internal.accountByAddress(ALICE).catch((caught) => caught);
  assert.equal(noAccount(error), false);
  await assert.rejects(readBook(internal, markets, ALICE));
  assert.equal(noAccount(new Error("fetch failed")), false);

  const store = memoryStore();
  await subscribed(store);
  await store.set(snapKey, JSON.stringify({ at: Date.now(), book: { 20: { market: "ETH", marketId: 20, side: "long", size: "5", value: "1" } } }));
  const held = store.values.get(snapKey);
  const apns = fakeAPNs();
  assert.equal((await scan({ store, chain: internal, apns, markets })).sent, 0);
  assert.equal(store.values.get(snapKey), held);
  assert.equal(store.values.has(`alerts:moves:${ALICE}`), false);

  const unknown = memoryStore();
  await subscribed(unknown);
  await scan({ store: unknown, chain: internal, apns, markets });
  assert.equal(unknown.values.has(snapKey), false);
});

test("an install that already had a subscription hears again only when deposit alerts are newly on", async () => {
  const store = memoryStore();
  const apns = fakeAPNs();
  const handler = createHandler(() => ({ store, apns, chain: fakeChain({}), markets: async () => markets, secret: "x", sleep: async () => {} }));
  const post = async (body) => {
    await store.del(`alerts:confirm:${subscriptionId(INSTALL)}`);
    return handler({ method: "POST", query: {}, body: subscribe(body) }, recorder());
  };
  await post({ confirm: true });
  assert.deepEqual(apns.sent.map((entry) => entry.payload.aps.alert.title), ["Trade alerts are on"]);
  await post({ confirm: true, traders: [ALICE, BOB] });
  assert.equal(apns.sent.length, 1);

  const on = await post({ confirm: true, me: ME });
  assert.equal(on.body.confirmed, true);
  assert.deepEqual(apns.sent[1].payload.aps.alert, { title: "Deposit alerts are on", body: "You'll hear when MON or AUSD lands in your Desk wallet." });
  await post({ confirm: true, me: ME });
  await post({ confirm: true, me: ME, traders: [] });
  assert.equal(apns.sent.length, 2);

  await post({ confirm: true });
  await post({ me: ME });
  assert.equal(apns.sent.length, 3);
  assert.equal(apns.sent[2].payload.aps.alert.title, "Deposit alerts are on");
});
