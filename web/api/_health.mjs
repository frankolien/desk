import { redisStore } from "./_store.mjs";

const PROBE_TIMEOUT_MS = 2500;
const CACHE_KEY = "health:cache";
const CACHE_SECONDS = 10;
const HEARTBEAT_KEY = "wl:heartbeat";
const LAST_SCAN_KEY = "alerts:lastScan";

export const RPC_URL = "https://rpc.monad.xyz";
export const PERPL_URL = "https://app.perpl.xyz/api/v1/pub/context";

async function timed(run, timeoutMs = PROBE_TIMEOUT_MS) {
  const started = Date.now();
  let timer;
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), timeoutMs); });
  try {
    const value = await Promise.race([run(), timeout]);
    return { ok: true, value, ms: Date.now() - started };
  } catch (error) {
    return { ok: false, error: String(error?.message ?? error), ms: Date.now() - started };
  } finally {
    clearTimeout(timer);
  }
}

const ageSeconds = (at, now) => {
  const then = typeof at === "number" ? at : Date.parse(String(at ?? ""));
  return Number.isFinite(then) ? Math.max(0, Math.round((now - then) / 1000)) : null;
};

export function gradeAge(age, { warn, fail }) {
  if (age == null) return "unknown";
  if (age > fail) return "fail";
  if (age > warn) return "warn";
  return "pass";
}

/// pass/warn/fail across the checks: critical failures fail the whole, everything else warns.
export function overall(checks, critical) {
  const rows = Object.entries(checks).map(([name, [row]]) => ({ name, status: row.status }));
  if (rows.some((row) => row.status === "fail" && critical.includes(row.name))) return "fail";
  if (rows.some((row) => row.status === "warn" || row.status === "fail")) return "warn";
  return "pass";
}

export function defaultProbes({ store, fetchImpl = fetch, rpcURL = RPC_URL, perplURL = PERPL_URL } = {}) {
  return {
    async redis() {
      if (!store) throw new Error("not configured");
      await store.get("health:probe");
    },
    async rpc() {
      const response = await fetchImpl(rpcURL, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] }),
      });
      if (!response.ok) throw new Error(`rpc ${response.status}`);
      const body = await response.json();
      return Number.parseInt(body.result, 16);
    },
    async perpl() {
      const response = await fetchImpl(perplURL, { method: "GET", headers: { accept: "application/json" } });
      if (!response.ok) throw new Error(`perpl ${response.status}`);
      return response.status;
    },
    async heartbeat() {
      if (!store) return null;
      const raw = await store.get(HEARTBEAT_KEY);
      return raw ? JSON.parse(raw) : null;
    },
    async lastScan() {
      return store ? store.get(LAST_SCAN_KEY) : null;
    },
  };
}

export function createHealth({
  store = redisStore(), probes = defaultProbes({ store }), now = Date.now, timeoutMs = PROBE_TIMEOUT_MS,
  releaseId = process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ?? null,
} = {}) {
  async function run() {
    const at = now();
    const time = new Date(at).toISOString();
    const [redis, rpc, perpl, heartbeat, lastScan] = await Promise.all(
      [probes.redis, probes.rpc, probes.perpl, probes.heartbeat, probes.lastScan].map((probe) => timed(probe, timeoutMs)),
    );
    const latency = (result, failStatus) => ({
      status: result.ok ? "pass" : failStatus, observedValue: result.ms, observedUnit: "ms", time,
      ...(result.ok ? {} : { output: result.error }),
    });
    const heartbeatAge = heartbeat.ok ? ageSeconds(heartbeat.value?.at, at) : null;
    const scanAge = lastScan.ok ? ageSeconds(lastScan.value, at) : null;
    const checks = {
      "redis:responseTime": [latency(redis, "fail")],
      "monad-rpc:responseTime": [{ ...latency(rpc, "warn"), ...(rpc.ok ? { block: rpc.value } : {}) }],
      "perpl:responseTime": [latency(perpl, "warn")],
      "worker:heartbeatAge": [{
        status: heartbeatAge == null ? "fail" : gradeAge(heartbeatAge, { warn: 4 * 60, fail: 10 * 60 }),
        observedValue: heartbeatAge, observedUnit: "s", time,
        ...(heartbeat.ok && heartbeat.value ? { wallets: heartbeat.value.wallets ?? null, behind: heartbeat.value.behind ?? null } : {}),
      }],
      "cron:lastRunAge": [{
        status: gradeAge(scanAge, { warn: 15 * 60, fail: 2 * 3600 }), observedValue: scanAge, observedUnit: "s", time,
      }],
    };
    return { status: overall(checks, ["redis:responseTime", "worker:heartbeatAge"]), version: "1", releaseId, time, checks };
  }

  return async function health() {
    if (store) {
      const cached = await store.get(CACHE_KEY).catch(() => null);
      if (cached) {
        try { return { report: JSON.parse(cached), cached: true }; } catch { /* fall through */ }
      }
    }
    const report = await run();
    if (store) await store.set(CACHE_KEY, JSON.stringify(report), { ex: CACHE_SECONDS }).catch(() => {});
    return { report, cached: false };
  };
}
