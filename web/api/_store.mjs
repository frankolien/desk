export function redisStore({
  url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL,
  token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN,
  fetchImpl = fetch,
} = {}) {
  if (!url || !token) return null;
  const base = url.replace(/\/+$/, "");

  async function call(path, body) {
    const response = await fetchImpl(`${base}${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      const reason = await response.text().catch(() => "");
      throw new Error(`redis ${response.status}${reason ? `: ${reason.slice(0, 120)}` : ""}`);
    }
    return response.json();
  }

  async function command(...args) {
    const { result, error } = await call("", args.map(String));
    if (error) throw new Error(`redis: ${error}`);
    return result;
  }

  return {
    get: (key) => command("GET", key),
    async set(key, value, { ex, nx } = {}) {
      const args = ["SET", key, value];
      if (ex) args.push("EX", ex);
      if (nx) args.push("NX");
      return (await command(...args)) === "OK";
    },
    del: (key) => command("DEL", key),
    mget: (keys) => (keys.length ? command("MGET", ...keys) : []),
    smembers: (key) => command("SMEMBERS", key),
    sadd: (key, member) => command("SADD", key, member),
    srem: (key, ...members) => (members.length ? command("SREM", key, ...members) : 0),
    scard: (key) => command("SCARD", key),
    incr: (key) => command("INCR", key),
    expire: (key, seconds) => command("EXPIRE", key, String(seconds)),
    async setMany(entries, ex) {
      if (!entries.length) return;
      const results = await call("/pipeline", entries.map(([key, value, ttl]) => ["SET", key, value, "EX", String(ttl ?? ex)]));
      if (results.some((entry) => entry.error)) throw new Error("redis pipeline");
    },
    lpush: (key, ...values) => command("LPUSH", key, ...values),
    ltrim: (key, start, stop) => command("LTRIM", key, String(start), String(stop)),
    lrange: (key, start, stop) => command("LRANGE", key, String(start), String(stop)),
    zadd: (key, score, member) => command("ZADD", key, String(score), member),
    zcount: (key, min, max) => command("ZCOUNT", key, String(min), String(max)),
    zremrangebyscore: (key, min, max) => command("ZREMRANGEBYSCORE", key, String(min), String(max)),
    /// Several commands in one round trip, e.g. `[["SET", k, v], ["LPUSH", k, a, b]]`. Upstash still
    /// bills each one; what this saves is the wait.
    async pipeline(commands) {
      if (!commands.length) return [];
      const results = await call("/pipeline", commands.map((entry) => entry.map(String)));
      const failed = results.find((entry) => entry.error);
      if (failed) throw new Error(`redis pipeline: ${failed.error}`);
      return results.map((entry) => entry.result);
    },
    /// Replaces the value only while it still equals `expected`, atomically: a lease is renewed
    /// or released by its holder alone. An empty `value` deletes the key.
    async swap(key, expected, value, { ex } = {}) {
      return Number(await command("EVAL", SWAP_SCRIPT, "1", key, expected, value, String(ex ?? 0))) === 1;
    },
  };
}

const SWAP_SCRIPT = `if redis.call("GET", KEYS[1]) ~= ARGV[1] then return 0 end
if ARGV[2] == "" then redis.call("DEL", KEYS[1]) return 1 end
if tonumber(ARGV[3]) > 0 then redis.call("SET", KEYS[1], ARGV[2], "EX", ARGV[3]) else redis.call("SET", KEYS[1], ARGV[2]) end
return 1`;

export function memoryStore() {
  const values = new Map();
  const sets = new Map();
  const lists = new Map();
  const zsets = new Map();
  return {
    values,
    sets,
    get: async (key) => values.get(key) ?? null,
    async set(key, value, { nx } = {}) {
      if (nx && values.has(key)) return false;
      values.set(key, String(value));
      return true;
    },
    async swap(key, expected, value) {
      if (values.get(key) !== expected) return false;
      if (value === "") values.delete(key); else values.set(key, String(value));
      return true;
    },
    del: async (key) => Number(values.delete(key)),
    mget: async (keys) => keys.map((key) => values.get(key) ?? null),
    smembers: async (key) => [...(sets.get(key) ?? [])],
    async sadd(key, member) {
      const set = sets.get(key) ?? new Set();
      const added = set.has(member) ? 0 : 1;
      sets.set(key, set.add(member));
      return added;
    },
    async srem(key, ...members) {
      members.forEach((member) => sets.get(key)?.delete(member));
      return members.length;
    },
    scard: async (key) => sets.get(key)?.size ?? 0,
    async incr(key) {
      const next = Number(values.get(key) ?? 0) + 1;
      values.set(key, String(next));
      return next;
    },
    async expire() { return 1; },
    async setMany(entries) {
      entries.forEach(([key, value]) => values.set(key, value));
    },
    lists,
    zsets,
    async lpush(key, ...values) {
      const list = lists.get(key) ?? [];
      values.forEach((value) => list.unshift(String(value)));
      lists.set(key, list);
      return list.length;
    },
    async ltrim(key, from, to) {
      const [start, stop] = [Number(from), Number(to)];
      const list = lists.get(key) ?? [];
      lists.set(key, list.slice(start, stop < 0 ? list.length + stop + 1 : stop + 1));
      return "OK";
    },
    async lrange(key, from, to) {
      const [start, stop] = [Number(from), Number(to)];
      const list = lists.get(key) ?? [];
      return list.slice(start, stop < 0 ? list.length + stop + 1 : stop + 1);
    },
    async pipeline(commands) {
      const out = [];
      for (const [name, ...args] of commands) out.push(await this[name.toLowerCase()](...args));
      return out;
    },
    async zadd(key, score, member) {
      const set = zsets.get(key) ?? new Map();
      const added = set.has(member) ? 0 : 1;
      set.set(member, Number(score));
      zsets.set(key, set);
      return added;
    },
    async zcount(key, min, max) {
      const lo = min === "-inf" ? -Infinity : Number(min);
      const hi = max === "+inf" ? Infinity : Number(max);
      return [...(zsets.get(key) ?? new Map()).values()].filter((score) => score >= lo && score <= hi).length;
    },
    async zremrangebyscore(key, min, max) {
      const lo = min === "-inf" ? -Infinity : Number(min);
      const hi = max === "+inf" ? Infinity : Number(max);
      const set = zsets.get(key) ?? new Map();
      let removed = 0;
      for (const [member, score] of set) if (score >= lo && score <= hi) { set.delete(member); removed += 1; }
      return removed;
    },
  };
}
