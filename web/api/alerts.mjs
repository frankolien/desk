import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import { apnsClient, isDeadToken } from "./_apns.mjs";
import { hypersyncClient, indexHistory } from "./_history.mjs";
import { redisStore } from "./_store.mjs";
import { chainReader, describePosition, openMarkets, perpIdsFromBitmap } from "./traders.mjs";

/// Trade alerts for followed traders.
///
/// The phone registers which traders it wants to hear about and where to deliver; a
/// scheduler calls the scan, which reads those traders' open positions on Perpl mainnet,
/// compares them with the last reading and pushes what changed. Nothing here can trade:
/// copying still happens on the phone, with the person's own key and Face ID.
///
/// A subscription is keyed by a hash of a secret only the phone holds, so nobody who
/// learns a device token or a followed address can read or rewrite someone's alerts.

export const MAX_TRADERS = 20;
export const MAX_SUBSCRIPTIONS = 5_000;
const MAX_SCANNED = 300;
const MAX_EVENTS_PER_TRADER = 4;
const SUBSCRIPTION_TTL = 60 * 24 * 3600;
const SNAPSHOT_TTL = 7 * 24 * 3600;
const ROUND_INTERVAL_MS = 14_000;
const MAX_ROUNDS = 4;
const SUBSCRIPTIONS = "alerts:subs";

const subscriptionKey = (id) => `alerts:sub:${id}`;
const snapshotKey = (address) => `alerts:snap:${address}`;

export const subscriptionId = (install) => createHash("sha256").update(`desk-alerts:${install}`).digest("hex");

const validAddress = (value) => typeof value === "string" && /^0x[a-fA-F0-9]{40}$/.test(value);

/// The subscription as stored, or the sentence explaining why it was refused.
export function parseSubscription(body) {
  if (!body || typeof body !== "object") return { error: "A JSON body is required." };
  const { install, token, environment, traders, names, copying } = body;
  if (typeof install !== "string" || !/^[0-9a-f]{64}$/.test(install)) return { error: "A valid install secret is required." };
  if (typeof token !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(token)) return { error: "A valid device token is required." };
  if (!Array.isArray(traders) || traders.length > MAX_TRADERS || !traders.every(validAddress)) {
    return { error: `Up to ${MAX_TRADERS} trader addresses are allowed.` };
  }
  if (copying != null && (!Array.isArray(copying) || copying.length > MAX_TRADERS || !copying.every(validAddress))) {
    return { error: `Up to ${MAX_TRADERS} copied addresses are allowed.` };
  }
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
    },
  };
}

/// Wakes the app in the background so the copy loop can take the copy itself. Nothing
/// visible: the alert, if this address is also followed, is a separate push.
export function wakePayload(address, event) {
  const { position } = event;
  return {
    aps: { "content-available": 1 },
    desk: { type: "wake", event: event.kind, trader: address, market: position.market, marketId: position.marketId },
  };
}

/// What a trader did between two readings of their book. Trims are left out: a follower
/// wants to hear about new risk and about exits, not every partial take-profit.
export function tradeEvents(before, after) {
  const events = [];
  for (const [id, now] of Object.entries(after)) {
    const was = before[id];
    if (!was) events.push({ kind: "opened", position: now });
    else if (was.side !== now.side) events.push({ kind: "flipped", position: now });
    else if (Number(now.size) >= Number(was.size) * 1.1) events.push({ kind: "added", position: now, previous: was });
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

/// The notification a follower reads, and the fields the app needs to open the copy.
const lockToken = () => randomBytes(16).toString("hex");

/// Releases a lock only if this run still holds it. A run that overran its lease used to
/// delete the next run's lock on its way out, which let a third run in alongside it.
async function release(store, key, token) {
  try {
    if (await store.get(key) === token) await store.del(key);
  } catch {
    // A lock nobody released expires on its own.
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
    default:
      title = `${who} closed their ${position.market} ${side}`;
      body = `Entered at ${priceText(position.entry)}. Last seen at ${compactDollars(position.pnl)} open PnL.`;
  }
  return {
    aps: {
      alert: { title, body },
      sound: "default",
      "thread-id": `trader-${address}`,
      // The app registers Copy, View and Mute buttons under these; a close offers no Copy.
      category: event.kind === "closed" ? "desk.trade.closed" : "desk.trade",
      "relevance-score": event.kind === "closed" ? 0.4 : 0.8,
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
      observedAt: Date.now(),
    },
  };
}

/// One trader's book, keyed by market, or null when it could not be read. An unreadable
/// book is never treated as empty, because that would announce closes that did not happen.
export async function readBook(chain, markets, address) {
  const account = await chain.accountByAddress(address);
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

/// Each subscription's first address, then each one's second, and so on until the budget is
/// spent. Every subscriber is served before anyone is served twice.
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

export async function scan({ store, chain, apns, markets }) {
  const ids = await store.smembers(SUBSCRIPTIONS);
  if (ids.length === 0) return { subscriptions: 0, traders: 0, sent: 0 };

  const records = await store.mget(ids.map(subscriptionKey));
  const expired = [];
  const followers = new Map();
  ids.forEach((id, index) => {
    if (!records[index]) return expired.push(id);
    const record = JSON.parse(records[index]);
    for (const address of new Set([...record.traders, ...(record.copying ?? [])])) {
      followers.set(address, [...(followers.get(address) ?? []), { id, record }]);
    }
  });
  await store.srem(SUBSCRIPTIONS, ...expired);

  // Round-robin across subscriptions rather than a flat slice: a flat one let fifteen junk
  // subscriptions, twenty addresses each, fill the whole budget and silently stop every real
  // follower's alerts.
  const addresses = shareBudget(followers, MAX_SCANNED);
  const previous = await store.mget(addresses.map(snapshotKey));
  const books = await inBatches(addresses, 20, (address) => readBook(chain, markets, address).catch(() => null));

  const snapshots = [];
  const deliveries = [];
  addresses.forEach((address, index) => {
    const book = books[index];
    if (!book) return;
    snapshots.push([snapshotKey(address), JSON.stringify(book)]);
    // The first reading is the baseline; everything already open is old news.
    if (previous[index] == null) return;
    const events = tradeEvents(JSON.parse(previous[index]), book).slice(0, MAX_EVENTS_PER_TRADER);
    for (const { id, record } of followers.get(address)) {
      for (const event of events) {
        if (record.traders.includes(address)) {
          deliveries.push({ id, record, payload: alertPayload(address, record.names?.[address], event),
            collapseId: `${address.slice(2, 14)}-${event.position.marketId}-${event.kind}` });
        }
        if (record.copying?.includes(address)) {
          deliveries.push({ id, record, payload: wakePayload(address, event),
            collapseId: `wake-${address.slice(2, 14)}`, background: true });
        }
      }
    }
  });
  // Saved before anything is sent, so a scan that dies mid-delivery cannot repeat itself.
  await store.setMany(snapshots, SNAPSHOT_TTL);

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
  for (const [id, record] of moved) {
    if (!dead.has(id)) await store.set(subscriptionKey(id), JSON.stringify(record), { ex: SUBSCRIPTION_TTL });
  }
  return {
    subscriptions: ids.length - expired.length,
    traders: addresses.length,
    sent: results.filter((result) => result.status === 200).length,
    failed: results.filter((result) => result.status !== 200).length,
  };
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

export function createHandler(resolve) {
  return async function handler(req, res) {
    const deps = resolve();
    if (req.query?.job === "index") {
      if (!authorized(req, deps.secret)) return res.status(401).json({ error: "Unauthorized." });
      if (!deps.store || !deps.hypersync) return res.status(503).json({ error: "History indexing isn't configured on this server." });
      const historyToken = lockToken();
      if (!await deps.store.set("hist:lock", historyToken, { ex: 58, nx: true })) return res.status(202).json({ skipped: true });
      try {
        const report = await indexHistory({
          store: deps.store, hypersync: deps.hypersync, markets: await deps.markets(), deadline: Date.now() + 40_000,
        });
        return res.status(200).json(report);
      } catch (error) {
        return res.status(502).json({ error: "History could not be indexed.", detail: String(error?.message ?? error) });
      } finally {
        await release(deps.store, "hist:lock", historyToken);
      }
    }

    if (!deps.store || !deps.apns) return res.status(503).json({ error: "Trade alerts aren't configured on this server." });
    const { store, apns } = deps;

    if (req.query?.job === "scan") {
      if (!authorized(req, deps.secret)) return res.status(401).json({ error: "Unauthorized." });
      // Schedulers overlap when a scan runs long; only one may read and deliver at a time.
      const scanToken = lockToken();
      if (!await store.set("alerts:lock", scanToken, { ex: 90, nx: true })) return res.status(202).json({ skipped: true });
      const rounds = Math.min(MAX_ROUNDS, Math.max(1, Number(req.query.rounds ?? MAX_ROUNDS) || 1));
      const reports = [];
      try {
        const markets = await deps.markets();
        for (let round = 0; round < rounds; round += 1) {
          if (round > 0) await deps.sleep(ROUND_INTERVAL_MS);
          const report = await scan({ store, chain: deps.chain, apns, markets });
          reports.push(report);
          // Nobody to alert: later rounds would only spend commands.
          if (report.subscriptions === 0) break;
        }
        return res.status(200).json({ rounds: reports });
      } catch {
        return res.status(502).json({ error: "The scan could not finish.", rounds: reports });
      } finally {
        apns.close();
        await release(store, "alerts:lock", scanToken);
      }
    }

    if (req.method !== "POST") return res.status(405).json({ error: "POST required" });
    const body = typeof req.body === "string" ? safeJSON(req.body) : req.body;

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
    const { id, record } = parsed;

    // Nothing to follow and nothing to copy is a request to be forgotten.
    if (record.traders.length === 0 && record.copying.length === 0) {
      await store.del(subscriptionKey(id));
      await store.srem(SUBSCRIPTIONS, id);
      return res.status(200).json({ traders: 0 });
    }
    const known = await store.get(subscriptionKey(id));
    if (!known && await store.scard(SUBSCRIPTIONS) >= MAX_SUBSCRIPTIONS) {
      return res.status(503).json({ error: "Trade alerts are full right now." });
    }

    // A subscription nobody can deliver to is not a subscription, it is a seat taken from
    // someone who can. A first registration is only written once Apple has accepted a push
    // for that token, which costs an attacker a real device and a real token per seat.
    // The confirmation the person sees is the same push, so this proves the whole path.
    let confirmed = false;
    let environment = record.environment;
    const announcing = !known || body.confirm === true;
    if (announcing && await store.set(`alerts:confirm:${id}`, "1", { ex: 60, nx: true })) {
      const first = record.traders[0];
      const who = first ? (record.names[first] || shortAddress(first)) : null;
      const copied = record.copying.length;
      const result = await apns.send(record, {
        aps: {
          alert: {
            title: first ? "Trade alerts are on" : "Away copying is on",
            body: !first
              ? `Desk will wake to copy ${copied === 1 ? "your trader" : `your ${copied} traders`} while it's closed.`
              : record.traders.length === 1
                ? `You'll hear the moment ${who} opens, adds to or closes a position.`
                : `You'll hear the moment any of your ${record.traders.length} traders opens, adds to or closes a position.`,
          },
          sound: "default",
        },
        desk: { type: "confirmation" },
      });
      apns.close();
      confirmed = result.status === 200;
      if (confirmed) environment = result.environment ?? environment;
      if (!confirmed && !known) {
        return res.status(400).json({ error: "This iPhone couldn't be reached by Apple, so alerts weren't saved." });
      }
    } else if (!known) {
      // A repeat registration inside the confirmation window, before the first one was
      // written. Nothing is stored on this path either.
      return res.status(429).json({ error: "Trade alerts are still being set up. Try again in a moment." });
    }

    await store.set(subscriptionKey(id), JSON.stringify({ ...record, environment }), { ex: SUBSCRIPTION_TTL });
    await store.sadd(SUBSCRIPTIONS, id);
    return res.status(200).json({ traders: record.traders.length, confirmed });
  };
}

let production;
export default createHandler(() => (production ??= {
  store: redisStore(),
  apns: apnsClient(),
  hypersync: hypersyncClient(),
  chain: chainReader(),
  markets: () => openMarkets(),
  secret: process.env.CRON_SECRET,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}));
