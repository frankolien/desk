/// A Desk profile: a name and a picture a wallet chose for itself.
///
/// Proven by a signature from the wallet key over a short message that carries the
/// address and the time, so a profile can only be set by the phone that holds the key,
/// and an old signature cannot be replayed a week later. Stored in the alerts store and
/// served through the identity resolver as the first source, ahead of Farcaster and ENS.
import { verifyMessage } from "viem";

export const MAX_NAME = 24;
/// Base64 of a 256×256 JPEG at moderate quality runs 15–40 KB; this leaves headroom.
export const MAX_IMAGE_BASE64 = 120_000;
export const SIGNATURE_WINDOW_MS = 10 * 60_000;
const SAVE_GAP_SECONDS = 20;
const API_HOST = process.env.PUBLIC_API_HOST || "https://web-lovat-nine-49.vercel.app";

const evmAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(String(value ?? ""));
const profileKey = (address) => `profile:${address.toLowerCase()}`;

export function profileMessage(address, timestamp) {
  return `Desk profile\n${String(address).toLowerCase()}\n${timestamp}`;
}

export function cleanName(value) {
  const name = String(value ?? "").replace(/[\u0000-\u001f\u007f\u200b-\u200f\u2028-\u202e]/g, "").replace(/\s+/g, " ").trim();
  return name.length > MAX_NAME ? name.slice(0, MAX_NAME).trim() : name;
}

/// JPEG or PNG, by the bytes, not by what the caller said.
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

/// Desk profiles for a batch of addresses, in the identity resolver's shape.
export async function deskProfiles(store, addresses) {
  const found = new Map();
  const evm = addresses.filter(evmAddress);
  if (!store || evm.length === 0) return found;
  const rows = await store.mget(evm.map(profileKey)).catch(() => evm.map(() => null));
  evm.forEach((address, index) => {
    if (!rows[index]) return;
    try {
      const stored = JSON.parse(rows[index]);
      const profile = publicProfile(address, stored);
      if (profile && (profile.name || profile.avatar)) found.set(address.toLowerCase(), profile);
    } catch { /* a bad row is no profile */ }
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
  if (!name && !image) return { status: 400, body: { error: "Give the profile a name or a picture." } };

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
  const stored = {
    name: name || null,
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
