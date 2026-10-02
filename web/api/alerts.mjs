import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import { apnsClient, isDeadToken } from "./_apns.mjs";
import { hypersyncClient, indexToken, indexWithLock } from "./_history.mjs";
import { TRACKED_KEY, URGENT_KEY, WATCHED_KEY, ledgerKey } from "./_ledger.mjs";
import { createMarkets } from "./_markets.mjs";
import { MAX_TARGETS, parseTargets, priceDeliveries } from "./_prices.mjs";
import { clientIp } from "./_ratelimit.mjs";
import { CURSOR_TTL_S, HYPERSYNC_URLS, RX_KEY, faucetSender, parseMe, receiptScan, skipList } from "./_receipts.mjs";
import { redisStore } from "./_store.mjs";
import {
  DEFAULT_MIN_USD, DIGEST_WINDOW_S, MAX_WALLETS, MOVES_KEPT, MOVES_TTL_S, WALLET_PUSH_CAP, movesKey, newestMarker, seenKey,
  walletCountKey, walletDigestKey, walletEvents, walletPayload,
} from "./_watch.mjs";
import { isSolanaAddress } from "./_chains.mjs";
import { chainReader, describePosition, noAccount, openMarkets, perpIdsFromBitmap } from "./traders.mjs";

export const MAX_TRADERS = 20 + MAX_WALLETS;
const MAX_COPIED = 20;
export const WAITLIST_KEY = "waitlist:emails";
export const MAX_SUBSCRIPTIONS = 5_000;
const MAX_SCANNED = 300;
/// Background wakes per phone per hour: iOS throttles silent pushes, so a flood costs the useful ones.
export const WAKE_CAP = 12;
export const wakeCountKey = (id, hour) => `alerts:wakes:${id}:${hour}`;
const MAX_EVENTS_PER_TRADER = 4;
const SUBSCRIPTION_TTL = 60 * 24 * 3600;
// Freshness comes from `at`; the key outlives an outage so a held book is never re-sent as opens.
const SNAPSHOT_TTL = 7 * 86400;
const SNAPSHOT_FRESH_MS = 20 * 60_000;
const SNAPSHOT_REFRESH_MS = 5 * 60_000;
const SEEN_TTL = 30 * 24 * 3600;
const ROUND_INTERVAL_MS = 14_000;
const MAX_ROUNDS = 4;
const SUBSCRIPTIONS = "alerts:subs";

const subscriptionKey = (id) => `alerts:sub:${id}`;
// {at, book} lives under a new prefix: the previous deployment reads alerts:snap: as a bare book.
const snapshotKey = (address) => `alerts:snap2:${address}`;

export const subscriptionId = (install) => createHash("sha256").update(`desk-alerts:${install}`).digest("hex");

const validAddress = (value) => typeof value === "string" && /^0x[a-fA-F0-9]{40}$/.test(value);

export function parseSubscription(body) {
  if (!body || typeof body !== "object") return { error: "A JSON body is required." };
  const { install, token, environment, traders, names, copying, wallets, prices, priceMarkets, targets } = body;
  if (typeof install !== "string" || !/^[0-9a-f]{64}$/.test(install)) return { error: "A valid install secret is required." };
  if (typeof token !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(token)) return { error: "A valid device token is required." };
  if (!Array.isArray(traders) || traders.length > MAX_TRADERS || !traders.every(validAddress)) {
    return { error: `Up to ${MAX_TRADERS} trader addresses are allowed.` };
  }
  if (copying != null && (!Array.isArray(copying) || copying.length > MAX_COPIED || !copying.every(validAddress))) {
    return { error: `Up to ${MAX_COPIED} copied addresses are allowed.` };
  }
  const own = parseMe(body.me);
  if (own.error) return { error: own.error };
  const watched = priceMarkets == null ? [] : parseMarkets(priceMarkets);
  if (!watched) return { error: "priceMarkets must be up to 20 market symbols." };
  const tracked = wallets == null ? [] : parseWallets(wallets);
  if (!tracked) return { error: `Up to ${MAX_WALLETS} tracked wallets are allowed, each with an address, an optional name and a minimum in dollars.` };
  const wanted = parseTargets(targets);
  if (!wanted) return { error: `Up to ${MAX_TARGETS} price targets are allowed, each with a market, a price and a direction.` };
  const followed = [...new Set(traders.map((address) => address.toLowerCase()))];
  const copied = [...new Set((copying ?? []).map((address) => address.toLowerCase()))];
  const labels = {};
  if (names && typeof names === "object") {
    for (const address of followed) {
      const name = names[address] ?? names[traders.find((entry) => entry.toLowerCase() === address)];
      if (typeof name === "string" && name.trim()) labels[address] = name.trim().slice(0, 24);
    }
  }
  return {
    id: subscriptionId(install),
    record: {
      token: token.toLowerCase(),
      environment: environment === "production" ? "production" : "sandbox",
      traders: followed,
      copying: copied,
      names: labels,
      wallets: tracked,
      prices: prices !== false,
      priceMarkets: watched,
      targets: wanted,
      me: own.me,
      moves: Number.isSafeInteger(body.moves) && body.moves > 0 ? body.moves : 0,
    },
    wantsPrices: prices === true || wanted.length > 0,
  };
}

function parseMarkets(markets) {
  if (!Array.isArray(markets) || markets.length > 20) return null;
  const out = [];
  for (const entry of markets) {
    if (typeof entry !== "string" || !/^[A-Za-z0-9]{1,12}$/.test(entry)) return null;
    const symbol = entry.toUpperCase();
    if (!out.includes(symbol)) out.push(symbol);
  }
  return out;
}

function parseWallets(wallets) {
  if (!Array.isArray(wallets) || wallets.length > MAX_WALLETS) return null;
  const out = [];
  const seen = new Set();
  for (const entry of wallets) {
    if (!entry || typeof entry !== "object") return null;
    if (isSolanaAddress(entry.address)) continue;
    if (!validAddress(entry.address)) return null;
    const { name, minUsd, firstBuysOnly } = entry;
    if (name != null && typeof name !== "string") return null;
    if (minUsd != null && (typeof minUsd !== "number" || !Number.isFinite(minUsd) || minUsd < 0)) return null;
    if (firstBuysOnly != null && typeof firstBuysOnly !== "boolean") return null;
    const address = entry.address.toLowerCase();
    if (seen.has(address)) continue;
    seen.add(address);
    out.push({
      address,
      name: typeof name === "string" && name.trim() ? name.trim().slice(0, 24) : null,
      minUsd: minUsd ?? DEFAULT_MIN_USD,
      firstBuysOnly: firstBuysOnly === true,
    });
  }
  return out;
}

export function wakePayload(address, event) {
  const { position } = event;
  return {
    aps: { "content-available": 1 },
    desk: { type: "wake", event: event.kind, trader: address, market: position.market, marketId: position.marketId },
  };
}

export function tradeEvents(before, after) {
  const events = [];
  for (const [id, now] of Object.entries(after)) {
    const was = before[id];
    if (!was) events.push({ kind: "opened", position: now });
    else if (was.side !== now.side) events.push({ kind: "flipped", position: now, previous: was });
    else if (Number(was.size) > 0 && Number(now.size) >= Number(was.size) * 1.1) events.push({ kind: "added", position: now, previous: was });
    else if (Number(now.size) > 0 && Number(now.size) <= Number(was.size) * 0.75) events.push({ kind: "reduced", position: now, previous: was });
  }
  for (const [id, was] of Object.entries(before)) {
    if (!after[id]) events.push({ kind: "closed", position: was });
  }
  return events;
}

export function compactDollars(text) {
  const value = Math.abs(Number(text));
  if (!Number.isFinite(value)) return "$—";
  const sign = Number(text) < 0 ? "−" : "";
  if (value >= 1e6) return `${sign}$${(value / 1e6).toFixed(1)}M`;
  if (value >= 1e4) return `${sign}$${Math.round(value / 1e3)}K`;
  if (value >= 1e3) return `${sign}$${(value / 1e3).toFixed(1)}K`;
  return `${sign}$${value.toFixed(value >= 100 ? 0 : 2)}`;
}

export function priceText(text) {
  const value = Number(text);
  if (!Number.isFinite(value)) return String(text);
  const places = value >= 100 ? 2 : value >= 1 ? 4 : 6;
  return `$${value.toLocaleString("en-US", { maximumFractionDigits: places })}`;
}

const leverageText = (value) => (value == null ? "" : `${Number.isInteger(value) ? value : value.toFixed(1)}×`);
const shortAddress = (address) => `${address.slice(0, 6)}…${address.slice(-4)}`;

const lockToken = () => randomBytes(16).toString("hex");

/// Releases a lock only if this run still holds it, so an overrun cannot delete the next run's lock.
async function release(store, key, token) {
  try {
    if (await store.get(key) === token) await store.del(key);
  } catch {
  }
}

export function alertPayload(address, name, event) {
  const who = name || shortAddress(address);
  const { position } = event;
  const side = position.side;
  const lev = leverageText(position.leverage);
  let title;
  let body;
  switch (event.kind) {
    case "opened":
      title = `${who} opened a ${side}`;
      body = `${position.market} ${lev} at ${priceText(position.entry)}, ${compactDollars(position.value)} position. Tap to copy.`;
      break;
    case "flipped":
      title = `${who} flipped ${side} on ${position.market}`;
      body = `Now ${lev} ${side} at ${priceText(position.entry)}, ${compactDollars(position.value)} position. Tap to copy.`;
      break;
    case "added":
      title = `${who} added to their ${position.market} ${side}`;
      body = `${compactDollars(event.previous.value)} → ${compactDollars(position.value)} at ${lev}. Tap to copy.`;
      break;
    case "reduced":
      title = `${who} trimmed their ${position.market} ${side}`;
      body = `${compactDollars(event.previous.value)} → ${compactDollars(position.value)}${lev ? ` at ${lev}` : ""}.`;
      break;
    default:
      title = `${who} closed their ${position.market} ${side}`;
      body = `Entered at ${priceText(position.entry)}. Last seen at ${compactDollars(position.pnl)} open PnL.`;
  }
  const quiet = event.kind === "closed" || event.kind === "reduced";
  return {
    aps: {
      alert: { title, body },
      sound: "default",
      "thread-id": `trader-${address}`,
      category: quiet ? "desk.trade.closed" : "desk.trade",
      "relevance-score": quiet ? 0.4 : 0.8,
    },
    desk: {
      type: "trade",
      event: event.kind,
      trader: address,
      market: position.market,
      marketId: position.marketId,
      side,
      leverage: position.leverage,
      entry: position.entry,
      value: position.value,
      ...(event.previous ? { previousValue: event.previous.value } : {}),
      observedAt: Date.now(),
    },
  };
}

const VERBS = { opened: "opened", flipped: "flipped", added: "added to", reduced: "trimmed", closed: "closed" };
const andList = (items) => (items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`);

export function movesSentence(events, limit = 4) {
  const groups = new Map();
  let listed = 0;
  let more = false;
  for (const { kind, position } of events) {
    const markets = groups.get(kind) ?? [];
    if (markets.includes(position.market)) continue;
    if (listed === limit) { more = true; continue; }
    markets.push(position.market);
    groups.set(kind, markets);
    listed += 1;
  }
  const parts = [...groups];
  if (more) parts.at(-1)[1].push("more");
  const text = parts.map(([kind, markets]) => `${VERBS[kind] ?? kind} ${andList(markets)}`).join(", ");
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}.`;
}

export function summaryPayload(address, name, events) {
  const who = name || shortAddress(address);
  return {
    aps: {
      alert: { title: `${who} made ${events.length} more moves`, body: movesSentence(events) },
      sound: "default",
      "thread-id": `trader-${address}`,
      category: "desk.trade.closed",
      "relevance-score": 0.4,
    },
    desk: {
      type: "trade", event: "summary", trader: address, count: events.length,
      markets: [...new Set(events.map((event) => event.position.market))], observedAt: Date.now(),
    },
  };
}

export const feedRow = (address, event, time) => ({
  wallet: address, venue: "perpl", time, kind: event.kind, market: event.position.market, marketId: event.position.marketId,
  side: event.position.side, leverage: event.position.leverage ?? null, entry: event.position.entry ?? null,
  value: event.position.value ?? null, previousValue: event.previous?.value ?? null,
});

export const NO_ACCOUNT = Object.freeze({});

/// One trader's book, keyed by market, or null when it could not be read. An unreadable
/// book is never treated as empty, because that would announce closes that did not happen.
export async function readBook(chain, markets, address) {
  let account;
  try {
    account = await chain.accountByAddress(address);
  } catch (error) {
    if (noAccount(error)) return NO_ACCOUNT;
    throw error;
  }
  if (!account || account.accountId === 0n) return null;
  const ids = perpIdsFromBitmap(account.positions).filter((id) => markets.has(id));
  const found = await Promise.all(ids.map((id) => chain.openPosition(id, account.accountId)));
  const book = {};
  found.forEach((entry, index) => {
    if (!entry) return;
    const described = describePosition(entry.row, entry.mark, markets.get(ids[index]));
    book[ids[index]] = {
      market: described.market,
      marketId: described.marketId,
      side: described.side,
      size: described.size,
      entry: described.entry,
      value: described.value,
      pnl: described.pnl,
      leverage: described.leverage,
    };
  });
  return book;
}

export function shareBudget(followers, budget) {
  const queues = new Map();
  for (const [address, watchers] of followers) {
    for (const watcher of watchers) {
      if (!queues.has(watcher.id)) queues.set(watcher.id, []);
      queues.get(watcher.id).push(address);
    }
  }
  const chosen = new Set();
  const lists = [...queues.values()];
  for (let rank = 0; chosen.size < budget; rank += 1) {
    let reached = false;
    for (const list of lists) {
      if (rank >= list.length) continue;
      reached = true;
      chosen.add(list[rank]);
      if (chosen.size >= budget) break;
    }
    if (!reached) break;
  }
  return [...chosen];
}

async function inBatches(items, size, work) {
  const out = [];
  for (let index = 0; index < items.length; index += size) {
    out.push(...await Promise.all(items.slice(index, index + size).map(work)));
  }
  return out;
}

export async function withinWakeBudget(store, id, now = Date.now()) {
  const hour = Math.floor(now / 3_600_000);
  const count = await store.incr(wakeCountKey(id, hour));
  if (count === 1) await store.expire(wakeCountKey(id, hour), 3600);
  return count <= WAKE_CAP;
}

async function walletDeliveries({ store, watchers, now }) {
  const addresses = [...watchers.keys()];
  if (addresses.length === 0) return { deliveries: [], markers: [], events: 0 };
  const [ledgers, seen] = await Promise.all([
    store.mget(addresses.map(ledgerKey)),
    store.mget(addresses.map(seenKey)),
  ]);
  const markers = [];
  const deliveries = [];
  const perSubscription = new Map();
  let events = 0;
  addresses.forEach((address, index) => {
    if (!ledgers[index]) return;
    const ledger = JSON.parse(ledgers[index]);
    const marker = JSON.stringify(newestMarker(ledger));
    if (marker !== seen[index]) markers.push([seenKey(address), marker]);
    if (seen[index] == null) return;
    const previous = JSON.parse(seen[index]);
    for (const { id, record, wallet } of watchers.get(address)) {
      const found = walletEvents(previous, ledger, { minUsd: wallet.minUsd, firstBuysOnly: wallet.firstBuysOnly });
      if (found.length === 0) continue;
      events += found.length;
      const bucket = perSubscription.get(id) ?? { record, wallets: new Set(), pending: [] };
      bucket.wallets.add(address);
      for (const event of found) bucket.pending.push({ wallet, event });
      perSubscription.set(id, bucket);
    }
  });

  const hour = Math.floor(now / 3_600_000);
  for (const [id, { record, wallets, pending }] of perSubscription) {
    let capped = false;
    for (const { wallet, event } of pending) {
      const count = await store.incr(walletCountKey(id, hour));
      if (count === 1) await store.expire(walletCountKey(id, hour), 3600);
      if (count > WALLET_PUSH_CAP) { capped = true; continue; }
      deliveries.push({ id, record, payload: walletPayload(record, wallet, event),
        collapseId: `w-${wallet.address.slice(2, 14)}-${String(event.token).slice(2, 10)}-${event.kind}` });
    }
    if (capped && await store.set(walletDigestKey(id), "1", { ex: DIGEST_WINDOW_S, nx: true })) {
      deliveries.push({ id, record, payload: walletPayload(record, null, { kind: "digest", count: wallets.size }), collapseId: "w-digest" });
    }
  }
  return { deliveries, markers, events };
}

function storedBook(raw) {
  if (raw == null) return null;
  let value;
  try { value = JSON.parse(raw); } catch { return null; }
  return value && Number.isFinite(value.at) && value.book && typeof value.book === "object" ? value : null;
}

const PRIORITY = { opened: 0, flipped: 1, added: 2, closed: 3, reduced: 4 };
const byPriority = (events) => [...events].sort((a, b) => PRIORITY[a.kind] - PRIORITY[b.kind]);

const shape = (book) => JSON.stringify(Object.entries(book).map(([id, position]) => [id, position.side, position.size]));

const sentCount = (results, deliveries, part) =>
  results.filter((result, index) => deliveries[index].part === part && result.status === 200).length;

export async function scan({
  store, chain, apns, markets, quotes = [], sources = {}, skip = skipList(), receiptTimeoutMs, now = Date.now(),
}) {
  const ids = await store.smembers(SUBSCRIPTIONS);
  if (ids.length === 0) {
    return { subscriptions: 0, traders: 0, sent: 0, wallets: { watched: 0, events: 0, sent: 0 }, prices: { events: 0, sent: 0 }, receipts: { events: 0, sent: 0 } };
  }

  const records = await store.mget([...ids.map(subscriptionKey), RX_KEY]);
  const rxCursor = records.pop();
  const expired = [];
  const followers = new Map();
  const watchers = new Map();
  const everyone = [];
  ids.forEach((id, index) => {
    if (!records[index]) return expired.push(id);
    const record = JSON.parse(records[index]);
    everyone.push({ id, record });
    // Copied first: money moves on those, so they take the subscription's share before alerts.
    for (const address of new Set([...(record.copying ?? []), ...record.traders])) {
      followers.set(address, [...(followers.get(address) ?? []), { id, record }]);
    }
    for (const wallet of record.wallets ?? []) {
      watchers.set(wallet.address, [...(watchers.get(wallet.address) ?? []), { id, record, wallet }]);
    }
  });

  const errors = [];
  const report = (part) => (error) => { errors.push(`${part}: ${error?.message ?? error}`); };
  const receipts = receiptScan({ sources, skip, subscribers: everyone, stored: rxCursor, now, timeoutMs: receiptTimeoutMs })
    .catch((error) => { report("receipts")(error); return { deliveries: [], events: 0, errors: [] }; });

  await store.srem(SUBSCRIPTIONS, ...expired);
  await store.set(WATCHED_KEY, JSON.stringify([...watchers.keys()]), { ex: 900 }).catch(() => {});

  const addresses = shareBudget(followers, MAX_SCANNED);
  const previous = await store.mget(addresses.map(snapshotKey));
  const books = await inBatches(addresses, 20, (address) => readBook(chain, markets, address).catch(() => null));

  const snapshots = [];
  const moves = [];
  const deliveries = [];
  const wakes = [];
  addresses.forEach((address, index) => {
    const book = books[index];
    if (!book) return;
    const stored = storedBook(previous[index]);
    // Whatever its age: a stale book with positions must not become an empty baseline on a misread revert.
    if (book === NO_ACCOUNT && stored && Object.keys(stored.book).length) return;
    const before = stored && now - stored.at < SNAPSHOT_FRESH_MS ? stored : null;
    if (!before || shape(before.book) !== shape(book) || now - before.at >= SNAPSHOT_REFRESH_MS) {
      snapshots.push([snapshotKey(address), JSON.stringify({ at: now, book })]);
    }
    if (!before) return;
    const events = byPriority(tradeEvents(before.book, book));
    if (events.length === 0) return;
    moves.push({ address, events });
    const told = events.length > MAX_EVENTS_PER_TRADER ? events.slice(0, MAX_EVENTS_PER_TRADER - 1) : events;
    const classic = events.filter((event) => event.kind !== "reduced").slice(0, MAX_EVENTS_PER_TRADER);
    for (const { id, record } of followers.get(address)) {
      if (record.traders.includes(address)) {
        // Builds that send moves: 2 handle trims and the summary; older ones keep the first four other moves.
        const current = record.moves >= 2;
        for (const event of current ? told : classic) {
          deliveries.push({ id, record, part: "traders", payload: alertPayload(address, record.names?.[address], event),
            collapseId: `${address.slice(2, 14)}-${event.position.marketId}-${event.kind}` });
        }
        if (current && told.length < events.length) {
          deliveries.push({ id, record, part: "traders", payload: summaryPayload(address, record.names?.[address], events.slice(told.length)),
            collapseId: `${address.slice(2, 14)}-summary` });
        }
      }
      if (!record.copying?.includes(address)) continue;
      for (const event of classic) {
        if (event.kind === "added") continue;
        wakes.push({ id, record, part: "traders", payload: wakePayload(address, event),
          collapseId: `wake-${address.slice(2, 14)}`, background: true });
      }
    }
  });
  for (const wake of wakes) {
    if (await withinWakeBudget(store, wake.id, now).catch(() => true)) deliveries.push(wake);
  }

  let feed = [];
  if (moves.length) {
    const stored = await store.mget(moves.map(({ address }) => movesKey(address))).catch(report("moves"));
    if (stored) {
      feed = moves.map(({ address, events }, index) => {
        let kept = [];
        try { kept = JSON.parse(stored[index] ?? "[]"); } catch {}
        const rows = events.map((event) => feedRow(address, event, now));
        return [movesKey(address), JSON.stringify([...rows, ...(Array.isArray(kept) ? kept : [])].slice(0, MOVES_KEPT)), MOVES_TTL_S];
      });
    }
  }
  const rx = await receipts;
  const cursor = rx.due ? [[RX_KEY, JSON.stringify(rx.next), CURSOR_TTL_S]] : [];
  // One write before any send: a scan cut off mid-delivery never repeats a push, one that fails here loses nothing.
  await store.setMany([...snapshots, ...feed, ...cursor], SNAPSHOT_TTL);
  errors.push(...rx.errors);
  deliveries.push(...rx.deliveries.map((delivery) => ({ ...delivery, part: "receipts" })));

  const tracked = await walletDeliveries({ store, watchers, now })
    .then(async (found) => { await store.setMany(found.markers, SEEN_TTL); return found; })
    .catch((error) => { report("wallets")(error); return { deliveries: [], events: 0 }; });
  deliveries.push(...tracked.deliveries.map((delivery) => ({ ...delivery, part: "wallets" })));

  const priced = await priceDeliveries({ store, quotes, subscribers: everyone, now })
    .catch((error) => { report("prices")(error); return { deliveries: [], events: 0, changed: [] }; });
  deliveries.push(...priced.deliveries.map((delivery) => ({ ...delivery, part: "prices" })));

  const results = await inBatches(deliveries, 10, ({ record, payload, collapseId, background }) =>
    apns.send(record, payload, { collapseId, background }));

  const dead = new Set();
  const moved = new Map();
  results.forEach((result, index) => {
    const { id, record } = deliveries[index];
    if (isDeadToken(result)) dead.add(id);
    else if (result.status === 200 && result.environment !== record.environment) moved.set(id, { ...record, environment: result.environment });
  });
  for (const id of dead) {
    await store.del(subscriptionKey(id));
    await store.srem(SUBSCRIPTIONS, id);
  }
  // A fired target is forgotten first, so the environment write below keeps the shorter list.
  for (const [id, record] of priced.changed) {
    if (!dead.has(id) && !moved.has(id)) await store.set(subscriptionKey(id), JSON.stringify(record), { ex: SUBSCRIPTION_TTL });
  }
  for (const [id, record] of moved) {
    if (!dead.has(id)) await store.set(subscriptionKey(id), JSON.stringify(record), { ex: SUBSCRIPTION_TTL });
  }
  return {
    subscriptions: ids.length - expired.length,
    traders: addresses.length,
    sent: results.filter((result) => result.status === 200).length,
    failed: results.filter((result) => result.status !== 200).length,
    wallets: { watched: watchers.size, events: tracked.events, sent: sentCount(results, deliveries, "wallets") },
    prices: { events: priced.events, sent: sentCount(results, deliveries, "prices") },
    receipts: { events: rx.events, sent: sentCount(results, deliveries, "receipts") },
    ...(errors.length ? { errors } : {}),
  };
}

const DEPOSITS_ON = { title: "Deposit alerts are on", body: "You'll hear when MON or AUSD lands in your Desk wallet." };

function confirmationAlert(record) {
  const first = record.traders[0];
  const copied = record.copying.length;
  const tracked = record.wallets;
  if (first) {
    const who = record.names[first] || shortAddress(first);
    return {
      title: "Trade alerts are on",
      body: record.traders.length === 1
        ? `You'll hear the moment ${who} opens, adds to or closes a position.`
        : `You'll hear the moment any of your ${record.traders.length} traders opens, adds to or closes a position.`,
    };
  }
  if (copied) return { title: "Away copying is on", body: `Desk will wake to copy ${copied === 1 ? "your trader" : `your ${copied} traders`} while it's closed.` };
  if (record.me) return DEPOSITS_ON;
  if (tracked.length) {
    return {
      title: "Wallet alerts are on",
      body: tracked.length === 1
        ? `You'll hear when ${tracked[0].name || shortAddress(tracked[0].address)} trades on ${isSolanaAddress(tracked[0].address) ? "Solana" : "Monad"}.`
        : `You'll hear when any of your ${tracked.length} tracked wallets trades.`,
    };
  }
  return { title: "Price alerts are on", body: "You'll hear when Bitcoin, Monad or a market on your watchlist breaks a level or moves 5% in a day." };
}

function authorized(req, secret) {
  if (!secret) return false;
  const header = String(req.headers?.authorization ?? "");
  const expected = Buffer.from(`Bearer ${secret}`);
  const given = Buffer.from(header);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

function safeJSON(text) {
  try { return JSON.parse(text); } catch { return null; }
}

const UNREACHABLE = "This iPhone couldn't be reached by Apple, so alerts weren't saved.";

export function createHandler(resolve) {
  return async function handler(req, res) {
    const deps = resolve();
    if (req.query?.job === "index") {
      if (!authorized(req, deps.secret)) return res.status(401).json({ error: "Unauthorized." });
      if (!deps.store || !deps.hypersync) return res.status(503).json({ error: "History indexing isn't configured on this server." });
      try {
        const report = await indexWithLock({
          store: deps.store, hypersync: deps.hypersync, markets: await deps.markets(), budgetMs: 40_000, lockSeconds: 58,
        });
        return res.status(report.skipped ? 202 : 200).json(report);
      } catch (error) {
        return res.status(502).json({ error: "History could not be indexed.", detail: String(error?.message ?? error) });
      }
    }

    if (!deps.store || !deps.apns) return res.status(503).json({ error: "Trade alerts aren't configured on this server." });
    const { store, apns } = deps;

    if (req.query?.job === "scan") {
      if (!authorized(req, deps.secret)) return res.status(401).json({ error: "Unauthorized." });
      const scanToken = lockToken();
      if (!await store.set("alerts:lock", scanToken, { ex: 90, nx: true })) return res.status(202).json({ skipped: true });
      const rounds = Math.min(MAX_ROUNDS, Math.max(1, Number(req.query.rounds ?? MAX_ROUNDS) || 1));
      const reports = [];
      try {
        const markets = await deps.markets();
        for (let round = 0; round < rounds; round += 1) {
          if (round > 0) await deps.sleep(ROUND_INTERVAL_MS);
          const quotes = deps.quotes ? await deps.quotes().catch(() => []) : [];
          const report = await scan({ store, chain: deps.chain, apns, markets, quotes, sources: deps.receipts, skip: deps.skip });
          reports.push(report);
          if (report.subscriptions === 0) break;
        }
        await store.set("alerts:lastScan", new Date().toISOString(), { ex: 7 * 86400 }).catch(() => {});
        return res.status(200).json({ rounds: reports });
      } catch {
        return res.status(502).json({ error: "The scan could not finish.", rounds: reports });
      } finally {
        apns.close();
        await release(store, "alerts:lock", scanToken);
      }
    }

    if (req.query?.job === "waitlist") {
      if (!authorized(req, deps.secret)) return res.status(401).json({ error: "Unauthorized." });
      const emails = (await store.smembers(WAITLIST_KEY)).sort();
      return res.status(200).json({ count: emails.length, emails });
    }

    if (req.method !== "POST") return res.status(405).json({ error: "POST required" });
    const body = typeof req.body === "string" ? safeJSON(req.body) : req.body;

    if (body?.action === "waitlist") {
      const email = String(body.email ?? "").trim().toLowerCase();
      if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
        return res.status(400).json({ error: "That doesn't look like an email address." });
      }
      const ip = clientIp(req.headers);
      const attempts = await store.incr(`waitlist:ip:${ip}`);
      if (attempts === 1) await store.expire(`waitlist:ip:${ip}`, 3600);
      if (attempts > 20) return res.status(429).json({ error: "Too many sign-ups from here. Try again later." });
      const added = await store.sadd(WAITLIST_KEY, email);
      if (added) await store.set(`waitlist:at:${email}`, new Date().toISOString(), { ex: 400 * 86400 }).catch(() => {});
      return res.status(200).json({ joined: true, already: !added });
    }

    if (body?.action === "unsubscribe") {
      if (typeof body.install !== "string" || !/^[0-9a-f]{64}$/.test(body.install)) {
        return res.status(400).json({ error: "A valid install secret is required." });
      }
      const id = subscriptionId(body.install);
      await store.del(subscriptionKey(id));
      await store.srem(SUBSCRIPTIONS, id);
      return res.status(200).json({ traders: 0 });
    }

    const parsed = parseSubscription(body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const { id, record, wantsPrices } = parsed;

    if (record.traders.length === 0 && record.copying.length === 0 && record.wallets.length === 0 && record.targets.length === 0
        && !wantsPrices && !record.me) {
      await store.del(subscriptionKey(id));
      await store.srem(SUBSCRIPTIONS, id);
      return res.status(200).json({ traders: 0 });
    }
    const known = await store.get(subscriptionKey(id));
    if (!known && await store.scard(SUBSCRIPTIONS) >= MAX_SUBSCRIPTIONS) {
      return res.status(503).json({ error: "Trade alerts are full right now." });
    }

    // A first registration is only written once Apple has accepted a push for that token,
    // so each seat costs an attacker a real device.
    let confirmed = false;
    let environment = record.environment;
    const depositsOn = Boolean(known) && Boolean(record.me) && !safeJSON(known)?.me;
    if ((!known || depositsOn) && await store.set(`alerts:confirm:${id}`, "1", { ex: 60, nx: true })) {
      const result = await apns.send(record, {
        aps: { alert: depositsOn ? DEPOSITS_ON : confirmationAlert(record), sound: "default" },
        desk: { type: "confirmation" },
      });
      apns.close();
      confirmed = result.status === 200;
      if (confirmed) environment = result.environment ?? environment;
      else console.warn(`alerts: confirmation refused, ${result.status || "no answer"} ${result.reason ?? ""} (${result.environment})`);
      if (!confirmed && !known) {
        await store.set(`alerts:confirm:${id}`, "failed", { ex: 60 }).catch(() => {});
        return res.status(400).json({ error: UNREACHABLE });
      }
    } else if (!known) {
      // A follow and a bell tap sync seconds apart; wait for the first to confirm rather than refuse.
      if (await store.get(`alerts:confirm:${id}`) === "failed") return res.status(400).json({ error: UNREACHABLE });
      let settled = null;
      for (let attempt = 0; attempt < 10 && !settled; attempt += 1) {
        await deps.sleep(500);
        settled = await store.get(subscriptionKey(id));
      }
      if (!settled) return res.status(429).json({ error: "Trade alerts are still being set up. Try again in a moment." });
    }

    await store.set(subscriptionKey(id), JSON.stringify({ ...record, environment }), { ex: SUBSCRIPTION_TTL });
    await store.sadd(SUBSCRIPTIONS, id);
    for (const wallet of record.wallets) {
      await store.sadd(TRACKED_KEY, wallet.address);
      await store.sadd(URGENT_KEY, wallet.address);
    }
    return res.status(200).json({
      traders: record.traders.length, ...(record.wallets.length ? { wallets: record.wallets.length } : {}),
      ...(record.targets.length ? { targets: record.targets } : {}), confirmed,
    });
  };
}

let production;
export default createHandler(() => (production ??= {
  store: redisStore(),
  apns: apnsClient(),
  hypersync: hypersyncClient({ token: indexToken() }),
  receipts: {
    mainnet: hypersyncClient({ token: indexToken(), url: HYPERSYNC_URLS.mainnet }),
    testnet: hypersyncClient({ token: indexToken(), url: HYPERSYNC_URLS.testnet }),
  },
  skip: skipList([faucetSender()]),
  chain: chainReader(),
  markets: () => openMarkets(),
  quotes: (() => {
    let source = null;
    // Marks off the exchange contract, so a level is crossed when the venue says so.
    return async () => {
      source ??= createMarkets();
      const [{ markets: rows }, { marks }] = await Promise.all([source.context(), source.marks()]);
      return rows.map((row) => ({ name: row.name, mark: marks[row.name] ?? row.mark, prev: row.prev }));
    };
  })(),
  secret: process.env.CRON_SECRET,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}));
