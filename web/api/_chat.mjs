/// A poster is identified by the hashed install secret. The address and name beside a
/// message are only what the app claimed, and the app marks them as such.
import crypto from "node:crypto";
import { blockedWhos, hiddenMessageIDs } from "./_moderation.mjs";

export const ROOM_CAP = 200;
export const PAGE = 80;
export const MAX_TEXT = 240;
export const MAX_NAME = 24;
export const PRESENT_MS = 120_000;
const RATE_WINDOW_SECONDS = 10;
const RATE_LIMIT = 3;

const validMarket = (value) => /^[A-Z0-9]{2,10}$/.test(value);
const validAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(value);
const validInstall = (value) => /^[a-f0-9]{64}$/.test(value);

export const who = (install) => crypto.createHash("sha256").update(`chat:${install}`).digest("hex").slice(0, 16);

export function cleanText(value) {
  const text = String(value ?? "").replace(/[\u0000-\u001f\u007f\u200b-\u200f\u2028-\u202e]/g, " ").replace(/\s+/g, " ").trim();
  return text.length > MAX_TEXT ? text.slice(0, MAX_TEXT).trim() : text;
}

export function cleanName(value) {
  const name = String(value ?? "").replace(/[\u0000-\u001f\u007f\u200b-\u200f\u2028-\u202e]/g, "").replace(/\s+/g, " ").trim();
  return name.length > MAX_NAME ? name.slice(0, MAX_NAME).trim() : name;
}

const messagesKey = (market) => `chat:room:${market}`;
const presenceKey = (market) => `chat:here:${market}`;

export async function readRoom(store, { market, install }, now = Date.now()) {
  const symbol = String(market ?? "").toUpperCase();
  if (!validMarket(symbol)) return { status: 400, body: { error: "A market is required." } };
  if (validInstall(String(install ?? ""))) {
    await store.zadd(presenceKey(symbol), now, who(install));
  }
  if (Math.random() < 0.125) await store.zremrangebyscore(presenceKey(symbol), "-inf", now - PRESENT_MS);
  const [raw, here, hidden, blocked] = await Promise.all([
    store.lrange(messagesKey(symbol), 0, PAGE - 1),
    store.zcount(presenceKey(symbol), now - PRESENT_MS, "+inf"),
    hiddenMessageIDs(store),
    blockedWhos(store),
  ]);
  const messages = raw.map((entry) => { try { return JSON.parse(entry); } catch { return null; } })
    .filter((message) => message && !hidden.has(message.id) && !blocked.has(message.who))
    .reverse();
  return { status: 200, body: { market: symbol, here: Number(here) || 0, messages, observedAt: now } };
}

/// One message in. The rate limit is per phone, not per address, so a new address is
/// not a way around it.
export async function postMessage(store, { market, install, address, name, text }, now = Date.now()) {
  const symbol = String(market ?? "").toUpperCase();
  if (!validMarket(symbol)) return { status: 400, body: { error: "A market is required." } };
  if (!validInstall(String(install ?? ""))) return { status: 401, body: { error: "This install is not recognised." } };
  const body = cleanText(text);
  if (!body) return { status: 400, body: { error: "Write something first." } };
  if ((await blockedWhos(store)).has(who(install))) return { status: 403, body: { error: "You can't post in the rooms right now." } };

  const rateKey = `chat:rate:${who(install)}`;
  const sent = await store.incr(rateKey);
  if (sent === 1) await store.expire(rateKey, RATE_WINDOW_SECONDS);
  if (sent > RATE_LIMIT) return { status: 429, body: { error: "Slow down a little." } };

  const message = {
    id: `${now.toString(36)}-${crypto.randomBytes(4).toString("hex")}`,
    at: now,
    who: who(install),
    address: validAddress(String(address ?? "")) ? String(address).toLowerCase() : null,
    name: cleanName(name) || null,
    text: body,
  };
  await store.lpush(messagesKey(symbol), JSON.stringify(message));
  await store.ltrim(messagesKey(symbol), 0, ROOM_CAP - 1);
  await store.zadd(presenceKey(symbol), now, message.who);
  return { status: 200, body: { message } };
}
