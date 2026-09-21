// node --test web/test/v1.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { createHealth, gradeAge, overall } from "../api/_health.mjs";
import { TIERS, clientIp, rateLimit } from "../api/_ratelimit.mjs";
import { memoryStore } from "../api/_store.mjs";
import { createHandler as relayHandler } from "../api/relay-quote.mjs";
import { ENDPOINTS, createHandler, routeOf } from "../api/v1.mjs";

const ALICE = "0x95d2602d30da1179fd13274839e60345857ca648";
const T = Date.UTC(2026, 8, 21, 12, 0, 30);

function recorder() {
  const out = { status: 200, body: null, headers: {} };
  const res = {
    status(code) { out.status = code; return this; },
    end(value) { out.body = value == null ? null : JSON.parse(value); return out; },
    json(value) { out.body = value; return out; },
    setHeader(key, value) { out.headers[key] = value; },
  };
  return { out, res };
}

async function call(handler, path, { method = "GET", query = {}, headers = {} } = {}) {
  const { out, res } = recorder();
  await handler({ method, url: `/api/v1?path=${path}`, query: { path, ...query }, headers }, res);
  return out;
}

const traders = async (req, res) => {
  const { view } = req.query;
  if (view === "top") return res.status(200).json({ observedAt: 1, traders: [{ address: "a" }, { address: "b" }, { address: "c" }] });
  if (view === "identity") return res.status(200).json({ identities: { [ALICE]: { address: ALICE, name: "alice.nad" } } });
  if (view === "history") return res.status(200).json({ address: req.query.address, stats: null, trades: [] });
  if (view === "signals") return res.status(200).json({ window: req.query.window, signals: [] });
  return res.status(502).json({ error: "Perpl mainnet could not be read right now." });
};
const activity = async (req, res) => res.status(200).json({ address: req.query.address, holdings: [], ledger: { status: "ready" } });

const api = (overrides = {}) => createHandler({ store: memoryStore(), traders, activity, now: () => T, ...overrides });

test("the index names the API, its routes and limits, with CORS and an envelope", async () => {
  const out = await call(api(), "");
  assert.equal(out.status, 200);
  assert.equal(out.body.data.name, "Desk API");
  assert.equal(out.body.data.version, "1");
  assert.deepEqual(out.body.data.endpoints, ENDPOINTS);
  assert.deepEqual(out.body.meta, { asOf: new Date(T).toISOString(), chain: "monad", cached: false });
  assert.equal(out.headers["Access-Control-Allow-Origin"], "*");
  assert.equal(out.headers["Access-Control-Allow-Methods"], "GET, HEAD, OPTIONS");
  assert.equal(out.headers["Access-Control-Max-Age"], "86400");
  assert.equal(out.headers["Content-Type"], "application/json; charset=utf-8");
  assert.equal(out.headers["X-RateLimit-Limit"], "60");

  const options = await call(api(), "traders/top", { method: "OPTIONS" });
  assert.equal(options.status, 204);
  assert.equal(options.headers["Access-Control-Allow-Origin"], "*");
  const post = await call(api(), "traders/top", { method: "POST" });
  assert.equal(post.status, 405);
  assert.equal(post.body.code, "method_not_allowed");
});

test("routes come from the rewrite's path query or the raw URL", () => {
  assert.deepEqual(routeOf({ url: "/api/v1?path=traders/top&limit=5", query: { path: "traders/top", limit: "5" } }),
    { segments: ["traders", "top"], query: { limit: "5" }, instance: "/api/v1/traders/top" });
  assert.deepEqual(routeOf({ url: `/api/v1/wallets/${ALICE}?x=1` }).segments, ["wallets", ALICE]);
  assert.equal(routeOf({ url: "/api/v1" }).instance, "/api/v1");
});

test("a malformed address is a 400 problem, and an unknown path a 404 problem", async () => {
  const bad = await call(api(), "identity/0x1234");
  assert.equal(bad.status, 400);
  assert.equal(bad.headers["Content-Type"], "application/problem+json");
  assert.equal(bad.headers["Cache-Control"], "no-store");
  assert.equal(bad.body.code, "invalid_address");
  assert.equal(bad.body.status, 400);
  assert.equal(bad.body.instance, "/api/v1/identity/0x1234");
  assert.match(bad.body.type, /#error-invalid_address$/);
  assert.ok(bad.body.title && bad.body.detail);

  const missing = await call(api(), "nothing/here");
  assert.equal(missing.status, 404);
  assert.equal(missing.body.code, "unknown_route");
  const seed = await call(api(), `wallets/${ALICE}/extra`);
  assert.equal(seed.body.code, "unknown_route");
});

test("each route wraps the handler it delegates to and sets its own cache policy", async () => {
  const top = await call(api(), "traders/top", { query: { limit: "2" } });
  assert.equal(top.body.data.traders.length, 2);
  assert.equal(top.headers["Cache-Control"], "public, s-maxage=30, stale-while-revalidate=300");

  const identity = await call(api(), `identity/${ALICE.toUpperCase().replace("0X", "0x")}`);
  assert.equal(identity.body.data.name, "alice.nad");
  assert.equal(identity.headers["Cache-Control"], "public, s-maxage=60, stale-while-revalidate=600");

  const history = await call(api(), `traders/${ALICE}/history`);
  assert.equal(history.body.data.address, ALICE);
  assert.equal(history.headers["X-RateLimit-Limit"], "10");

  const wallet = await call(api(), `wallets/${ALICE}`);
  assert.equal(wallet.body.data.ledger.status, "ready");
  assert.equal(wallet.headers["X-RateLimit-Limit"], "10");

  const signals = await call(api(), "tokens/signals", { query: { window: "1h" } });
  assert.equal(signals.body.data.window, "1h");
  assert.equal(signals.headers["Cache-Control"], "public, s-maxage=15, stale-while-revalidate=120");
  assert.equal((await call(api(), "tokens/signals")).body.data.window, "6h");
  const badWindow = await call(api(), "tokens/signals", { query: { window: "7d" } });
  assert.equal(badWindow.body.code, "invalid_request");

  const down = await call(api({ traders: async (req, res) => res.status(502).json({ error: "Perpl is down." }) }), "traders/top");
  assert.equal(down.status, 503);
  assert.equal(down.body.code, "upstream_unavailable");
  assert.equal(down.body.detail, "Perpl is down.");

  const head = await call(api(), "traders/top", { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(head.body, null);
});

test("stats are counters only: requests per day, tracked wallets, alert subscriptions", async () => {
  const store = memoryStore();
  await store.sadd("wl:tracked", ALICE);
  await store.sadd("alerts:subs", "sub1");
  await store.sadd("alerts:subs", "sub2");
  const handler = api({ store });
  await call(handler, "traders/top");
  await call(handler, "");
  // The stats request is the third one counted.
  const stats = await call(handler, "stats");
  assert.deepEqual(stats.body.data, { day: "2026-09-21", requestsToday: 3, trackedWallets: 1, alertSubscriptions: 2 });
  assert.equal(JSON.stringify(stats.body).includes(ALICE), false);
});

test("the limiter weighs the previous window by how much of it still overlaps", async () => {
  assert.equal(clientIp({ "x-forwarded-for": "203.0.113.9, 10.0.0.1" }), "203.0.113.9");
  assert.equal(clientIp({ "x-real-ip": "203.0.113.7" }), "203.0.113.7");
  assert.equal(clientIp({}), "unknown");

  const store = memoryStore();
  const ip = "203.0.113.9";
  const seconds = Math.floor(T / 1000);
  const start = seconds - (seconds % 60);
  await store.set(`rl:default:${ip}:${start - 60}`, "40");
  let last;
  for (let i = 0; i < 40; i += 1) last = await rateLimit({ store, ip, now: T });
  // Halfway through the window, 40 of the previous bucket count as 20: 20 + 40 = 60, the limit.
  assert.equal(last.allowed, true);
  assert.equal(last.remaining, 0);
  assert.equal(last.headers["X-RateLimit-Reset"], String(start + 60));
  const over = await rateLimit({ store, ip, now: T });
  assert.equal(over.allowed, false);
  assert.equal(over.retryAfter, 30);
  assert.equal(over.headers["X-RateLimit-Remaining"], "0");

  const expensive = await rateLimit({ store, tier: "expensive", ip, now: T });
  assert.equal(expensive.limit, TIERS.expensive.limit);
  assert.equal(expensive.remaining, 9);

  const unlimited = await rateLimit({ store: null, ip, now: T });
  assert.equal(unlimited.allowed, true);
  assert.equal(unlimited.headers["X-RateLimit-Remaining"], "60");
});

test("over the limit, the API answers 429 with Retry-After and a problem body", async () => {
  const store = memoryStore();
  const handler = api({ store });
  const headers = { "x-forwarded-for": "198.51.100.4" };
  for (let i = 0; i < 10; i += 1) await call(handler, `wallets/${ALICE}`, { headers });
  const blocked = await call(handler, `wallets/${ALICE}`, { headers });
  assert.equal(blocked.status, 429);
  assert.equal(blocked.headers["Retry-After"], "30");
  assert.equal(blocked.headers["X-RateLimit-Remaining"], "0");
  assert.equal(blocked.headers["Content-Type"], "application/problem+json");
  assert.equal(blocked.body.code, "rate_limited");
  // A different address on the default tier is still served.
  const ok = await call(handler, "traders/top", { headers });
  assert.equal(ok.status, 200);
});

const probes = (overrides = {}) => ({
  redis: async () => {},
  rpc: async () => 12_345,
  perpl: async () => 200,
  heartbeat: async () => ({ at: T - 60_000, wallets: 3, indexed: 2, behind: 0 }),
  lastScan: async () => new Date(T - 5 * 60_000).toISOString(),
  ...overrides,
});

test("health grades ages and rolls checks up: critical failures fail, the rest warn", async () => {
  assert.equal(gradeAge(null, { warn: 1, fail: 2 }), "unknown");
  assert.equal(gradeAge(5 * 60, { warn: 4 * 60, fail: 10 * 60 }), "warn");
  assert.equal(overall({ a: [{ status: "fail" }], b: [{ status: "pass" }] }, ["b"]), "warn");

  const { report, cached } = await createHealth({ store: null, probes: probes(), now: () => T, releaseId: "abc1234" })();
  assert.equal(cached, false);
  assert.equal(report.status, "pass");
  assert.equal(report.releaseId, "abc1234");
  assert.deepEqual(Object.keys(report.checks), ["redis:responseTime", "monad-rpc:responseTime", "perpl:responseTime", "worker:heartbeatAge", "cron:lastRunAge"]);
  assert.equal(report.checks["monad-rpc:responseTime"][0].block, 12_345);
  assert.equal(report.checks["monad-rpc:responseTime"][0].observedUnit, "ms");
  assert.equal(report.checks["worker:heartbeatAge"][0].observedValue, 60);
  assert.equal(report.checks["cron:lastRunAge"][0].observedValue, 300);

  const rpcDown = (await createHealth({ store: null, probes: probes({ rpc: async () => { throw new Error("socket"); } }), now: () => T })()).report;
  assert.equal(rpcDown.status, "warn");
  assert.equal(rpcDown.checks["monad-rpc:responseTime"][0].status, "warn");

  const redisDown = (await createHealth({ store: null, probes: probes({ redis: async () => { throw new Error("redis 500"); } }), now: () => T })()).report;
  assert.equal(redisDown.status, "fail");

  const stale = (await createHealth({ store: null, probes: probes({ heartbeat: async () => ({ at: T - 5 * 60_000 }) }), now: () => T })()).report;
  assert.equal(stale.checks["worker:heartbeatAge"][0].status, "warn");
  const dead = (await createHealth({ store: null, probes: probes({ heartbeat: async () => ({ at: T - 11 * 60_000 }) }), now: () => T })()).report;
  assert.equal(dead.status, "fail");
  const never = (await createHealth({ store: null, probes: probes({ lastScan: async () => null }), now: () => T })()).report;
  assert.equal(never.checks["cron:lastRunAge"][0].status, "unknown");
  assert.equal(never.status, "pass");

  const slow = (await createHealth({ store: null, probes: probes({ perpl: () => new Promise(() => {}) }), now: () => T, timeoutMs: 10 })()).report;
  assert.equal(slow.checks["perpl:responseTime"][0].status, "warn");
});

test("health is memoised for ten seconds and served as health+json, 503 on fail", async () => {
  const store = memoryStore();
  let calls = 0;
  const run = createHealth({ store, probes: probes({ redis: async () => { calls += 1; } }), now: () => T });
  assert.equal((await run()).cached, false);
  assert.equal((await run()).cached, true);
  assert.equal(calls, 1);

  const ok = await call(api({ health: run }), "health");
  assert.equal(ok.status, 200);
  assert.equal(ok.headers["Content-Type"], "application/health+json; charset=utf-8");
  assert.equal(ok.headers["Cache-Control"], "no-store");
  assert.equal(ok.body.status, "pass");

  const failing = api({ health: async () => ({ report: { status: "fail", version: "1", checks: {} }, cached: false }) });
  const down = await call(failing, "health");
  assert.equal(down.status, 503);
  const head = await call(failing, "health", { method: "HEAD" });
  assert.equal(head.status, 503);
  assert.equal(head.body, null);
});

test("relay status lives inside relay-quote and still answers on the old path", async () => {
  const fetchImpl = async () => ({ ok: true, status: 200, json: async () => ({ status: "refund", txHashes: [] }) });
  const handler = relayHandler(fetchImpl);
  const requestId = `0x${"ab".repeat(32)}`;
  for (const req of [
    { method: "GET", query: { view: "status", requestId } },
    { method: "GET", url: `/api/relay-status?requestId=${requestId}`, query: { requestId } },
  ]) {
    const { out, res } = recorder();
    await handler(req, res);
    assert.deepEqual(out.body, { phase: "refunded", destinationTx: null });
  }
  const { out, res } = recorder();
  await handler({ method: "GET", url: "/api/relay-quote?user=0x12", query: { user: "0x12" } }, res);
  assert.equal(out.status, 400);
  assert.equal(out.body.reason, "invalid");
});
