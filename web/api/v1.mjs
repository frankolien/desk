import { createHealth } from "./_health.mjs";
import { TIERS, clientIp, rateLimit } from "./_ratelimit.mjs";
import { redisStore } from "./_store.mjs";
import { createHandler as activityHandler } from "./activity.mjs";
import { createHandler as tradersHandler } from "./traders.mjs";

const DOCS = "https://trydesk.trade/docs";
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const WINDOWS = new Set(["1h", "6h", "24h"]);
const TOP_LIMIT = 25;

const CACHE = {
  top: "public, s-maxage=30, stale-while-revalidate=300",
  slow: "public, s-maxage=60, stale-while-revalidate=600",
  signals: "public, s-maxage=15, stale-while-revalidate=120",
  none: "no-store",
};

const PROBLEMS = {
  invalid_address: [400, "Invalid address"],
  invalid_request: [400, "Invalid request"],
  not_found: [404, "Not found"],
  method_not_allowed: [405, "Method not allowed"],
  rate_limited: [429, "Too many requests"],
  upstream_unavailable: [503, "Upstream unavailable"],
  unknown_route: [404, "Unknown route"],
};

export const ENDPOINTS = [
  { path: "/api/v1/traders/top", tier: "default", description: "Top traders on Perpl by unrealised PnL. ?limit=1..25" },
  { path: "/api/v1/traders/{address}/history", tier: "expensive", description: "A trader's closed trades and statistics" },
  { path: "/api/v1/identity/{address}", tier: "default", description: "Names and avatars for an address (.nad, nad.fun, ENS, Farcaster)" },
  { path: "/api/v1/wallets/{address}", tier: "expensive", description: "What a wallet holds and did on Monad" },
  { path: "/api/v1/tokens/signals", tier: "default", description: "Token signals over a window. ?window=1h|6h|24h" },
  { path: "/api/v1/health", tier: "default", description: "Service health (health+json)" },
  { path: "/api/v1/stats", tier: "default", description: "Usage counters, no addresses" },
];

export function problem(code, detail, instance, extra = {}) {
  const [status, title] = PROBLEMS[code] ?? [500, "Error"];
  return { status, body: { type: `${DOCS}#error-${code}`, title, status, detail, instance, code, ...extra } };
}

/// The path after /api/v1, from the rewrite's `path` query or the raw URL.
export function routeOf(req) {
  const url = new URL(String(req.url ?? "/"), "http://desk");
  const query = req.query ?? Object.fromEntries(url.searchParams);
  let path = query.path;
  if (path == null) path = url.pathname.replace(/^\/api\/v1\/?/, "");
  const segments = String(path).split("/").filter(Boolean);
  const { path: _omit, ...rest } = query;
  return { segments, query: rest, instance: `/api/v1${segments.length ? `/${segments.join("/")}` : ""}` };
}

async function capture(handler, query) {
  const out = { status: 200, body: null, headers: {} };
  const res = {
    status(code) { out.status = code; return this; },
    json(value) { out.body = value; return out; },
    end(value) { if (value) out.body = value; return out; },
    setHeader(key, value) { out.headers[String(key).toLowerCase()] = value; },
  };
  await handler({ method: "GET", query, headers: {}, url: "" }, res);
  return out;
}

function relay(out, instance) {
  if (out.status < 400) return { ok: true, data: out.body };
  const detail = out.body?.error ?? "The upstream request failed.";
  if (out.status === 400) return { ok: false, ...problem("invalid_request", detail, instance) };
  if (out.status === 404) return { ok: false, ...problem("not_found", detail, instance) };
  if (out.status === 429) return { ok: false, ...problem("rate_limited", detail, instance) };
  return { ok: false, ...problem("upstream_unavailable", detail, instance) };
}

export function createHandler({
  store = redisStore(),
  traders = null,
  activity = null,
  health = null,
  now = Date.now,
} = {}) {
  const deps = { traders, activity, health };
  const get = (name, make) => (deps[name] ??= make());

  return async function handler(req, res) {
    const method = String(req.method ?? "GET").toUpperCase();
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
    res.setHeader("Access-Control-Max-Age", "86400");
    res.setHeader("Access-Control-Expose-Headers", "X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset, Retry-After");
    if (method === "OPTIONS") return res.status(204).end();

    const { segments, query, instance } = routeOf(req);
    const send = (status, body, cacheControl, type = "application/json; charset=utf-8") => {
      res.setHeader("Cache-Control", cacheControl);
      res.setHeader("Content-Type", type);
      return res.status(status).end(method === "HEAD" ? undefined : JSON.stringify(body));
    };
    const fail = ({ status, body }, extra = {}) => {
      Object.entries(extra).forEach(([key, value]) => res.setHeader(key, value));
      return send(status, body, CACHE.none, "application/problem+json");
    };
    const envelope = (status, data, cacheControl, cached = false) =>
      send(status, { data, meta: { asOf: new Date(now()).toISOString(), chain: "monad", cached } }, cacheControl);

    const route = match(segments);
    const limit = await rateLimit({ store, tier: route?.tier ?? "default", ip: clientIp(req.headers ?? {}), now: now() });
    Object.entries(limit.headers).forEach(([key, value]) => res.setHeader(key, value));
    if (!limit.allowed) {
      return fail(problem("rate_limited", `Limit is ${limit.limit} requests per minute for this route. Try again in ${limit.retryAfter}s.`, instance),
        { "Retry-After": String(limit.retryAfter) });
    }
    if (method !== "GET" && method !== "HEAD") return fail(problem("method_not_allowed", "Only GET, HEAD and OPTIONS are served.", instance));
    if (!route) return fail(problem("unknown_route", `No route for ${instance}. See ${DOCS}.`, instance));
    if (route.address && !ADDRESS.test(route.address)) {
      return fail(problem("invalid_address", "Addresses are 0x followed by 40 hex characters.", instance));
    }
    if (store) count(store, now()).catch(() => {});

    switch (route.name) {
      case "index":
        return envelope(200, {
          name: "Desk API", version: "1", docs: DOCS, openapi: "https://trydesk.trade/openapi.json", health: "/api/v1/health",
          rateLimits: Object.fromEntries(Object.entries(TIERS).map(([tier, { limit: perMinute }]) => [tier, `${perMinute}/min`])),
          endpoints: ENDPOINTS,
        }, CACHE.slow);
      case "health": {
        const run = get("health", () => createHealth({ store, now }));
        let result;
        try {
          result = await run();
        } catch (error) {
          return fail(problem("upstream_unavailable", `Health could not be read: ${error.message}`, instance));
        }
        res.setHeader("Cache-Control", CACHE.none);
        res.setHeader("Content-Type", "application/health+json; charset=utf-8");
        return res.status(result.report.status === "fail" ? 503 : 200).end(method === "HEAD" ? undefined : JSON.stringify(result.report));
      }
      case "stats": {
        if (!store) return fail(problem("upstream_unavailable", "Counters are not configured on this server.", instance));
        const day = new Date(now()).toISOString().slice(0, 10);
        const [requests, tracked, subs] = await Promise.all([
          store.get(`v1:requests:${day}`).catch(() => null),
          store.scard("wl:tracked").catch(() => null),
          store.scard("alerts:subs").catch(() => null),
        ]);
        return envelope(200, { day, requestsToday: Number(requests ?? 0), trackedWallets: tracked ?? 0, alertSubscriptions: subs ?? 0 }, CACHE.top);
      }
      case "top": {
        const wanted = Math.min(TOP_LIMIT, Math.max(1, Number.parseInt(String(query.limit ?? TOP_LIMIT), 10) || TOP_LIMIT));
        const out = relay(await capture(get("traders", () => tradersHandler({ store })), { view: "top" }), instance);
        if (!out.ok) return fail(out);
        return envelope(200, { ...out.data, traders: (out.data.traders ?? []).slice(0, wanted) }, CACHE.top);
      }
      case "history": {
        const out = relay(await capture(get("traders", () => tradersHandler({ store })), { view: "history", address: route.address }), instance);
        return out.ok ? envelope(200, out.data, CACHE.slow) : fail(out);
      }
      case "identity": {
        const out = relay(await capture(get("traders", () => tradersHandler({ store })), { view: "identity", address: route.address }), instance);
        if (!out.ok) return fail(out);
        const identity = out.data.identities?.[route.address.toLowerCase()] ?? out.data.identities?.[route.address] ?? null;
        return identity ? envelope(200, identity, CACHE.slow) : fail(problem("not_found", "Nothing is known about this address.", instance));
      }
      case "wallet": {
        const out = relay(await capture(get("activity", () => activityHandler(fetch, () => process.env.ETHERSCAN_API_KEY, { store })), { view: "wallet", address: route.address }), instance);
        return out.ok ? envelope(200, out.data, CACHE.slow) : fail(out);
      }
      case "signals": {
        const window = String(query.window ?? "6h");
        if (!WINDOWS.has(window)) return fail(problem("invalid_request", "window must be one of 1h, 6h, 24h.", instance));
        const out = relay(await capture(get("traders", () => tradersHandler({ store })), { view: "signals", window }), instance);
        return out.ok ? envelope(200, out.data, CACHE.signals) : fail(out);
      }
      default:
        return fail(problem("unknown_route", `No route for ${instance}.`, instance));
    }
  };
}

function match(segments) {
  const [a, b, c] = segments;
  if (segments.length === 0) return { name: "index", tier: "default" };
  if (segments.length === 1 && a === "health") return { name: "health", tier: "default" };
  if (segments.length === 1 && a === "stats") return { name: "stats", tier: "default" };
  if (segments.length === 2 && a === "traders" && b === "top") return { name: "top", tier: "default" };
  if (segments.length === 3 && a === "traders" && c === "history") return { name: "history", tier: "expensive", address: b };
  if (segments.length === 2 && a === "identity") return { name: "identity", tier: "default", address: b };
  if (segments.length === 2 && a === "wallets") return { name: "wallet", tier: "expensive", address: b };
  if (segments.length === 2 && a === "tokens" && b === "signals") return { name: "signals", tier: "default" };
  return null;
}

async function count(store, now) {
  const key = `v1:requests:${new Date(now).toISOString().slice(0, 10)}`;
  if (await store.incr(key) === 1) await store.expire(key, 400 * 86400);
}

let defaultHandler;
export default function handler(req, res) {
  defaultHandler ??= createHandler();
  return defaultHandler(req, res);
}
