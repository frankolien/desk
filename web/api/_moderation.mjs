/// Reports, hides and blocks for what people write and show in Desk: room messages and
/// the name and picture on a Desk profile.
///
/// A report names a phone (the alerts' install secret, hashed) rather than a wallet, so
/// one person cannot report as many people. Three distinct phones reporting the same
/// message hide it; three hidden messages from one poster in a day block that poster
/// from the rooms. Three phones reporting a profile hide its Desk name and picture, and
/// the wallet falls back to whatever nad, ENS or Farcaster say about it. Every automatic
/// action can be undone, and any action taken, through the moderation route with the
/// cron secret.
import crypto from "node:crypto";

export const REPORT_CAP = 500;
export const AUTO_HIDE_REPORTS = 3;
export const STRIKES_TO_BLOCK = 3;
export const MAX_REASON = 140;
const REPORT_WINDOW_SECONDS = 60;
const REPORT_LIMIT = 5;
const REPORTERS_TTL_SECONDS = 7 * 86_400;
const STRIKE_TTL_SECONDS = 86_400;

const KEYS = {
  hiddenMessages: "mod:hidden:messages",
  blockedWhos: "mod:blocked:whos",
  hiddenProfiles: "mod:hidden:profiles",
  reports: "mod:reports",
  reporters: (kind, target) => `mod:reporters:${kind}:${target}`,
  strikes: (who) => `mod:strikes:${who}`,
  rate: (reporter) => `mod:rate:${reporter}`,
};

const validInstall = (value) => /^[a-f0-9]{64}$/.test(String(value ?? ""));
const validAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(String(value ?? ""));
const validMarket = (value) => /^[A-Z0-9]{2,10}$/.test(String(value ?? ""));
const validID = (value) => /^[a-z0-9]{1,12}-[a-f0-9]{8}$/.test(String(value ?? ""));
const validWho = (value) => /^[a-f0-9]{16}$/.test(String(value ?? ""));

/// Who reported, as a hash the reports list can carry without the secret.
export const reporter = (install) => crypto.createHash("sha256").update(`report:${install}`).digest("hex").slice(0, 16);

export function cleanReason(value) {
  const text = String(value ?? "").replace(/[\u0000-\u001f\u007f\u200b-\u200f\u2028-\u202e]/g, " ").replace(/\s+/g, " ").trim();
  return text.length > MAX_REASON ? text.slice(0, MAX_REASON).trim() : text;
}

async function members(store, key) {
  try { return new Set(await store.smembers(key)); } catch { return new Set(); }
}

export const hiddenMessageIDs = (store) => members(store, KEYS.hiddenMessages);
export const blockedWhos = (store) => members(store, KEYS.blockedWhos);
export const hiddenProfiles = (store) => members(store, KEYS.hiddenProfiles);

export async function isProfileHidden(store, address) {
  if (!store || !validAddress(address)) return false;
  return (await hiddenProfiles(store)).has(String(address).toLowerCase());
}

/// One report in. `kind` is "message" (market + id + who) or "profile" (address).
export async function report(store, { kind, install, market, id, who, address, reason }, now = Date.now()) {
  if (!store) return { status: 503, body: { error: "Reporting is not configured." } };
  if (!validInstall(install)) return { status: 401, body: { error: "This install is not recognised." } };
  const by = reporter(install);

  let target;
  if (kind === "message") {
    const symbol = String(market ?? "").toUpperCase();
    if (!validMarket(symbol) || !validID(id)) return { status: 400, body: { error: "A market and a message are required." } };
    if (who != null && !validWho(who)) return { status: 400, body: { error: "The poster is malformed." } };
    target = `${symbol}:${id}`;
  } else if (kind === "profile") {
    if (!validAddress(address)) return { status: 400, body: { error: "A wallet address is required." } };
    target = String(address).toLowerCase();
  } else {
    return { status: 400, body: { error: "Unknown report." } };
  }

  const sent = await store.incr(KEYS.rate(by));
  if (sent === 1) await store.expire(KEYS.rate(by), REPORT_WINDOW_SECONDS);
  if (sent > REPORT_LIMIT) return { status: 429, body: { error: "That is enough reports for now." } };

  const reportersKey = KEYS.reporters(kind, target);
  const added = await store.sadd(reportersKey, by);
  if (added) await store.expire(reportersKey, REPORTERS_TTL_SECONDS);
  const distinct = Number(await store.scard(reportersKey)) || 0;

  const record = { at: now, kind, target, by, ...(who ? { who } : {}), ...(cleanReason(reason) ? { reason: cleanReason(reason) } : {}) };
  await store.lpush(KEYS.reports, JSON.stringify(record));
  await store.ltrim(KEYS.reports, 0, REPORT_CAP - 1);

  let hidden = false;
  let blocked = false;
  if (distinct >= AUTO_HIDE_REPORTS) {
    if (kind === "message") {
      hidden = Boolean(await store.sadd(KEYS.hiddenMessages, String(id)));
      if (hidden && who) {
        const strikes = await store.incr(KEYS.strikes(who));
        if (strikes === 1) await store.expire(KEYS.strikes(who), STRIKE_TTL_SECONDS);
        if (strikes >= STRIKES_TO_BLOCK) blocked = Boolean(await store.sadd(KEYS.blockedWhos, who));
      }
    } else {
      hidden = Boolean(await store.sadd(KEYS.hiddenProfiles, target));
    }
  }
  return { status: 200, body: { reported: true, reports: distinct, hidden, blocked } };
}

/// Everything a moderator needs to see in one answer.
export async function overview(store) {
  const [raw, whos, messages, profiles] = await Promise.all([
    store.lrange(KEYS.reports, 0, REPORT_CAP - 1), blockedWhos(store), hiddenMessageIDs(store), hiddenProfiles(store),
  ]);
  const reports = raw.map((entry) => { try { return JSON.parse(entry); } catch { return null; } }).filter(Boolean);
  return { reports, blockedWhos: [...whos], hiddenMessages: [...messages], hiddenProfiles: [...profiles] };
}

/// A moderator's decision. Each action is idempotent.
export async function act(store, { action, who, id, address }) {
  switch (action) {
    case "block-who": if (!validWho(who)) break; await store.sadd(KEYS.blockedWhos, who); return { status: 200, body: { done: action, who } };
    case "unblock-who": if (!validWho(who)) break; await store.srem(KEYS.blockedWhos, who); return { status: 200, body: { done: action, who } };
    case "hide-message": if (!validID(id)) break; await store.sadd(KEYS.hiddenMessages, id); return { status: 200, body: { done: action, id } };
    case "unhide-message": if (!validID(id)) break; await store.srem(KEYS.hiddenMessages, id); return { status: 200, body: { done: action, id } };
    case "hide-profile": if (!validAddress(address)) break; await store.sadd(KEYS.hiddenProfiles, address.toLowerCase()); return { status: 200, body: { done: action, address: address.toLowerCase() } };
    case "unhide-profile": if (!validAddress(address)) break; await store.srem(KEYS.hiddenProfiles, address.toLowerCase()); return { status: 200, body: { done: action, address: address.toLowerCase() } };
    default: return { status: 400, body: { error: "Unknown action." } };
  }
  return { status: 400, body: { error: "The target is malformed." } };
}

/// Bearer check shared by the moderation routes, constant time.
export function authorized(req, secret = process.env.CRON_SECRET) {
  if (!secret) return false;
  const given = Buffer.from(String(req.headers?.authorization ?? ""));
  const expected = Buffer.from(`Bearer ${secret}`);
  return given.length === expected.length && crypto.timingSafeEqual(given, expected);
}
