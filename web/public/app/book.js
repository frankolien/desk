// Perpl's public market-data socket, read straight from the browser: one connection for the
// page, one order book at a time. A snapshot (mt 15) replaces the book; an update (mt 16)
// changes levels, and a level whose order count is zero is gone. Prices and sizes arrive
// scaled by the market's decimals. The socket allows ten requests a minute, so a market
// change is one frame that leaves the old stream and joins the new one.
//
// Perpl refuses browser origins it has not whitelisted, so when the direct socket closes
// without ever serving a snapshot the same frames are read from Desk's own relay instead,
// `/api/v1/markets/{market}/stream`, server-sent events carrying Perpl's JSON unchanged.

const WS_URL = "wss://app.perpl.xyz/ws/v1/market-data";
const RETRY_MAX_MS = 30_000;

let socket = null;
let relay = null;           // EventSource to Desk's relay, once the direct socket is refused
let direct = true;          // whether the direct socket is still worth trying
let served = false;         // whether the direct socket ever delivered a snapshot
let wanted = null;          // { id, name, decimals }
let subscribed = null;      // market id the socket currently streams
let sid = null;             // subscription id of the current snapshot
let bids = new Map();
let asks = new Map();
let at = 0;
let retryMs = 1_000;
let retryTimer = null;
let listeners = new Set();

const sorted = (map, descending) => [...map.values()].sort((a, b) => (descending ? b.price - a.price : a.price - b.price));

const connected = () => socket?.readyState === WebSocket.OPEN || relay?.readyState === EventSource.OPEN;

export function bookState() {
  return { bids: sorted(bids, true), asks: sorted(asks, false), at, live: connected() && subscribed === wanted?.id && sid !== null };
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

function handle(text) {
  let frame;
  try { frame = JSON.parse(text); } catch { return; }
  if (frame.mt === 15) { served = true; apply(frame, true); }
  else if (frame.mt === 16) apply(frame, false);
}

function connect() {
  if (!direct) { connectRelay(); return; }
  if (socket || typeof WebSocket === "undefined") return;
  try { socket = new WebSocket(WS_URL); } catch { socket = null; direct = false; connectRelay(); return; }
  socket.onopen = () => { retryMs = 1_000; subscribed = null; subscribe(); };
  socket.onmessage = (event) => handle(event.data);
  socket.onclose = () => {
    socket = null; sid = null; subscribed = null; emit();
    if (!wanted) return;
    // Refused before a single snapshot: the origin is not on Perpl's list. Read through Desk.
    if (!served) { direct = false; connectRelay(); } else scheduleRetry();
  };
  socket.onerror = () => { try { socket?.close(); } catch {} };
}

function connectRelay() {
  if (relay || !wanted?.name || typeof EventSource === "undefined") return;
  sid = null; bids = new Map(); asks = new Map();
  relay = new EventSource(`/api/v1/markets/${encodeURIComponent(wanted.name)}/stream`);
  const forMarket = wanted.id;
  relay.onopen = () => { retryMs = 1_000; subscribed = forMarket; emit(); };
  relay.onmessage = (event) => handle(event.data);
  relay.addEventListener("bye", () => { try { relay?.close(); } catch {} relay = null; if (wanted) connectRelay(); });
  relay.onerror = () => { try { relay?.close(); } catch {} relay = null; sid = null; emit(); if (wanted) scheduleRetry(); };
}

function scheduleRetry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(() => { retryTimer = null; if (wanted) connect(); }, retryMs);
  retryMs = Math.min(RETRY_MAX_MS, retryMs * 2);
}

/// Streams `marketId`'s book to `onChange` until the returned function is called. Decimals
/// are the market's `priceDecimals` and `sizeDecimals` from /api/v1/markets.
export function watchBook(marketId, decimals, onChange, name = null) {
  listeners.add(onChange);
  const changed = wanted?.id !== marketId;
  wanted = { id: marketId, name, decimals };
  if (socket?.readyState === WebSocket.OPEN) { if (changed) subscribe(); else onChange(bookState()); }
  else if (relay) { if (changed) { try { relay.close(); } catch {} relay = null; connectRelay(); } else onChange(bookState()); }
  else connect();
  return () => {
    listeners.delete(onChange);
    if (listeners.size === 0) {
      wanted = null;
      clearTimeout(retryTimer); retryTimer = null;
      try { socket?.close(); } catch {}
      try { relay?.close(); } catch {}
      socket = null; relay = null; sid = null; subscribed = null;
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
