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
    const parsed = await response.json();
    if (!response.ok) throw new Error(`redis ${response.status}`);
    return parsed;
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
    async setMany(entries, ex) {
      if (!entries.length) return;
      const results = await call("/pipeline", entries.map(([key, value]) => ["SET", key, value, "EX", String(ex)]));
      if (results.some((entry) => entry.error)) throw new Error("redis pipeline");
    },
  };
}

/// The same surface in memory, for tests.
export function memoryStore() {
  const values = new Map();
  const sets = new Map();
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
      sets.set(key, set.add(member));
      return 1;
    },
    async srem(key, ...members) {
      members.forEach((member) => sets.get(key)?.delete(member));
      return members.length;
    },
    scard: async (key) => sets.get(key)?.size ?? 0,
    async setMany(entries) {
      entries.forEach(([key, value]) => values.set(key, value));
    },
  };
}
