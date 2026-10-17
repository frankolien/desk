/// Spot copy's loop (docs/spot-copy.md). The worker's fast lane keeps each copied leader's ledger
/// (`wl:<address>`) fresh; every few seconds this reads those ledgers, finds trades newer than
/// its own marker and plays each against every wallet copying that leader: a buy through the
/// rules and the executor, a sell as the same share of what the copy holds. Wallets' own signed
/// batches (turning on, new limits, turning off) are relayed from the job list on the same beat.
import { ledgerKey } from "../api/_ledger.mjs";
import { compactNumber, newestMarker, walletEvents } from "../api/_watch.mjs";
import { shortAddress } from "./notify.mjs";
import { ausdOf, buyDecision, sellDecision } from "./spot-rules.mjs";
import { SpotRefusal, reasonOf } from "./spot-executor.mjs";
import { batchFor } from "./spot-chain.mjs";

export const S = {
  copier: (wallet) => `copy:spot:${wallet.toLowerCase()}`,
  wallets: "copy:spot:wallets",
  leaders: "copy:spot:leaders",
  followers: (leader) => `copy:spot:followers:${leader.toLowerCase()}`,
  seen: (leader) => `copy:spot:seen:${leader.toLowerCase()}`,
  log: (wallet) => `copy:spot:log:${wallet.toLowerCase()}`,
  hourly: (wallet, hour) => `copy:spot:hourly:${wallet.toLowerCase()}:${hour}`,
  jobs: "copy:spot:jobs",
  desk: "copy:spot:desk",
  halt: "copy:halt",
};
export const SPOT_LOG_LIMIT = 200;
export const TRADES_PER_HOUR = 30;
const FAILURES_TO_PAUSE = 3;
const SELL_RETRY_MS = 15_000;

const parse = (text) => { try { return text ? JSON.parse(text) : null; } catch { return null; } };

export function live(copier, nowMs) {
  return copier && copier.stage === "live" && !copier.paused && (!copier.expiry || copier.expiry * 1000 > nowMs);
}

const units = (raw, decimals) => Number(raw) / 10 ** (decimals ?? 18);

export function spotPayload(row) {
  const who = row.leaderName || shortAddress(row.leader ?? "0x0000000000");
  let title;
  let body = row.detail ?? "";
  switch (row.status) {
    case "copied":
      title = row.side === "buy" ? `Copied ${who}'s buy` : `Sold with ${who}`;
      body = row.side === "buy"
        ? `${row.ausd.toFixed(2)} AUSD → ${compactNumber(row.amount)} ${row.symbol}`
        : `${compactNumber(row.amount)} ${row.symbol} → ${row.ausd.toFixed(2)} AUSD`;
      break;
    case "failed": title = `Couldn't copy ${who}'s ${row.symbol} ${row.side}`; break;
    case "paused": title = "Spot Auto-Copy paused"; break;
    case "on": title = "Spot Auto-Copy is on"; break;
    case "off": title = "Spot Auto-Copy is off"; break;
    default: return null;
  }
  return {
    aps: { alert: { title, body }, sound: "default", "thread-id": "spot-copy", "relevance-score": 0.9 },
    desk: { type: "spot-copy", status: row.status, leader: row.leader ?? null, token: row.token ?? null, symbol: row.symbol ?? null, hash: row.hash ?? null },
  };
}

/// reads: the hook's books (copied, remainingToday, limits). executor: buy, sell, relay.
/// send(push, payload, options): the notification relay.
export function createSpotEngine({ store, reads, executor, desk, send = async () => {}, now = Date.now, logger = console, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) }) {
  const busy = new Map(); // wallet -> promise chain, so one wallet's copies run in order
  const leadersInFlight = new Set();

  function serial(wallet, work) {
    const run = (busy.get(wallet) ?? Promise.resolve()).then(work, work);
    const tail = run.catch(() => {});
    busy.set(wallet, tail);
    tail.then(() => { if (busy.get(wallet) === tail) busy.delete(wallet); });
    return run;
  }

  async function record(copier, row) {
    const entry = { at: now(), ...row };
    await store.pipeline([["LPUSH", S.log(copier.wallet), JSON.stringify(entry)], ["LTRIM", S.log(copier.wallet), 0, SPOT_LOG_LIMIT - 1]]);
    if (copier.push?.token && row.status !== "skipped") {
      const payload = spotPayload(entry);
      if (payload) await send(copier.push, payload, { collapseId: `spot-${entry.at}`.slice(0, 64) }).catch(() => {});
    }
  }

  async function freshCopier(wallet) {
    return parse(await store.get(S.copier(wallet)));
  }

  async function writeCopier(copier) {
    await store.set(S.copier(copier.wallet), JSON.stringify(copier));
  }

  async function failed(copier, row) {
    const next = { ...copier, failures: (copier.failures ?? 0) + 1 };
    await record(next, row);
    if (next.failures >= FAILURES_TO_PAUSE) {
      next.paused = true;
      next.pausedBy = "failures";
      await record(next, { status: "paused", detail: `${FAILURES_TO_PAUSE} copies in a row didn't go through. Check your AUSD, then resume.` });
    }
    await writeCopier(next);
  }

  async function succeeded(copier) {
    if (copier.failures) await writeCopier({ ...copier, failures: 0 });
  }

  async function underHourlyLimit(wallet) {
    const hour = Math.floor(now() / 3_600_000);
    const count = await store.incr(S.hourly(wallet, hour));
    if (count === 1) await store.expire(S.hourly(wallet, hour), 3600);
    return count <= TRADES_PER_HOUR;
  }

  async function copyBuy(copier, leader, event, entry, ledger) {
    const rules = entry.rules;
    const [copiedRaw, remainingTodayRaw, limits] = await Promise.all([
      reads.copied(copier.wallet, event.token), reads.remainingToday(copier.wallet), reads.limits(copier.wallet),
    ]);
    const base = { leader, token: event.token, symbol: event.symbol, side: "buy" };
    const decision = buyDecision({ event, rules, holdsCopy: copiedRaw > 0n, remainingTodayRaw, perTradeRaw: limits.perTrade });
    if (decision.skip) return record(copier, { ...base, status: "skipped", detail: decision.skip });
    if (!(await underHourlyLimit(copier.wallet))) return record(copier, { ...base, status: "skipped", detail: `More than ${TRADES_PER_HOUR} copies this hour` });
    const decimals = ledger.positions?.[event.token]?.decimals;
    try {
      const done = await executor.buy({ wallet: copier.wallet, token: event.token, amount: decision.amount, slippageBps: rules.slippageBps, id: eventId(event) });
      await record(copier, { ...base, status: "copied", ausd: ausdOf(decision.amount), amount: units(done.received, decimals), hash: done.hash });
      await succeeded(copier);
    } catch (error) {
      if (error instanceof SpotRefusal && error.kind === "skipped") return record(copier, { ...base, status: "skipped", detail: error.message });
      await failed(copier, { ...base, status: "failed", detail: error instanceof SpotRefusal ? error.message : reasonOf(error), hash: error.hash ?? null });
    }
  }

  async function copySell(copier, leader, event, entry, ledger) {
    const copiedRaw = await reads.copied(copier.wallet, event.token);
    const position = ledger.positions?.[event.token];
    const leftAfter = (position?.holding ?? 0) + (position?.unpriced ?? 0);
    const decision = sellDecision({ event, rules: entry.rules, copiedRaw, leftAfter });
    const base = { leader, token: event.token, symbol: event.symbol, side: "sell" };
    if (decision.skip !== undefined) return decision.skip ? record(copier, { ...base, status: "skipped", detail: decision.skip }) : null;
    let slippageBps = entry.rules.slippageBps;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const done = await executor.sell({ wallet: copier.wallet, token: event.token, amount: decision.amount, slippageBps, id: `${eventId(event)}:${attempt}` });
        await record(copier, { ...base, status: "copied", amount: units(decision.amount, position?.decimals), ausd: ausdOf(done.ausd), hash: done.hash, detail: decision.all ? "All of the copy" : null });
        return succeeded(copier);
      } catch (error) {
        if (attempt === 0 && !(error instanceof SpotRefusal && error.kind === "skipped")) {
          slippageBps = Math.min(3000, slippageBps * 2);
          await sleep(SELL_RETRY_MS);
          continue;
        }
        if (error instanceof SpotRefusal && error.kind === "skipped") return record(copier, { ...base, status: "skipped", detail: error.message });
        return failed(copier, { ...base, status: "failed", detail: error instanceof SpotRefusal ? error.message : reasonOf(error), hash: error.hash ?? null });
      }
    }
    return null;
  }

  async function play(wallet, leader, event, ledger) {
    const copier = await freshCopier(wallet);
    if (!live(copier, now())) return;
    const entry = copier.leaders?.[leader];
    if (!entry) return;
    if (event.time < (entry.since ?? 0)) return; // trades from before this leader was copied
    if (await store.get(S.halt)) return record(copier, { leader, token: event.token, symbol: event.symbol, side: event.side, status: "skipped", detail: "Desk paused all copying" });
    return event.side === "buy" ? copyBuy(copier, leader, event, entry, ledger) : copySell(copier, leader, event, entry, ledger);
  }

  async function leaders() {
    const addresses = await store.smembers(S.leaders);
    if (addresses.length === 0) return 0;
    const [ledgers, seen] = await Promise.all([store.mget(addresses.map(ledgerKey)), store.mget(addresses.map(S.seen))]);
    let played = 0;
    await Promise.all(addresses.map(async (leader, index) => {
      if (leadersInFlight.has(leader)) return;
      const ledger = parse(ledgers[index]);
      if (!ledger) return;
      const marker = JSON.stringify(newestMarker(ledger));
      if (seen[index] === marker) return;
      if (seen[index] == null) { await store.set(S.seen(leader), marker); return; } // history isn't copied
      const events = walletEvents(parse(seen[index]), ledger, { minUsd: 0 });
      leadersInFlight.add(leader);
      try {
        const wallets = events.length ? await store.smembers(S.followers(leader)) : [];
        await Promise.all(wallets.map((wallet) => serial(wallet, async () => {
          for (const event of events) {
            try { await play(wallet, leader, event, ledger); } catch (error) { logger.error?.(`copyd: spot ${wallet} ${error.message}`); }
          }
        })));
        played += events.length * wallets.length;
        await store.set(S.seen(leader), marker);
      } finally {
        leadersInFlight.delete(leader);
      }
    }));
    return played;
  }

  async function jobs() {
    let done = 0;
    for (let i = 0; i < 5; i += 1) {
      const text = await store.lpop(S.jobs);
      if (!text) break;
      const job = parse(text);
      if (!job) continue;
      done += 1;
      await serial(job.wallet, () => relayJob(job));
    }
    return done;
  }

  async function relayJob(job) {
    const copier = await freshCopier(job.wallet);
    if (!copier) return;
    try {
      const typed = batchFor({ kind: job.kind, wallet: job.wallet, desk: desk.address, hook: desk.hook, ...job.batch });
      const { hash } = await executor.relay({ wallet: job.wallet, typed, signature: job.batch.signature, authorization: job.authorization });
      const next = { ...copier, error: null, lastHash: hash };
      if (job.kind === "enable") Object.assign(next, { stage: "live", enabledAt: now(), paused: false, failures: 0 });
      if (job.kind === "limits") Object.assign(next, { limits: job.limits, expiry: job.expiry ?? copier.expiry });
      if (job.kind === "disable") Object.assign(next, { stage: "off", leaders: {}, disabledAt: now() });
      await writeCopier(next);
      if (job.kind === "disable") await unfollowAll(copier);
      if (job.kind !== "limits") await record(next, { status: job.kind === "enable" ? "on" : "off", hash, detail: job.kind === "enable" ? "Desk copies your leaders' token trades within your limits." : "Desk's key is off this wallet." });
    } catch (error) {
      const message = error instanceof SpotRefusal ? error.message : reasonOf(error);
      await writeCopier({ ...copier, stage: job.kind === "enable" ? "failed" : copier.stage, error: message });
      await record(copier, { status: "failed", side: job.kind, detail: message, hash: error.hash ?? null });
    }
  }

  async function unfollowAll(copier) {
    const commands = [["SREM", S.wallets, copier.wallet.toLowerCase()]];
    for (const leader of Object.keys(copier.leaders ?? {})) commands.push(["SREM", S.followers(leader), copier.wallet.toLowerCase()]);
    await store.pipeline(commands);
  }

  return {
    async tick() {
      const relayed = await jobs();
      const played = await leaders();
      return { relayed, played };
    },
    idle: () => Promise.all([...busy.values()]),
  };
}

/// One leader event, the same for every copier: its last trade's hash and the token and side.
export const eventId = (event) => `${String(event.hash).slice(2, 18)}:${String(event.token).slice(2, 12)}:${event.side}`;
