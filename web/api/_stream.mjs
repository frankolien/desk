/// Perpl's public market-data socket, held once per function instance and fanned out to the
/// browsers streaming from it. Perpl refuses browser origins it has not whitelisted, but a
/// server connection carries no origin, so the page reads the same frames through here until
/// trydesk.trade is on Perpl's list. Market state (every mark) and the heartbeat go to every
/// subscriber; a market's book and trades are joined when the first subscriber asks and
/// left when the last one goes, in one subscription frame each way, since the socket allows
/// ten such requests a minute.

const WS_URL = process.env.PERPL_WS_URL || "wss://app.perpl.xyz/ws/v1/market-data";
const CHAIN = 143;
const RETRY_MAX_MS = 30_000;

let socket = null;
let retryMs = 1_000;
let retryTimer = null;
const subscribers = new Map(); // market id -> Set<(frame: string) => void>
const sids = new Map();        // sid -> market id, for book and trade frames
const broadcast = new Set();   // sid of chain-wide streams
const books = new Map();       // market id -> { sid, at, bid: Map, ask: Map }: the book as it stands
const trades = new Map();      // market id -> last trades snapshot text
let lastState = null;          // last market-state frame text, every market's mark

/// A reader joining a market already streamed would otherwise see only updates, which mean
/// nothing without the snapshot they amend; the hub keeps the book current and sends a
/// snapshot of its own making first.
function remember(frame, text) {
  if (frame.mt === 9) { lastState = text; return; }
  const market = sids.get(frame.sid);
  if (market == null) return;
  if (frame.mt === 17) { trades.set(market, text); return; }
  if (frame.mt !== 15 && frame.mt !== 16) return;
  let book = books.get(market);
  if (frame.mt === 15 || !book || book.sid !== frame.sid) { book = { sid: frame.sid, at: frame.at, bid: new Map(), ask: new Map() }; books.set(market, book); }
  book.at = frame.at ?? book.at;
  for (const side of ["bid", "ask"]) for (const row of frame[side] ?? []) { if (!row.o || !row.s) book[side].delete(row.p); else book[side].set(row.p, row); }
}

function snapshotText(market) {
  const book = books.get(market);
  if (!book) return null;
  return JSON.stringify({ mt: 15, sid: book.sid, at: book.at, bid: [...book.bid.values()], ask: [...book.ask.values()] });
}

function open() {
  if (socket || typeof WebSocket === "undefined") return;
  try { socket = new WebSocket(WS_URL); } catch { socket = null; retry(); return; }
  socket.addEventListener("open", () => {
    retryMs = 1_000;
    sids.clear(); broadcast.clear();
    const subs = [{ stream: `heartbeat@${CHAIN}`, subscribe: true }, { stream: `market-state@${CHAIN}`, subscribe: true }];
    for (const id of subscribers.keys()) subs.push({ stream: `order-book@${id}`, subscribe: true }, { stream: `trades@${id}`, subscribe: true });
    socket.send(JSON.stringify({ mt: 5, subs }));
  });
  socket.addEventListener("message", (event) => {
    const text = typeof event.data === "string" ? event.data : String(event.data);
    let frame;
    try { frame = JSON.parse(text); } catch { return; }
    if (frame.mt === 6) {
      for (const sub of frame.subs ?? []) {
        if (sub.status?.code !== 0 || sub.sid == null) continue;
        const [name, key] = String(sub.stream).split("@");
        if (name === "order-book" || name === "trades") sids.set(sub.sid, Number(key)); else broadcast.add(sub.sid);
      }
      return;
    }
    remember(frame, text);
    if (frame.mt === 9 || frame.mt === 100) { for (const set of subscribers.values()) for (const fn of set) fn(text); return; }
    const market = sids.get(frame.sid);
    if (market == null) return;
    for (const fn of subscribers.get(market) ?? []) fn(text);
  });
  socket.addEventListener("close", () => { socket = null; sids.clear(); broadcast.clear(); if (subscribers.size) retry(); });
  socket.addEventListener("error", () => { try { socket?.close(); } catch {} });
}

function retry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(() => { retryTimer = null; if (subscribers.size) open(); }, retryMs);
  retryMs = Math.min(RETRY_MAX_MS, retryMs * 2);
}

function send(subs) {
  if (socket?.readyState === 1 && subs.length) socket.send(JSON.stringify({ mt: 5, subs }));
}

/// Streams market `id`'s book and trades, plus every market's state, to `onFrame` as the raw
/// JSON text Perpl sent. The returned function stops it.
export function subscribe(id, onFrame) {
  let set = subscribers.get(id);
  if (!set) {
    set = new Set();
    subscribers.set(id, set);
    send([{ stream: `order-book@${id}`, subscribe: true }, { stream: `trades@${id}`, subscribe: true }]);
  }
  set.add(onFrame);
  open();
  // What the hub already holds goes first: the state of every market, this market's book
  // as it stands, and its last trades, so a late reader starts where the socket is.
  if (lastState) onFrame(lastState);
  const snapshot = snapshotText(id);
  if (snapshot) onFrame(snapshot);
  if (trades.has(id)) onFrame(trades.get(id));
  return () => {
    set.delete(onFrame);
    if (set.size) return;
    subscribers.delete(id);
    send([{ stream: `order-book@${id}`, subscribe: false }, { stream: `trades@${id}`, subscribe: false }]);
    for (const [sid, market] of sids) if (market === id) sids.delete(sid);
    books.delete(id); trades.delete(id);
    if (!subscribers.size) { clearTimeout(retryTimer); retryTimer = null; try { socket?.close(); } catch {} socket = null; }
  };
}

export const streamState = () => ({ connected: socket?.readyState === 1, markets: [...subscribers.keys()], listeners: [...subscribers.values()].reduce((n, s) => n + s.size, 0) });
