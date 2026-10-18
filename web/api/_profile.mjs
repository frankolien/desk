import { verifyMessage } from "viem";

import { hiddenProfiles } from "./_moderation.mjs";
export const MAX_NAME = 24;
export const MAX_IMAGE_BASE64 = 120_000;
export const SIGNATURE_WINDOW_MS = 10 * 60_000;
const SAVE_GAP_SECONDS = 20;
const API_HOST = process.env.PUBLIC_API_HOST || "https://web-lovat-nine-49.vercel.app";

const evmAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(String(value ?? ""));
const profileKey = (address) => `profile:${address.toLowerCase()}`;
const tagKey = (tag) => `tag:${tag}`;

/// Names Desk keeps for itself, so no one can pose as the app or its staff.
const RESERVED_TAGS = new Set([
  "desk", "trydesk", "admin", "administrator", "support", "help", "team", "official", "staff", "mod", "moderator",
  "security", "root", "system", "null", "undefined", "perpl", "monad", "ausd", "agora", "wallet", "treasury", "fees",
]);

/// A Desk tag: 3 to 20 lowercase letters, digits and underscores, starting with a letter.
/// "@frank", "Frank" and "frank.desk" all mean frank. Returns the tag, or a sentence saying why not.
export function cleanTag(value) {
  let tag = String(value ?? "").trim().toLowerCase();
  if (tag.startsWith("@")) tag = tag.slice(1);
  if (tag.endsWith(".desk")) tag = tag.slice(0, -5);
  if (!tag) return { tag: "" };
  if (tag.length < 3) return { error: "A tag needs at least 3 characters." };
  if (tag.length > 20) return { error: "A tag can have at most 20 characters." };
  if (!/^[a-z][a-z0-9_]*$/.test(tag)) return { error: "Letters, numbers and underscores only, starting with a letter." };
  if (RESERVED_TAGS.has(tag)) return { error: "That tag is reserved." };
  return { tag };
}

/// Who holds a tag, if anyone.
export async function tagOwner(store, tag) {
  if (!store || !tag) return null;
  const owner = await store.get(tagKey(tag)).catch(() => null);
  return owner && evmAddress(owner) ? String(owner).toLowerCase() : null;
}

/// The answer to "is @frank free?", for the editor as the person types.
export async function tagAvailability(store, query) {
  const cleaned = cleanTag(query);
  if (cleaned.error) return { status: 200, body: { tag: null, available: false, reason: cleaned.error } };
  if (!cleaned.tag) return { status: 400, body: { error: "A tag is required." } };
  const owner = await tagOwner(store, cleaned.tag);
  return { status: 200, body: { tag: cleaned.tag, available: owner == null, address: owner } };
}

export function profileMessage(address, timestamp) {
  return `Desk profile\n${String(address).toLowerCase()}\n${timestamp}`;
}

/// A different message from saving, so a save signature can never be replayed as a delete.
export function deleteMessage(address, timestamp) {
  return `Delete Desk profile\n${String(address).toLowerCase()}\n${timestamp}`;
}

export async function deleteProfile(store, body, { now = Date.now(), verify = verifyMessage } = {}) {
  if (!store) return { status: 503, body: { error: "Profiles are not configured." } };
  const address = String(body?.address ?? "");
  if (!evmAddress(address)) return { status: 400, body: { error: "A wallet address is required." } };
  const timestamp = Number(body?.timestamp);
  if (!Number.isInteger(timestamp) || Math.abs(now - timestamp) > SIGNATURE_WINDOW_MS) {
    return { status: 400, body: { error: "This request is too old. Try again." } };
  }
  const signature = String(body?.signature ?? "");
  if (!/^0x[a-fA-F0-9]{130}$/.test(signature)) return { status: 400, body: { error: "A wallet signature is required." } };
  let valid = false;
  try {
    valid = await verify({ address, message: deleteMessage(address, timestamp), signature });
  } catch { valid = false; }
  if (!valid) return { status: 401, body: { error: "That signature does not belong to this wallet." } };
  const previous = await readProfile(store, address);
  if (previous?.tag && (await tagOwner(store, previous.tag)) === address.toLowerCase()) await store.del(tagKey(previous.tag)).catch(() => {});
  await store.del(profileKey(address));
  await store.del(`id:${address.toLowerCase()}`).catch(() => {});
  return { status: 200, body: { deleted: true } };
}

export function cleanName(value) {
  const name = String(value ?? "").replace(/[\u0000-\u001f\u007f\u200b-\u200f\u2028-\u202e]/g, "").replace(/\s+/g, " ").trim();
  return name.length > MAX_NAME ? name.slice(0, MAX_NAME).trim() : name;
}

export function imageType(base64) {
  if (!/^[A-Za-z0-9+\/]+=*$/.test(base64)) return null;
  const head = Buffer.from(base64.slice(0, 16), "base64");
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return "image/jpeg";
  if (head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47) return "image/png";
  return null;
}

export function avatarURL(address, updatedAt) {
  return `${API_HOST}/api/traders?view=avatar&address=${address.toLowerCase()}&v=${updatedAt}`;
}

export function publicProfile(address, stored) {
  if (!stored) return null;
  return {
    name: stored.name ?? null,
    tag: stored.tag ?? null,
    avatar: stored.image ? avatarURL(address, stored.updatedAt) : null,
    updatedAt: stored.updatedAt,
  };
}

export async function readProfile(store, address) {
  if (!store || !evmAddress(address)) return null;
  const raw = await store.get(profileKey(address)).catch(() => null);
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

export async function deskProfiles(store, addresses) {
  const found = new Map();
  const evm = addresses.filter(evmAddress);
  if (!store || evm.length === 0) return found;
  const [rows, hidden] = await Promise.all([
    store.mget(evm.map(profileKey)).catch(() => evm.map(() => null)),
    hiddenProfiles(store),
  ]);
  evm.forEach((address, index) => {
    if (!rows[index] || hidden.has(address.toLowerCase())) return;
    try {
      const stored = JSON.parse(rows[index]);
      const profile = publicProfile(address, stored);
      if (profile && (profile.name || profile.avatar || profile.tag)) found.set(address.toLowerCase(), profile);
    } catch {}
  });
  return found;
}

export async function saveProfile(store, body, { now = Date.now(), verify = verifyMessage } = {}) {
  if (!store) return { status: 503, body: { error: "Profiles are not configured." } };
  const address = String(body?.address ?? "");
  if (!evmAddress(address)) return { status: 400, body: { error: "A wallet address is required." } };
  const timestamp = Number(body?.timestamp);
  if (!Number.isInteger(timestamp) || Math.abs(now - timestamp) > SIGNATURE_WINDOW_MS) {
    return { status: 400, body: { error: "This request is too old. Try again." } };
  }
  const signature = String(body?.signature ?? "");
  if (!/^0x[a-fA-F0-9]{130}$/.test(signature)) return { status: 400, body: { error: "A wallet signature is required." } };

  const name = cleanName(body?.name);
  const image = body?.image == null ? null : String(body.image);
  let type = null;
  
  if (image !== null && image !== "") {
    if (image.length > MAX_IMAGE_BASE64) return { status: 413, body: { error: "That picture is too large." } };
    type = imageType(image);
    if (!type) return { status: 400, body: { error: "The picture must be a JPEG or PNG." } };
  }
  // A missing tag keeps the one already there; an empty string lets it go.
  const wantsTag = body?.tag !== undefined && body?.tag !== null;
  const cleanedTag = wantsTag ? cleanTag(body.tag) : { tag: undefined };
  if (cleanedTag.error) return { status: 400, body: { error: cleanedTag.error } };
  if (!name && !image && !cleanedTag.tag) return { status: 400, body: { error: "Give the profile a name, a tag or a picture." } };

  let valid = false;
  try {
    valid = await verify({ address, message: profileMessage(address, timestamp), signature });
  } catch { valid = false; }
  if (!valid) return { status: 401, body: { error: "That signature does not belong to this wallet." } };

  const rateKey = `profile:rate:${address.toLowerCase()}`;
  const attempts = await store.incr(rateKey);
  if (attempts === 1) await store.expire(rateKey, SAVE_GAP_SECONDS);
  if (attempts > 1) return { status: 429, body: { error: "Give it a moment before saving again." } };

  const previous = await readProfile(store, address);
  const me = address.toLowerCase();
  const tag = cleanedTag.tag === undefined ? (previous?.tag ?? null) : (cleanedTag.tag || null);
  if (tag && tag !== previous?.tag) {
    // First come, first served: the key is set only if nobody holds it.
    const claimed = await store.set(tagKey(tag), me, { nx: true });
    if (!claimed && (await tagOwner(store, tag)) !== me) return { status: 409, body: { error: `@${tag} is taken. Try another.` } };
  }
  if (previous?.tag && previous.tag !== tag && (await tagOwner(store, previous.tag)) === me) await store.del(tagKey(previous.tag)).catch(() => {});
  const stored = {
    name: name || null,
    tag,
    // An empty string clears the picture; a missing field keeps the one already there.
    image: image === "" ? null : (image ?? previous?.image ?? null),
    type: image === "" ? null : (type ?? previous?.type ?? null),
    updatedAt: now,
  };
  await store.set(profileKey(address), JSON.stringify(stored));
  // The identity cache holds the merged answer; it must be rebuilt with this in it.
  await store.del(`id:${address.toLowerCase()}`).catch(() => {});
  return { status: 200, body: { profile: publicProfile(address, stored) } };
}
