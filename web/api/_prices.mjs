/// Levels are a tenth of the price's magnitude: $1K on Bitcoin, $100 on Ether.

export const ASSET_NAMES = {
  BTC: "Bitcoin", ETH: "Ethereum", SOL: "Solana", MON: "Monad", HYPE: "Hyperliquid", ZEC: "Zcash", LIT: "Lighter", PUMP: "Pump", VVV: "Venice", NEAR: "NEAR",
};
export const MOVE_THRESHOLDS = [0.05, 0.1, 0.2];
const LEVEL_QUIET_S = 6 * 3600;
const MARK_TTL_S = 7 * 86400;

export const MARKS_KEY = "alerts:marks";
export const levelKey = (name, level, direction) => `alerts:pxlevel:${name}:${level}:${direction}`;
export const moveKey = (name, day, direction, threshold) => `alerts:pxmove:${name}:${day}:${direction}${Math.round(threshold * 100)}`;

export function levelStep(price) {
  if (!(price > 0)) return null;
  return 10 ** (Math.floor(Math.log10(price)) - 1);
}

export function levelText(value) {
  if (value >= 1e6) return `$${trim(value / 1e6)}M`;
  if (value >= 1e3) return `$${trim(value / 1e3)}K`;
  if (value >= 1) return `$${trim(value)}`;
  return `$${Number(value.toPrecision(3)).toString()}`;
}
const trim = (n) => String(Number(n.toFixed(2)));

export function priceText(value) {
  if (value == null) return "";
  if (value >= 1000) return `$${Math.round(value).toLocaleString("en-US")}`;
  if (value >= 1) return `$${value.toFixed(2)}`;
  return `$${Number(value.toPrecision(3)).toString()}`;
}

export function priceEvents(name, previous, current) {
  const events = [];
  if (!(current.mark > 0)) return events;
  const step = levelStep(current.mark);
  if (previous?.mark > 0 && step) {
    const before = Math.floor(previous.mark / step + 1e-9);
    const after = Math.floor(current.mark / step + 1e-9);
    if (after > before) events.push({ kind: "level", direction: "up", level: after * step, mark: current.mark });
    else if (after < before) events.push({ kind: "level", direction: "down", level: before * step, mark: current.mark });
  }
  if (current.prev > 0) {
    const change = (current.mark - current.prev) / current.prev;
    const direction = change >= 0 ? "up" : "down";
    const passed = MOVE_THRESHOLDS.filter((threshold) => Math.abs(change) >= threshold);
    if (passed.length) events.push({ kind: "move", direction, threshold: passed[passed.length - 1], change, mark: current.mark });
  }
  return events;
}

export function pricePayload(name, event) {
  const asset = ASSET_NAMES[name] ?? name;
  const dot = event.direction === "up" ? "🟢" : "🔴";
  const body = event.kind === "level"
    ? `${asset} just ${event.direction === "up" ? "broke" : "fell through"} ${levelText(event.level)} ${dot}`
    : `${asset} is ${event.direction === "up" ? "up" : "down"} ${Math.round(Math.abs(event.change) * 100)}% today ${dot} · ${priceText(event.mark)}`;
  return {
    aps: { alert: { title: "Desk", body }, sound: "default", "interruption-level": "time-sensitive", "thread-id": "prices" },
    desk: { type: "price", market: name, mark: event.mark, kind: event.kind, direction: event.direction, ...(event.level != null ? { level: event.level } : {}) },
  };
}

export const MAX_TARGETS = 20;

export function parseTargets(targets) {
  if (targets == null) return [];
  if (!Array.isArray(targets) || targets.length > MAX_TARGETS) return null;
  const out = [];
  for (const entry of targets) {
    if (!entry || typeof entry !== "object") return null;
    const { market, price, direction } = entry;
    if (typeof market !== "string" || !/^[A-Za-z0-9]{1,12}$/.test(market)) return null;
    if (typeof price !== "number" || !Number.isFinite(price) || price <= 0) return null;
    if (direction !== "above" && direction !== "below") return null;
    const symbol = market.toUpperCase();
    if (out.some((t) => t.market === symbol && t.price === price && t.direction === direction)) continue;
    out.push({ market: symbol, price, direction });
  }
  return out;
}

export function crossed(target, previous, current) {
  if (!(previous > 0) || !(current > 0)) return false;
  return target.direction === "above"
    ? previous < target.price && current >= target.price
    : previous > target.price && current <= target.price;
}

export function targetPayload(target, mark) {
  const asset = ASSET_NAMES[target.market] ?? target.market;
  const up = target.direction === "above";
  const body = `${asset} crossed ${priceText(target.price)} ${up ? "🟢" : "🔴"} · now ${priceText(mark)}`;
  return {
    aps: { alert: { title: "Price alert", body }, sound: "default", "interruption-level": "time-sensitive", "thread-id": "prices" },
    desk: { type: "price", kind: "target", market: target.market, level: target.price, direction: up ? "up" : "down", mark },
  };
}

export const ALWAYS_TOLD = new Set(["BTC", "MON"]);

export function wantsMarket(record, name) {
  if (record.prices === false) return false;
  return ALWAYS_TOLD.has(name) || (record.priceMarkets ?? []).includes(name);
}

export async function priceDeliveries({ store, quotes, subscribers, now = Date.now() }) {
  if (!quotes?.length) return { deliveries: [], events: 0, changed: [] };
  let stored = {};
  try { stored = JSON.parse(await store.get(MARKS_KEY) ?? "{}") ?? {}; } catch {}
  // A market missing from one scan keeps its last mark for a week.
  const previous = Object.fromEntries(Object.entries(stored).filter(([, last]) => now - (last?.at ?? 0) < MARK_TTL_S * 1000));
  const day = new Date(now).toISOString().slice(0, 10);
  const deliveries = [];
  let events = 0;
  const marks = { ...previous };
  const changed = new Map();
  for (const quote of quotes) {
    marks[quote.name] = { mark: quote.mark, at: now };
    const last = previous[quote.name] ?? null;
    // The first reading is the baseline; a day already half over is old news.
    if (!last) continue;
    for (const subscriber of subscribers) {
      const record = changed.get(subscriber.id) ?? subscriber.record;
      const hits = (record.targets ?? []).filter((target) => target.market === quote.name && crossed(target, last.mark, quote.mark));
      if (!hits.length) continue;
      const remaining = { ...record, targets: record.targets.filter((target) => !hits.includes(target)) };
      changed.set(subscriber.id, remaining);
      for (const target of hits) {
        events += 1;
        deliveries.push({ id: subscriber.id, record: remaining, payload: targetPayload(target, quote.mark),
          collapseId: `tgt-${quote.name}-${target.price}` });
      }
    }
    for (const event of priceEvents(quote.name, last, quote)) {
      const key = event.kind === "level" ? levelKey(quote.name, event.level, event.direction) : moveKey(quote.name, day, event.direction, event.threshold);
      const fresh = await store.set(key, "1", { ex: event.kind === "level" ? LEVEL_QUIET_S : 2 * 86400, nx: true });
      if (!fresh) continue;
      events += 1;
      const payload = pricePayload(quote.name, event);
      for (const { id, record } of subscribers) {
        if (!wantsMarket(record, quote.name)) continue;
        deliveries.push({ id, record, payload, collapseId: `px-${quote.name}` });
      }
    }
  }
  await store.set(MARKS_KEY, JSON.stringify(marks), { ex: MARK_TTL_S });
  return { deliveries, events, changed: [...changed] };
}
