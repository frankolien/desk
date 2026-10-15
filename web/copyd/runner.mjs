/// The engine's loop, without the wiring: one beat keeps the lease, picks up copiers the API
/// changed and leaves a heartbeat, all in one Redis command (lease.beat); then every followed
/// trader is swept, and a chain event reads its trader at once. Events don't wait for a sweep:
/// the engine keeps reads of one trader from overlapping, and its decisions from interleaving.
///
/// Redis is billed per command and shared with the worker, so an idle engine costs one command
/// a beat. Events use the halt as the last beat saw it; only a live order reads it fresh, right
/// before its signature.
export function createRunner({ engine, lease, store, logger = console }) {
  let haltNoted = false;
  let halted = false;
  let sweeping = null;
  let lapsed = false; // held the lease, lost it, and has not swept since taking it back

  function noteHalt(value) {
    if (value && !haltNoted) logger.warn?.(`copyd: halted (${value}); nothing is read or copied until copy:halt is cleared`);
    haltNoted = Boolean(value);
    halted = Boolean(value);
  }

  /// One beat: the lease, the halt and the changed copiers in one command, then a sweep. A sweep
  /// still running from the last beat is waited for, not doubled.
  async function tick() {
    let beat;
    try { beat = await lease.beat(); } catch (error) {
      logger.warn?.(`copyd: beat: ${error.message}`);
      return { swept: false, reason: "no lease" };
    }
    if (!beat.held || !lease.holds()) { lapsed = true; return { swept: false, reason: "no lease" }; }
    if (lapsed) { engine.reset?.(); lapsed = false; }
    noteHalt(beat.halt);
    if (halted) return { swept: false, reason: "halted" };
    if (sweeping) { await sweeping; return { swept: false, reason: "busy" }; }
    sweeping = (async () => {
      await engine.refresh?.(beat.dirty);
      return engine.sweep();
    })();
    try { return { swept: true, found: await sweeping }; } finally { sweeping = null; }
  }

  const work = new Set();

  /// A chain event: read that account's trader now.
  async function onAccount(accountId) {
    if (!lease.holds() || lapsed || halted) return null;
    const trader = await engine.traderForAccount(accountId);
    if (!trader) return null;
    const job = (async () => {
      if (!lease.holds() || halted) return null;
      return engine.processTrader(trader);
    })().catch((error) => { logger.warn?.(`copyd: event ${trader}: ${error.message}`); return null; });
    work.add(job);
    job.finally(() => work.delete(job));
    return job;
  }

  /// For the executor, right before every signature: held, and the halt read now.
  async function mayAct() {
    if (!lease.holds() || lapsed) return false;
    noteHalt(await store.get("copy:halt"));
    return !halted;
  }

  return { tick, onAccount, mayAct, idle: async () => { await sweeping; await Promise.all([...work]); } };
}
