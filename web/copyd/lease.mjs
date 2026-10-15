/// One engine at a time. Two would place every copy twice, so the engine signs nothing unless it
/// holds this lease. The value carries its own expiry, so a holder that stops renewing loses it
/// on the clock even if the key outlives it, and every change is a compare-and-swap: a lapsed
/// holder can never extend or release a lease someone else has since taken.
import { randomBytes } from "node:crypto";

export function createLease({ store, key = "copy:lease", ttlMs = 15_000, now = Date.now, id = randomBytes(8).toString("hex") }) {
  let written = null; // the exact value this process last wrote
  const encode = (until) => `${id}|${until}`;
  const decode = (value) => {
    if (!value) return null;
    const [holder, until] = value.split("|");
    return { holder, until: Number(until) };
  };
  const ttlSeconds = Math.ceil(ttlMs / 1000) + 5;

  return {
    id,
    /// Takes the lease if it is free or lapsed. True when this process holds it afterwards.
    async acquire() {
      const current = await store.get(key);
      const parsed = decode(current);
      const next = encode(now() + ttlMs);
      let taken = false;
      if (!parsed) taken = await store.set(key, next, { nx: true, ex: ttlSeconds });
      else if (parsed.holder === id || parsed.until <= now()) taken = await store.swap(key, current, next, { ex: ttlSeconds });
      written = taken ? next : null;
      return taken;
    },
    /// Extends a lease this process still holds; false, and the lease is gone, if it lapsed
    /// and someone else took it.
    async renew() {
      if (!written) return false;
      const next = encode(now() + ttlMs);
      const renewed = await store.swap(key, written, next, { ex: ttlSeconds });
      written = renewed ? next : null;
      return renewed;
    },
    /// Whether signing is allowed right now: held, and not within two seconds of lapsing, so a
    /// slow request cannot outlive the lease it started under.
    holds() {
      const parsed = decode(written);
      return Boolean(parsed) && now() < parsed.until - 2_000;
    },
    async release() {
      if (!written) return false;
      const released = await store.swap(key, written, "");
      written = null;
      return released;
    },
  };
}
