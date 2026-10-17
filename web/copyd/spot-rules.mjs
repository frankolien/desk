/// Spot copy's decisions, with no I/O: whether a leader's buy is copied and for how much, and how
/// much of a copied position follows a leader's sell (docs/spot-copy.md). Amounts in rules are
/// AUSD (≈ USD); amounts on-chain are base units, as bigint.
import { ausdOf, ausdRaw } from "./spot-chain.mjs";

export { ausdOf, ausdRaw };

export const DEFAULT_SPOT_RULES = Object.freeze({
  sizing: "fixed", // or "match": the leader's size, up to maxPerBuy
  amount: 10,
  maxPerBuy: 25,
  copySells: true,
  buyOnce: true,
  minLeaderUsd: 250,
  maxLeaderUsd: null,
  slippageBps: 500,
});

/// A round trip that would hand back less than this share of the spend is refused: a sell tax,
/// a honeypot, or no depth to get out through.
export const ROUND_TRIP_FLOOR = 0.85;
const LEADER_SOLD_ALL = 0.95;

const finite = (value, name, { min = 0, max = Infinity, integer = false } = {}) => {
  const number = Number(value);
  if (!Number.isFinite(number) || number < min || number > max || (integer && !Number.isInteger(number))) {
    throw new RangeError(`${name} must be ${integer ? "a whole number " : ""}from ${min} to ${max}.`);
  }
  return number;
};

/// Rules from the phone, checked against the per-trade limit the wallet set on-chain.
export function checkedSpotRules(json, { perTradeAusd }) {
  if (typeof json !== "object" || json === null) throw new RangeError("The rules are incomplete.");
  // Left unset, the max per buy is the most the wallet approved on-chain, not a refusal.
  const rules = { ...DEFAULT_SPOT_RULES, maxPerBuy: Math.min(DEFAULT_SPOT_RULES.maxPerBuy, perTradeAusd), ...json };
  if (!["fixed", "match"].includes(rules.sizing)) throw new RangeError("Sizing must be fixed or match.");
  const out = {
    sizing: rules.sizing,
    amount: finite(rules.amount, "Amount per buy", { min: 1, max: 100_000 }),
    maxPerBuy: finite(rules.maxPerBuy, "Max per buy", { min: 1, max: 100_000 }),
    copySells: Boolean(rules.copySells),
    buyOnce: Boolean(rules.buyOnce),
    minLeaderUsd: finite(rules.minLeaderUsd, "Skip leader buys under", { max: 10_000_000 }),
    maxLeaderUsd: rules.maxLeaderUsd == null ? null : finite(rules.maxLeaderUsd, "Skip leader buys over", { min: 1, max: 100_000_000 }),
    slippageBps: finite(rules.slippageBps, "Slippage", { min: 10, max: 3_000, integer: true }),
  };
  if (out.sizing === "fixed" && out.amount > out.maxPerBuy) out.maxPerBuy = out.amount;
  if (out.maxPerBuy > perTradeAusd) {
    throw new RangeError(`${out.maxPerBuy} AUSD a buy is more than the ${perTradeAusd} AUSD you approved with Face ID.`);
  }
  if (out.maxLeaderUsd != null && out.maxLeaderUsd <= out.minLeaderUsd) throw new RangeError("Skip-over must be above skip-under.");
  return out;
}

/// A leader's buy (a `walletEvents` group of kind "buy" or "first") → `{ amount }` in AUSD base
/// units, or `{ skip }` with the reason shown in the log.
export function buyDecision({ event, rules, holdsCopy, remainingTodayRaw, perTradeRaw }) {
  if (event.value < rules.minLeaderUsd) return { skip: `Their buy was under $${rules.minLeaderUsd}` };
  if (rules.maxLeaderUsd != null && event.value > rules.maxLeaderUsd) return { skip: `Their buy was over $${rules.maxLeaderUsd}` };
  if (rules.buyOnce && holdsCopy) return { skip: "Already copied this token" };
  const wanted = rules.sizing === "match" ? Math.min(event.value, rules.maxPerBuy) : rules.amount;
  let amount = ausdRaw(wanted);
  if (amount > perTradeRaw) amount = perTradeRaw;
  if (amount > remainingTodayRaw) return { skip: "Today's limit is used up" };
  if (amount < ausdRaw(1)) return { skip: "Less than 1 AUSD to copy with" };
  return { amount };
}

/// A leader's sell → how much of the copy's position follows, in the token's base units. The
/// leader sold `event.amount` and holds `leftAfter`; the copy sells the same share of `copied`.
export function sellDecision({ event, rules, copiedRaw, leftAfter }) {
  if (!rules.copySells) return { skip: "Copying sells is off" };
  if (copiedRaw <= 0n) return { skip: null };
  const before = event.amount + Math.max(0, leftAfter);
  const share = event.kind === "close" || before <= 0 ? 1 : Math.min(1, event.amount / before);
  if (share >= LEADER_SOLD_ALL) return { amount: copiedRaw, all: true };
  const amount = (copiedRaw * BigInt(Math.round(share * 1_000_000))) / 1_000_000n;
  return amount > 0n ? { amount, all: false } : { skip: null };
}

/// Whether a quote back to AUSD for what the buy would bring is worth the spend.
export const sellsBack = ({ spentRaw, backRaw }) => Number(backRaw) >= Number(spentRaw) * ROUND_TRIP_FLOOR;
