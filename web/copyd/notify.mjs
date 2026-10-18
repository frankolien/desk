/// Every result the engine records, as a push to the copier's phone: the app is not open to show
/// it. Shadow results say so in the title, so a paper copy is never mistaken for money. Skips are
/// held to one per trader per hour; everything else always goes.
import { resolveIdentities } from "../api/_identity.mjs";
import { deskProfiles } from "../api/_profile.mjs";

export const shortAddress = (address) => `${address.slice(0, 6)}…${address.slice(-4)}`;
const EVM = /^0x[a-fA-F0-9]{40}$/;

/// Who a trader is, for the push: their Desk tag as "@tag", else the name Desk already knows
/// them by (the identity cache; name services are asked at most once a day), else nothing, and
/// the payload falls back to the short address. Answers are held for ten minutes so one sweep's
/// pushes don't each read Redis.
export function traderNames({ store, fetchImpl = fetch, now = Date.now, ttlMs = 10 * 60_000 }) {
  const known = new Map();
  return async function name(address) {
    if (!store || !EVM.test(address ?? "")) return null;
    const key = address.toLowerCase();
    const hit = known.get(key);
    if (hit && now() - hit.at < ttlMs) return hit.value;
    let value = null;
    try {
      const profile = (await deskProfiles(store, [key])).get(key);
      if (profile?.tag) value = `@${profile.tag}`;
      else {
        const identity = (await resolveIdentities([key], { store, fetchImpl }))[key];
        value = identity?.tag ? `@${identity.tag}` : identity?.name ?? null;
      }
    } catch { value = null; }
    known.set(key, { value, at: now() });
    if (known.size > 5_000) for (const [k, v] of known) if (now() - v.at >= ttlMs) known.delete(k);
    return value;
  };
}

const side = (row) => (row.isLong ? "Long" : "Short");
const money = (value) => `${value >= 0 ? "+" : "−"}${Math.abs(value).toFixed(2)} AUSD`;

export function copyPayload(row, { name } = {}) {
  const who = name || (row.trader ? shortAddress(row.trader) : "");
  const what = `${side(row)} ${row.symbol}${row.leverage ? ` ${row.leverage}×` : ""}`;
  const paper = row.isShadow ? "Shadow · " : "";
  let title;
  let body = row.detail;
  switch (row.kind) {
    case "opened": title = `${paper}Copied ${who}: ${what}`; break;
    case "closed": title = `${paper}Closed with ${who}: ${what}`; if (Number.isFinite(row.pnl)) body = `${money(row.pnl)}. ${row.detail}`; break;
    case "protected": title = `${paper}${row.symbol} copy closed on its own`; if (Number.isFinite(row.pnl)) body = `${row.detail} ${money(row.pnl)}.`; break;
    case "skipped": title = `${paper}Didn't copy ${who}'s ${row.symbol} ${row.isLong ? "long" : "short"}`; break;
    case "failed": title = `Couldn't copy ${who}`; break;
    case "paused": title = "Auto-Copy paused"; break;
    case "resumed": title = "Auto-Copy resumed"; break;
    default: return null;
  }
  return {
    aps: {
      alert: { title, body },
      sound: row.kind === "skipped" || row.isShadow ? undefined : "default",
      "thread-id": "auto-copy",
      "relevance-score": row.isShadow ? 0.3 : 0.9,
    },
    desk: { type: "copy", kind: row.kind, trader: row.trader, symbol: row.symbol, shadow: Boolean(row.isShadow), id: row.id },
  };
}

/// `send(push, payload, {collapseId})` is the APNs client's send. The skip throttle is kept in
/// memory: a restart can let one extra skip through per trader, which costs less than a Redis
/// write for every skip of every copier.
export function createNotifier({ send, names = () => null, now = Date.now }) {
  const skipNoted = new Map(); // `${copier}|${trader}` -> hour
  return async function notify(copier, row) {
    if (!copier.push?.token) return { skipped: "no device" };
    if (row.isShadow && copier.notifyShadow === false) return { skipped: "shadow muted" };
    if (row.kind === "skipped") {
      const hour = Math.floor(now() / 3_600_000);
      const key = `${copier.id}|${row.trader}`;
      if (skipNoted.get(key) === hour) return { skipped: "throttled" };
      skipNoted.set(key, hour);
      if (skipNoted.size > 50_000) for (const [k, h] of skipNoted) if (h !== hour) skipNoted.delete(k);
    }
    let name = null;
    try { name = row.trader ? await names(row.trader) : null; } catch { name = null; }
    const payload = copyPayload(row, { name });
    if (!payload) return { skipped: "silent kind" };
    return send(copier.push, payload, { collapseId: `copy-${row.id}`.slice(0, 64) });
  };
}

/// Sends through Desk's API (/api/copy/notify), which holds the APNs key, so copyd needs none.
/// Pushes made within 250 ms go together, up to 100 a request.
export function apiSender({ base, secret, fetchImpl = fetch, waitMs = 250 }) {
  let queue = [];
  let timer = null;
  async function flush() {
    timer = null;
    const batch = queue.splice(0, 100);
    if (queue.length) timer = setTimeout(flush, 0);
    try {
      const response = await fetchImpl(`${base}/api/copy/notify`, {
        method: "POST", headers: { authorization: `Bearer ${secret}`, "content-type": "text/plain" },
        body: JSON.stringify({ items: batch.map(({ push, payload, options }) => ({ push, payload, collapseId: options?.collapseId })) }),
      });
      const answer = await response.json().catch(() => ({}));
      batch.forEach((item, i) => item.resolve(answer.results?.[i] ?? { status: response.status }));
    } catch (error) {
      batch.forEach((item) => item.resolve({ status: 0, error: error.message }));
    }
  }
  return (push, payload, options) => new Promise((resolve) => {
    queue.push({ push, payload, options, resolve });
    timer ??= setTimeout(flush, waitMs);
  });
}
