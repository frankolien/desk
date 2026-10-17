/// Spot copy's hands: quotes a copied buy or sell through Desk's API, checks the token can be
/// sold back, simulates the batch from Desk's key and sends it (docs/spot-copy.md). One key sends
/// for every wallet, so sends queue one at a time behind its nonce. An intent is written before
/// each send and never twice, so a restart can't send a copy again.
import { SPOT, approveCall, executeAsKeyData, executeSignedData, hookEvents, keyHashOf } from "./spot-chain.mjs";
import { sellsBack } from "./spot-rules.mjs";

export const SPOT_KEYS = {
  intent: (wallet, id) => `copy:spot:intent:${wallet.toLowerCase()}:${id}`,
};
const INTENT_TTL_S = 7 * 86_400;

const HOOK_NAMES = {
  OverTradeLimit: "Over your max per buy", OverDayLimit: "Today's limit is used up", NotCopied: "More than the copy holds",
  Unauthorized: "Desk's key is no longer on this wallet", KeyExpired: "Auto-Copy has expired on this wallet",
};
const HOOK_REASONS = new Set([...Object.values(HOOK_NAMES)]);

export class SpotRefusal extends Error {
  constructor(kind, message) { super(message); this.kind = kind; }
}

/// What a revert or a refused quote says, in a line for the log.
export function reasonOf(error) {
  const text = String(error?.shortMessage ?? error?.message ?? error);
  const named = text.match(/(OverTradeLimit|OverDayLimit|NotCopied|NotToWallet|NotSettler|NoFloor|NotAllowed|SellsForAUSDOnly|Unauthorized|KeyExpired)/);
  if (named) {
    return HOOK_NAMES[named[1]] ?? `Refused on-chain (${named[1]})`;
  }
  if (/insufficient|exceeds balance|TRANSFER_FROM_FAILED/i.test(text)) return "Not enough AUSD in the wallet";
  if (/slippage|TooMuchSlippage|minAmountOut/i.test(text)) return "The price moved past your slippage";
  return text.slice(0, 120);
}

/// chain: { simulate({to,data}), send({to,data,authorizationList?}) → hash, wait(hash) → receipt }.
/// quote({ kind, taker, sellToken, buyToken, sellAmount, slippageBps }) → Desk's copy quote view.
export function createSpotExecutor({ store, chain, quote, hook, desk, logger = console }) {
  const keyHash = keyHashOf(desk);
  let queue = Promise.resolve();
  const oneAtATime = (work) => {
    const run = queue.then(work, work);
    queue = run.catch(() => {});
    return run;
  };

  async function send({ wallet, id, calls, what }) {
    const key = SPOT_KEYS.intent(wallet, id);
    if (!(await store.set(key, JSON.stringify({ what, at: Date.now() }), { nx: true, ex: INTENT_TTL_S }))) {
      throw new SpotRefusal("skipped", "Already sent");
    }
    const data = executeAsKeyData(calls);
    try {
      await chain.simulate({ to: wallet, data });
    } catch (error) {
      await store.del(key).catch(() => {});
      const reason = reasonOf(error);
      throw Object.assign(new SpotRefusal("failed", reason), { route: !HOOK_REASONS.has(reason) && !/AUSD in the wallet/.test(reason) });
    }
    const hash = await oneAtATime(() => chain.send({ to: wallet, data }));
    await store.set(key, JSON.stringify({ what, hash, at: Date.now() }), { ex: INTENT_TTL_S }).catch(() => {});
    const receipt = await chain.wait(hash);
    if (receipt.status !== "success") throw Object.assign(new SpotRefusal("failed", "The copy reverted on-chain"), { hash });
    return { hash, events: hookEvents(receipt.logs, hook) };
  }

  /// A route can revert in simulation when the pools moved since the quote; one fresh quote
  /// gets a new route. A refusal from the hook or an empty wallet isn't retried.
  async function twice(attempt) {
    try { return await attempt(); } catch (error) {
      if (!(error instanceof SpotRefusal) || !error.route) throw error;
      return attempt();
    }
  }

  async function quoted(args) {
    try { return await quote(args); } catch (error) { throw new SpotRefusal("skipped", error.message || "No quote"); }
  }

  async function buyOnce({ wallet, token, amount, slippageBps, id }) {
    const q = await quoted({ kind: "quote", taker: wallet, sellToken: SPOT.ausd, buyToken: token, sellAmount: amount, slippageBps });
    const back = await quoted({ kind: "price", taker: wallet, sellToken: token, buyToken: SPOT.ausd, sellAmount: q.buyAmount, slippageBps });
    if (!sellsBack({ spentRaw: amount, backRaw: back.buyAmount })) {
      throw new SpotRefusal("skipped", "Can't sell it back for most of the price (tax, honeypot or no depth)");
    }
    const calls = [approveCall(SPOT.ausd, amount), { to: SPOT.holder, value: 0n, data: q.data }];
    const sent = await send({ wallet, id, calls, what: `buy ${token}` });
    const bought = sent.events.find((event) => event.name === "Bought");
    return { hash: sent.hash, received: bought?.received ?? BigInt(q.buyAmount), fee: BigInt(q.fee ?? 0) };
  }

  async function sellOnce({ wallet, token, amount, slippageBps, id }) {
    const q = await quoted({ kind: "quote", taker: wallet, sellToken: token, buyToken: SPOT.ausd, sellAmount: amount, slippageBps });
    const calls = [approveCall(token, amount), { to: SPOT.holder, value: 0n, data: q.data }];
    const sent = await send({ wallet, id, calls, what: `sell ${token}` });
    return { hash: sent.hash, ausd: BigInt(q.buyAmount), fee: BigInt(q.fee ?? 0) };
  }

  return {
    keyHash,

    /// AUSD → token. Returns { hash, received } in the token's base units.
    buy: (args) => twice(() => buyOnce(args)),

    /// Token → AUSD, no more than the hook records as copied. Returns { hash, ausd }.
    sell: (args) => twice(() => sellOnce(args)),

    /// The wallet's own signed batch (turning on, changing limits, turning off), with the EIP-7702
    /// authorization when the wallet doesn't run Calibur yet. Desk pays the gas.
    async relay({ wallet, typed, signature, authorization }) {
      const data = executeSignedData({ typed, signature });
      const authorizationList = authorization ? [authorization] : undefined;
      const hash = await oneAtATime(() => chain.send({ to: wallet, data, authorizationList }));
      const receipt = await chain.wait(hash);
      if (receipt.status !== "success") throw Object.assign(new SpotRefusal("failed", "The wallet's batch reverted"), { hash });
      logger.log?.(`copyd: spot relayed ${wallet} ${hash}`);
      return { hash };
    },
  };
}
