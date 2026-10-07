// Perpl's public market-data socket, read straight from the browser: one connection for the
// page, one order book at a time. A snapshot (mt 15) replaces the book; an update (mt 16)
// changes levels, and a level whose order count is zero is gone. Prices and sizes arrive
// scaled by the market's decimals. The socket allows ten requests a minute, so a market
// change is one frame that leaves the old stream and joins the new one.

const WS_URL = "wss://app.perpl.xyz/ws/v1/market-data";
const RETRY_MAX_MS = 30_000;

let socket = null;
let wanted = null;          // { id, decimals }
let subscribed = null;      // market id the socket currently streams
let sid = null;             // subscription id of the current snapshot
let bids = new Map();
let asks = new Map();
let at = 0;
let retryMs = 1_000;
let retryTimer = null;
let listeners = new Set();

const sorted = (map, descending) => [...map.values()].sort((a, b) => (descending ? b.price - a.price : a.price - b.price));

export function bookState() {
  return { bids: sorted(bids, true), asks: sorted(asks, false), at, live: socket?.readyState === WebSocket.OPEN && subscribed === wanted?.id && sid !== null };
}

function emit() { const state = bookState(); for (const fn of listeners) fn(state); }

function level(map, raw) {
  if (!wanted) return;
  if (!raw.o || !raw.s) { map.delete(raw.p); return; }
  map.set(raw.p, { price: raw.p / 10 ** wanted.decimals.price, size: raw.s / 10 ** wanted.decimals.size, orders: raw.o });
}

function apply(frame, snapshot) {
  if (snapshot) { bids = new Map(); asks = new Map(); sid = frame.sid ?? null; subscribed = wanted?.id ?? null; }
  else if (frame.sid != null && sid != null && frame.sid !== sid) return;
  for (const row of frame.bid ?? []) level(bids, row);
  for (const row of frame.ask ?? []) level(asks, row);
  at = Number(frame.at) || Date.now();
  emit();
}

function send(frame) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(frame));
}

function subscribe() {
  if (!wanted || socket?.readyState !== WebSocket.OPEN) return;
  const subs = [];
  if (subscribed != null && subscribed !== wanted.id) subs.push({ stream: `order-book@${subscribed}`, subscribe: false });
  subs.push({ stream: `order-book@${wanted.id}`, subscribe: true });
  sid = null;
  bids = new Map(); asks = new Map();
  send({ mt: 5, subs });
  subscribed = wanted.id;
  emit();
}

function connect() {
  if (socket || typeof WebSocket === "undefined") return;
  try { socket = new WebSocket(WS_URL); } catch { socket = null; scheduleRetry(); return; }
  socket.onopen = () => { retryMs = 1_000; subscribed = null; subscribe(); };
  socket.onmessage = (event) => {
    let frame;
    try { frame = JSON.parse(event.data); } catch { return; }
    if (frame.mt === 15) apply(frame, true);
    else if (frame.mt === 16) apply(frame, false);
  };
  socket.onclose = () => { socket = null; sid = null; subscribed = null; emit(); if (wanted) scheduleRetry(); };
  socket.onerror = () => { try { socket?.close(); } catch {} };
}

function scheduleRetry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(() => { retryTimer = null; if (wanted) connect(); }, retryMs);
  retryMs = Math.min(RETRY_MAX_MS, retryMs * 2);
}

/// Streams `marketId`'s book to `onChange` until the returned function is called. Decimals
/// are the market's `priceDecimals` and `sizeDecimals` from /api/v1/markets.
export function watchBook(marketId, decimals, onChange) {
  listeners.add(onChange);
  const changed = wanted?.id !== marketId;
  wanted = { id: marketId, decimals };
  if (socket?.readyState === WebSocket.OPEN) { if (changed) subscribe(); else onChange(bookState()); }
  else connect();
  return () => {
    listeners.delete(onChange);
    if (listeners.size === 0) {
      wanted = null;
      clearTimeout(retryTimer); retryTimer = null;
      try { socket?.close(); } catch {}
      socket = null; sid = null; subscribed = null;
      bids = new Map(); asks = new Map();
    }
  };
}

/// The price a market order of `size` (in the base asset) would fill at by walking the book:
/// asks for a buy, bids for a sell. Null when the book is empty or too thin for the size.
export function estimateFill(state, side, size) {
  const levels = side === "long" ? state.asks : state.bids;
  if (!levels.length || !(size > 0)) return null;
  let left = size, cost = 0;
  for (const row of levels) {
    const take = Math.min(left, row.size);
    cost += take * row.price;
    left -= take;
    if (left <= 1e-12) return { price: cost / size, levels: levels.indexOf(row) + 1, partial: false };
  }
  const filled = size - left;
  return filled > 0 ? { price: cost / filled, levels: levels.length, partial: true } : null;
}
