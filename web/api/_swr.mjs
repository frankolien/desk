import { waitUntil } from "@vercel/functions";

/// The last good answer for `key`, kept in Redis so a cold function or an empty edge never
/// makes someone wait on a slow upstream twice. Younger than `freshMs` it is simply the answer.
/// Older, it is answered at once with `stale: true` and rebuilt after the response is sent;
/// the app asks again a moment later and gets the rebuilt one. Nothing held means a normal build.
/// `freshMs` may be a function of the held answer, for answers that are known to be partial.
/// `keepS` bounds how old an answer may still be shown, and one rebuild runs per key at a time.
export async function lastGood(store, key, { freshMs, keepS = 86_400, now = Date.now, background = waitUntil } = {}, build) {
  if (!store) return { value: await build(), ageMs: 0, stale: false };
  const held = parse(await store.get(key).catch(() => null));
  const ageMs = held ? Math.max(0, now() - held.at) : null;
  const freshFor = typeof freshMs === "function" ? freshMs(held?.value) : freshMs;
  if (held && ageMs < freshFor) return { value: held.value, ageMs, stale: false };

  const rebuild = async () => {
    const value = await build();
    await store.set(key, JSON.stringify({ at: now(), value }), { ex: keepS }).catch(() => {});
    return value;
  };
  if (!held) return { value: await rebuild(), ageMs: 0, stale: false };

  const claimed = await store.set(`${key}:rebuilding`, "1", { nx: true, ex: 60 }).catch(() => false);
  if (claimed) {
    const work = rebuild().catch(() => {}).finally(() => store.del(`${key}:rebuilding`).catch(() => {}));
    try { background(work); } catch {}
  }
  return { value: held.value, ageMs, stale: true };
}

function parse(text) {
  if (!text) return null;
  try {
    const held = JSON.parse(text);
    return Number.isFinite(held?.at) && "value" in held ? held : null;
  } catch { return null; }
}
