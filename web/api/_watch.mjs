import { isSolanaAddress } from "./_chains.mjs";

export const MAX_WALLETS = 25;
export const DEFAULT_MIN_USD = 250;
export const WALLET_PUSH_CAP = 20;
export const DIGEST_WINDOW_S = 900;
export const COLLAPSE_MS = 5 * 60_000;
const DUST = 1e-9;

export const seenKey = (address) => `alerts:seen:${address.toLowerCase()}`;
export const walletCountKey = (id, hour) => `alerts:wcount:${id}:${hour}`;
export const walletDigestKey = (id) => `alerts:wdigest:${id}`;

export const shortAddress = (address) => `${address.slice(0, 6)}…${address.slice(-4)}`;

export function compactNumber(value) {
  const abs = Math.abs(Number(value));
  if (!Number.isFinite(abs)) return "—";
  if (abs >= 1e9) return `${(abs / 1e9).toFixed(1)}B`;
  if (abs >= 1e6) return `${(abs / 1e6).toFixed(1)}M`;
  if (abs >= 1e3) return `${(abs / 1e3).toFixed(1)}K`;
  if (abs >= 100) return abs.toFixed(0);
  if (abs >= 1) return String(Math.round(abs * 100) / 100);
  return String(Math.round(abs * 10_000) / 10_000);
}

export function compactUsd(value) {
  const abs = Math.abs(Number(value));
  if (!Number.isFinite(abs)) return "$—";
  if (abs >= 1e6) return `$${(abs / 1e6).toFixed(1)}M`;
  if (abs >= 1e4) return `$${Math.round(abs / 1e3)}K`;
  if (abs >= 1e3) return `$${(abs / 1e3).toFixed(1)}K`;
  return `$${abs.toFixed(abs >= 100 ? 0 : 2)}`;
}

export const signedUsd = (value) => `${Number(value) < 0 ? "−" : "+"}${compactUsd(value)}`;

export function newestMarker(ledger) {
  const last = ledger?.trades?.[ledger.trades.length - 1];
  return last ? { time: last.time, hash: last.hash } : { time: 0, hash: null };
}

function firstNewIndex(trades, previous) {
  if (!previous) return 0;
  for (let index = trades.length - 1; index >= 0; index -= 1) {
    if (trades[index].hash === previous.hash && trades[index].time === previous.time) return index + 1;
  }
  // The marker's trade may have been trimmed from the ledger; time is the fallback.
  const after = trades.findIndex((trade) => trade.time > (previous.time ?? 0));
  return after === -1 ? trades.length : after;
}

export function walletEvents(previous, ledger, { minUsd = DEFAULT_MIN_USD, firstBuysOnly = false } = {}) {
  const trades = ledger?.trades ?? [];
  const start = firstNewIndex(trades, previous);
  const firstOf = new Map();
  const lastSellOf = new Map();
  trades.forEach((trade, index) => {
    if (!firstOf.has(trade.token)) firstOf.set(trade.token, index);
    if (trade.side === "sell") lastSellOf.set(trade.token, index);
  });

  const groups = [];
  const open = new Map();
  for (let index = start; index < trades.length; index += 1) {
    const trade = trades[index];
    let kind = trade.side;
    if (trade.side === "buy" && firstOf.get(trade.token) === index) kind = "first";
    const left = (ledger.positions?.[trade.token]?.holding ?? 0) + (ledger.positions?.[trade.token]?.unpriced ?? 0);
    if (trade.side === "sell" && lastSellOf.get(trade.token) === index && left <= DUST) kind = "close";

    const key = `${trade.token}:${trade.side}`;
    let group = open.get(key);
    if (group && trade.time - group.start > COLLAPSE_MS) { groups.push(group); group = null; }
    if (!group) {
      group = { kind, token: trade.token, symbol: trade.symbol, side: trade.side, amount: 0, value: 0, gain: null, count: 0, start: trade.time, time: trade.time, hash: trade.hash };
      open.set(key, group);
    }
    group.amount += trade.amount;
    group.value += trade.value;
    if (trade.gain != null) group.gain = (group.gain ?? 0) + trade.gain;
    group.count += 1;
    group.time = trade.time;
    group.hash = trade.hash;
    group.symbol = trade.symbol;
    if (trade.side === "sell") group.kind = kind;
  }
  groups.push(...open.values());

  return groups
    .sort((a, b) => a.time - b.time)
    .filter((event) => event.kind === "close" || event.value >= minUsd)
    .filter((event) => !firstBuysOnly || event.kind === "first" || event.kind === "close")
    .map(({ start, ...event }) => event);
}

function body(event) {
  const symbol = String(event.symbol ?? "?").slice(0, 16);
  switch (event.kind) {
    case "first":
      return `🐋 bought ${compactNumber(event.amount)} ${symbol} (${compactUsd(event.value)}) · first buy`;
    case "buy":
      return event.count > 1
        ? `🎯 bought ${symbol} ${event.count}× (${compactUsd(event.value)} total)`
        : `🎯 added ${compactNumber(event.amount)} ${symbol} (${compactUsd(event.value)})`;
    case "sell":
      return `📤 sold ${compactNumber(event.amount)} ${symbol} (${compactUsd(event.value)})${event.gain == null ? "" : ` · ${signedUsd(event.gain)} realized`}`;
    case "close": {
      if (event.gain == null) return `✅ closed ${symbol}`;
      const cost = event.value - event.gain;
      const percent = cost > 0 ? Math.round((event.gain / cost) * 100) : null;
      const pct = percent == null ? "" : ` (${percent < 0 ? "−" : "+"}${Math.abs(percent)}%)`;
      return `✅ closed ${symbol} · ${signedUsd(event.gain)}${pct}`;
    }
    default:
      return `${event.count} tracked wallet${event.count === 1 ? "" : "s"} traded in the last 15 min`;
  }
}

export function walletPayload(record, wallet, event) {
  const address = wallet?.address ?? null;
  const digest = event.kind === "digest";
  const title = digest ? "Tracked wallets" : (wallet?.name || shortAddress(address));
  return {
    aps: {
      alert: { title, body: body(event).slice(0, 100) },
      sound: "default",
      "thread-id": digest ? "wallet-digest" : `wallet-${address}`,
      category: "desk.wallet",
      "relevance-score": 0.7,
    },
    desk: {
      type: "wallet",
      event: event.kind,
      wallet: address,
      name: wallet?.name ?? null,
      token: event.token ?? null,
      symbol: event.symbol ?? null,
      chainIndex: isSolanaAddress(address ?? "") ? "501" : "143",
      amount: event.amount ?? null,
      valueUsd: event.value ?? null,
      gain: event.gain ?? null,
      count: event.count ?? null,
      observedAt: Date.now(),
    },
  };
}
