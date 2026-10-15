/// Every result the engine records, as a push to the copier's phone: the app is not open to show
/// it. Shadow results say so in the title, so a paper copy is never mistaken for money. Skips are
/// held to one per trader per hour; everything else always goes.
export const shortAddress = (address) => `${address.slice(0, 6)}…${address.slice(-4)}`;

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
    const payload = copyPayload(row, { name: names(row.trader) });
    if (!payload) return { skipped: "silent kind" };
    return send(copier.push, payload, { collapseId: `copy-${row.id}`.slice(0, 64) });
  };
}
