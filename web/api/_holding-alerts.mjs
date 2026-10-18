import { currentPrices } from "./_wallet.mjs";

/// Alerts on a token someone holds: "tell me each time it moves another 5% from what I paid".
/// The step is 5, 10 or 20 percent; up and down can each be switched off. `told` is the last
/// step level the person heard about, kept server-side so a re-sync never repeats a push.
export const MAX_HOLDING_ALERTS = 30;
export const HOLDING_STEPS = [0.05, 0.1, 0.2];

const evmAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(String(value ?? ""));
const solanaAddress = (value) => /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(String(value ?? ""));
export const holdingKey = (alert) => `${alert.chainIndex}:${alert.contract}`;

export function parseHoldingAlerts(list) {
  if (list == null) return [];
  if (!Array.isArray(list) || list.length > MAX_HOLDING_ALERTS) return null;
  const out = [];
  const seen = new Set();
  for (const row of list) {
    if (!row || typeof row !== "object") return null;
    const chainIndex = String(row.chainIndex ?? "");
    if (!/^\d{1,6}$/.test(chainIndex)) return null;
    const contract = evmAddress(row.contract) ? String(row.contract).toLowerCase() : solanaAddress(row.contract) ? String(row.contract) : null;
    if (!contract) return null;
    const anchor = Number(row.anchor);
    const step = Number(row.step);
    if (!(anchor > 0) || !Number.isFinite(anchor) || !HOLDING_STEPS.includes(step)) return null;
    const symbol = String(row.symbol ?? "").replace(/[^\w$.-]/g, "").slice(0, 12) || "token";
    const up = row.up !== false, down = row.down !== false;
    if (!up && !down) continue;
    const alert = { chainIndex, contract, symbol, anchor, step, up, down, told: Number.isInteger(row.told) ? row.told : 0 };
    if (seen.has(holdingKey(alert))) continue;
    seen.add(holdingKey(alert));
    out.push(alert);
  }
  return out;
}

/// `told` belongs to the server: a phone re-sending its alerts keeps what it has already heard.
export function carryTold(fresh, previous) {
  const before = new Map((previous ?? []).map((alert) => [holdingKey(alert), alert]));
  return fresh.map((alert) => {
    const old = before.get(holdingKey(alert));
    return old && old.anchor === alert.anchor && old.step === alert.step ? { ...alert, told: old.told ?? 0 } : { ...alert, told: 0 };
  });
}

/// How many whole steps the price sits from the anchor, signed. A new step counts once the price
/// is a third of a step past its line, so hovering on a line never rings twice; a jump of two
/// steps counts at once. Coming back within half a step of the price paid is "even".
export function stepLevel(alert, price, told = alert.told ?? 0) {
  const raw = (price / alert.anchor - 1) / alert.step;
  const level = (raw >= 0 ? Math.floor(raw) : Math.ceil(raw)) || 0;
  if (level === told) return told;
  const margin = Math.abs(raw - level) >= 0.34 || Math.abs(level - told) >= 2;
  if (level === 0) return told !== 0 && Math.abs(raw) <= 0.5 ? 0 : told;
  const away = Math.abs(level) > Math.abs(told) && (told === 0 || Math.sign(level) === Math.sign(told));
  const flipped = told !== 0 && Math.sign(level) !== Math.sign(told);
  return (away || flipped) && margin ? level : told;
}

/// The event to send, if the price has reached a new step in a direction the person wants.
export function holdingEvent(alert, price) {
  if (!(price > 0)) return null;
  const told = alert.told ?? 0;
  const level = stepLevel(alert, price, told);
  if (level === told) return null;
  const direction = level > told ? "up" : "down";
  const wanted = direction === "up" ? alert.up : alert.down;
  const next = { ...alert, told: level };
  if (!wanted) return { alert: next, event: null };
  const percent = Math.round((price / alert.anchor - 1) * 1000) / 10;
  return { alert: next, event: { direction, level, percent, price } };
}

export function compactPrice(value) {
  if (!(value > 0)) return "—";
  if (value >= 1000) return `$${Math.round(value).toLocaleString("en-US")}`;
  if (value >= 1) return `$${value.toFixed(2)}`;
  if (value >= 0.01) return `$${value.toFixed(4)}`;
  return `$${value.toPrecision(3)}`;
}

export function holdingPayload(alert, event) {
  const up = event.direction === "up";
  const pct = `${Math.abs(event.percent).toFixed(Math.abs(event.percent) >= 10 ? 0 : 1)}%`;
  const since = Math.abs(event.percent) < 2 ? "back to what you paid" : event.percent > 0 ? `up ${pct} since you bought` : `down ${pct} since you bought`;
  const body = `${alert.symbol} is ${since} ${up ? "🟢" : "🔴"} · ${compactPrice(event.price)}`;
  return {
    aps: { alert: { title: up ? "Your token is up" : "Your token is down", body }, sound: "default", "interruption-level": "time-sensitive", "thread-id": "holdings" },
    desk: { type: "holding", chainIndex: alert.chainIndex, token: alert.contract, symbol: alert.symbol, direction: event.direction,
      percent: event.percent, price: event.price, anchor: alert.anchor },
  };
}

/// One price read per token, however many people hold it; a push per person per new step.
export async function holdingDeliveries({ subscribers, prices = currentPrices }) {
  const wanted = new Map(); // chainIndex -> Set(contract)
  for (const { record } of subscribers) {
    for (const alert of record.holdings ?? []) {
      if (!wanted.has(alert.chainIndex)) wanted.set(alert.chainIndex, new Set());
      wanted.get(alert.chainIndex).add(alert.contract);
    }
  }
  if (wanted.size === 0) return { deliveries: [], events: 0, changed: [] };
  const quotes = new Map();
  for (const [chainIndex, contracts] of wanted) {
    const list = [...contracts];
    for (let i = 0; i < list.length; i += 50) {
      const found = await prices(chainIndex, list.slice(i, i + 50)).catch(() => new Map());
      for (const [contract, price] of found) quotes.set(`${chainIndex}:${String(contract).toLowerCase()}`, price);
    }
  }
  const deliveries = [];
  const changed = new Map();
  let events = 0;
  for (const { id, record } of subscribers) {
    let touched = false;
    const holdings = (record.holdings ?? []).map((alert) => {
      const price = quotes.get(`${alert.chainIndex}:${alert.contract.toLowerCase()}`);
      const outcome = holdingEvent(alert, price);
      if (!outcome) return alert;
      touched = true;
      if (outcome.event) {
        events += 1;
        deliveries.push({ id, record, payload: holdingPayload(alert, outcome.event), collapseId: `hold-${alert.contract.slice(0, 12)}`, part: "holdings" });
      }
      return outcome.alert;
    });
    if (touched) changed.set(id, { ...record, holdings });
  }
  // Deliveries carry the updated record, so a dead token or moved environment keeps the new levels.
  for (const delivery of deliveries) if (changed.has(delivery.id)) delivery.record = changed.get(delivery.id);
  return { deliveries, events, changed: [...changed] };
}
