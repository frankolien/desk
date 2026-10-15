/// The engine's loop, without the wiring: hold the lease, sweep every followed trader on a
/// schedule, read a trader at once when a chain event names their account, and leave a
/// heartbeat for the health check. Everything the engine does goes through one queue, so an
/// event and a sweep never read and act on the same trader at the same time.
export function createRunner({ engine, lease, store, now = Date.now, logger = console }) {
  let chain = Promise.resolve();
  const pendingTraders = new Set();
  let haltNoted = false;

  /// Runs `work` after everything already queued; a failure is logged, never thrown into the loop.
  function serial(label, work) {
    const run = chain.then(work).catch((error) => logger.warn?.(`copyd: ${label}: ${error.message}`));
    chain = run;
    return run;
  }

  async function halted() {
    const halt = await store.get("copy:halt");
    if (halt && !haltNoted) logger.warn?.(`copyd: halted (${halt}); nothing is read or copied until copy:halt is cleared`);
    haltNoted = Boolean(halt);
    return Boolean(halt);
  }

  /// One beat: keep or take the lease, and sweep if this process may act.
  async function tick() {
    const held = (await lease.renew()) || (await lease.acquire());
    if (!held || !lease.holds()) return { swept: false, reason: "no lease" };
    if (await halted()) return { swept: false, reason: "halted" };
    const found = await serial("sweep", () => engine.sweep());
    await store.set("copy:heartbeat", String(now()));
    return { swept: true, found };
  }

  /// A chain event: read that account's trader now, once, however many events arrive together.
  async function onAccount(accountId) {
    if (!lease.holds()) return null;
    const trader = await engine.traderForAccount(accountId);
    if (!trader || pendingTraders.has(trader)) return null;
    pendingTraders.add(trader);
    return serial(`event ${trader}`, async () => {
      pendingTraders.delete(trader);
      if (!lease.holds() || (await halted())) return null;
      return engine.processTrader(trader);
    });
  }

  return { tick, onAccount, idle: () => chain };
}
