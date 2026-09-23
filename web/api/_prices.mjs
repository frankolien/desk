/// Price alerts for every Perpl market: a round level broken or fallen through, and a
/// day's move past 5, 10 or 20 percent. Levels are a tenth of the price's magnitude —
/// $1K on Bitcoin, $100 on Ether, $10 on Solana, a tenth of a cent on MON — so the
/// alert says the number a person would say.

export const ASSET_NAMES = {
  BTC: "Bitcoin", ETH: "Ethereum", SOL: "Solana", MON: "Monad", HYPE: "Hyperliquid", ZEC: "Zcash", LIT: "Lighter", PUMP: "Pump",
};
export const MOVE_THRESHOLDS = [0.05, 0.1, 0.2];
const LEVEL_QUIET_S = 6 * 3600;
const MARK_TTL_S = 7 * 86400;

export const markKey = (name) => `alerts:px:${name}`;
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

/// What changed between the last reading and this one, per market.
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

/// Bitcoin because it is the market everyone watches, Monad because Desk lives on it.
/// Everything else only reaches a phone that put the market on its watchlist.
export const ALWAYS_TOLD = new Set(["BTC", "MON"]);

export function wantsMarket(record, name) {
  if (record.prices === false) return false;
  return ALWAYS_TOLD.has(name) || (record.priceMarkets ?? []).includes(name);
}

/// Reads the last marks, finds what crossed, and returns one delivery per subscriber
/// per event. Levels stay quiet six hours once told; a day's move is told once per
/// threshold and direction.
export async function priceDeliveries({ store, quotes, subscribers, now = Date.now() }) {
  if (!quotes?.length) return { deliveries: [], events: 0 };
  const names = quotes.map((q) => q.name);
  const previous = await store.mget(names.map(markKey));
  const day = new Date(now).toISOString().slice(0, 10);
  const deliveries = [];
  let events = 0;
  const marks = [];
  for (const [index, quote] of quotes.entries()) {
    marks.push([markKey(quote.name), JSON.stringify({ mark: quote.mark, at: now })]);
    const last = previous[index] ? JSON.parse(previous[index]) : null;
    // The first reading is the baseline; a day already half over is old news.
    if (!last) continue;
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
  await store.setMany(marks, MARK_TTL_S);
  return { deliveries, events };
}
