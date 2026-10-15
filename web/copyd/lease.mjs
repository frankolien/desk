/// One engine at a time. Two would place every copy twice, so the engine signs nothing unless it
/// holds this lease. The value carries its own expiry, so a holder that stops renewing loses it
/// on the clock even if the key outlives it, and every change is a compare-and-swap: a lapsed
/// holder can never extend or release a lease someone else has since taken.
import { randomBytes } from "node:crypto";

/// One beat of the engine as one Redis command: keep or take the lease (the same rule as
/// acquire/renew), and only if held, read the halt, take the dirty set and stamp the heartbeat.
/// KEYS: lease, heartbeat, halt, dirty. ARGV: value this holder last wrote ('' if none), the
/// new value, ttl seconds, now ms.
export const BEAT_SCRIPT = `
local cur = redis.call('GET', KEYS[1])
local take = false
if not cur then take = true
elseif ARGV[1] ~= '' and cur == ARGV[1] then take = true
else
  local u = tonumber(string.match(cur, '|(%d+)$'))
  if u and u <= tonumber(ARGV[4]) then take = true end
end
if not take then return {0, '', {}} end
redis.call('SET', KEYS[1], ARGV[2], 'EX', tonumber(ARGV[3]))
local halt = redis.call('GET', KEYS[3])
if halt then return {1, halt, {}} end
local dirty = redis.call('SMEMBERS', KEYS[4])
if #dirty > 0 then redis.call('DEL', KEYS[4]) end
redis.call('SET', KEYS[2], ARGV[4])
return {1, '', dirty}
`;

/// The same beat for the in-memory store the tests use.
async function memoryBeat(store, [leaseKey, heartbeatKey, haltKey, dirtyKey], [expected, next, , nowMs]) {
  const cur = await store.get(leaseKey);
  const until = cur ? Number(cur.split("|")[1]) : null;
  const take = !cur || (expected !== "" && cur === expected) || (Number.isFinite(until) && until <= Number(nowMs));
  if (!take) return [0, "", []];
  await store.set(leaseKey, next);
  const halt = await store.get(haltKey);
  if (halt) return [1, halt, []];
  const dirty = await store.smembers(dirtyKey);
  if (dirty.length) await store.del(dirtyKey);
  await store.set(heartbeatKey, nowMs);
  return [1, "", dirty];
}

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
    /// Keep or take the lease, and with it the halt, the copiers changed since, and the heartbeat.
    async beat({ heartbeat = "copy:heartbeat", halt = "copy:halt", dirty = "copy:dirty" } = {}) {
      const next = encode(now() + ttlMs);
      const keys = [key, heartbeat, halt, dirty];
      const args = [written ?? "", next, String(ttlSeconds), String(now())];
      const [held, haltValue, dirtyIds] = store.eval ? await store.eval(BEAT_SCRIPT, keys, args) : await memoryBeat(store, keys, args);
      written = Number(held) === 1 ? next : null;
      return { held: Number(held) === 1, halt: haltValue || null, dirty: dirtyIds ?? [] };
    },
    async release() {
      if (!written) return false;
      const released = await store.swap(key, written, "");
      written = null;
      return released;
    },
  };
}
