/// Upstash Redis over its REST API, so the functions need no client library. Either the
/// Vercel marketplace names or Upstash's own are accepted.
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
    if (!response.ok) throw new Error(`redis ${response.status}`);
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
      const results = await call("/pipeline", entries.map(([key, value]) => ["SET", key, value, "EX", String(ex)]));
      if (results.some((entry) => entry.error)) throw new Error("redis pipeline");
    },
    lpush: (key, value) => command("LPUSH", key, value),
    ltrim: (key, start, stop) => command("LTRIM", key, String(start), String(stop)),
    lrange: (key, start, stop) => command("LRANGE", key, String(start), String(stop)),
    zadd: (key, score, member) => command("ZADD", key, String(score), member),
    zcount: (key, min, max) => command("ZCOUNT", key, String(min), String(max)),
    zremrangebyscore: (key, min, max) => command("ZREMRANGEBYSCORE", key, String(min), String(max)),
  };
}

/// The same surface in memory, for tests.
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
    async lpush(key, value) {
      const list = lists.get(key) ?? [];
      list.unshift(String(value));
      lists.set(key, list);
      return list.length;
    },
    async ltrim(key, start, stop) {
      const list = lists.get(key) ?? [];
      lists.set(key, list.slice(start, stop < 0 ? list.length + stop + 1 : stop + 1));
      return "OK";
    },
    async lrange(key, start, stop) {
      const list = lists.get(key) ?? [];
      return list.slice(start, stop < 0 ? list.length + stop + 1 : stop + 1);
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
