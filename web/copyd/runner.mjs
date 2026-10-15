/// The engine's loop, without the wiring: hold the lease, pick up copiers the API changed, sweep
/// every followed trader on a schedule, read a trader at once when a chain event names their
/// account, and leave a heartbeat for the health check. Events don't wait for a sweep: the engine
/// keeps reads of one trader from overlapping, and its decisions from interleaving.
const HALT_CACHE_MS = 2_000;

export function createRunner({ engine, lease, store, now = Date.now, logger = console }) {
  let haltNoted = false;
  let haltCheckedAt = -Infinity;
  let haltCached = false;
  let sweeping = null;
  let lapsed = false; // held the lease, lost it, and has not swept since taking it back

  async function halted({ fresh = false } = {}) {
    if (!fresh && now() - haltCheckedAt < HALT_CACHE_MS) return haltCached;
    const halt = await store.get("copy:halt");
    if (halt && !haltNoted) logger.warn?.(`copyd: halted (${halt}); nothing is read or copied until copy:halt is cleared`);
    haltNoted = Boolean(halt);
    haltCheckedAt = now();
    haltCached = Boolean(halt);
    return haltCached;
  }

  /// Keeps or takes the lease. Runs on its own timer, well inside the lease's life: renewed only
  /// once per sweep, the lease spent its last two seconds of every cycle not held, and events
  /// landing then were dropped until the next sweep.
  async function keepLease() {
    try { return (await lease.renew()) || (await lease.acquire()); }
    catch (error) { logger.warn?.(`copyd: lease: ${error.message}`); return false; }
  }

  /// One beat: sweep if this process may act. A sweep still running from the last beat is
  /// waited for, not doubled.
  async function tick() {
    if (!lease.holds()) await keepLease();
    if (!lease.holds()) { lapsed = true; return { swept: false, reason: "no lease" }; }
    if (lapsed) { engine.reset?.(); lapsed = false; }
    if (await halted({ fresh: true })) return { swept: false, reason: "halted" };
    if (sweeping) { await sweeping; return { swept: false, reason: "busy" }; }
    sweeping = (async () => {
      await engine.refresh?.();
      return engine.sweep();
    })();
    try {
      const found = await sweeping;
      await store.set("copy:heartbeat", String(now()));
      return { swept: true, found };
    } finally { sweeping = null; }
  }

  const work = new Set();

  /// A chain event: read that account's trader now.
  async function onAccount(accountId) {
    if (!lease.holds() || lapsed) return null;
    const trader = await engine.traderForAccount(accountId);
    if (!trader) return null;
    const job = (async () => {
      if (await halted()) return null;
      if (!lease.holds()) return null;
      return engine.processTrader(trader);
    })().catch((error) => { logger.warn?.(`copyd: event ${trader}: ${error.message}`); return null; });
    work.add(job);
    job.finally(() => work.delete(job));
    return job;
  }

  return { tick, keepLease, onAccount, idle: async () => { await sweeping; await Promise.all([...work]); } };
}
