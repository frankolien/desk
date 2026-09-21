export const TIERS = {
  default: { limit: 60, window: 60 },
  expensive: { limit: 10, window: 60 },
};

export function clientIp(headers = {}) {
  const forwarded = String(headers["x-forwarded-for"] ?? "").split(",")[0].trim();
  return forwarded || String(headers["x-real-ip"] ?? "").trim() || "unknown";
}

// Two fixed windows stand in for a sliding one: the previous bucket counts in proportion
// to how much of it still overlaps the last `window` seconds.
export async function rateLimit({ store, tier = "default", ip, now = Date.now() } = {}) {
  const { limit, window } = TIERS[tier] ?? TIERS.default;
  const seconds = Math.floor(now / 1000);
  const start = seconds - (seconds % window);
  const reset = start + window;
  const headers = (remaining) => ({
    "X-RateLimit-Limit": String(limit),
    "X-RateLimit-Remaining": String(Math.max(0, remaining)),
    "X-RateLimit-Reset": String(reset),
  });
  if (!store) return { allowed: true, limit, remaining: limit, reset, retryAfter: 0, headers: headers(limit) };

  const key = (bucket) => `rl:${tier}:${ip}:${bucket}`;
  try {
    const [current, previous] = await Promise.all([
      store.incr(key(start)),
      store.get(key(start - window)),
    ]);
    if (current === 1) await store.expire(key(start), window * 2).catch(() => {});
    const elapsed = seconds - start;
    const weight = Number(previous ?? 0) * (1 - elapsed / window) + Number(current);
    const remaining = Math.floor(limit - weight);
    const allowed = weight <= limit;
    return { allowed, limit, remaining: allowed ? remaining : 0, reset, retryAfter: allowed ? 0 : Math.max(1, reset - seconds), headers: headers(allowed ? remaining : 0) };
  } catch {
    return { allowed: true, limit, remaining: limit, reset, retryAfter: 0, headers: headers(limit) };
  }
}
