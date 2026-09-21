import { CHAINS } from "./_chains.mjs";
import { hypersyncClient } from "./_history.mjs";
import { resolveIdentities } from "./_identity.mjs";
import { TRACKED_KEY, indexWallet, ledgerKey, summarize } from "./_ledger.mjs";
import { currentPrices, describeWallet, logosFor, metaReader, priceReader, walletBalances } from "./_wallet.mjs";

/// Everything Desk knows about a wallet, in one answer: who it is, what it holds on every
/// chain OKX reads, and its trade ledger on Monad with realised and unrealised PnL.
///
///   GET /api/activity?view=wallet&address=0x…[&chainIndex=143&contract=0x…]
///
/// The ledger is built on first sight, within this function's budget, and continued
/// by the worker afterwards; `ledger.status` says which. A page never waits on the
/// chain for balances or identity.

const MONAD = "143";
const BACKFILL_BLOCKS = 45 * 216_000;
const INDEX_BUDGET_MS = 25_000;
const MAX_TRACKED = 2_000;

export async function walletResource(address, { chainIndex = MONAD, contract = "", store, fetchImpl = fetch, chain = null, ens = null, hypersync = hypersyncClient(), now = Date.now } = {}) {
  const wanted = address.toLowerCase();
  const chains = Object.keys(CHAINS).filter((index) => CHAINS[index].rpc !== null && index !== "501");

  const [identities, balances] = await Promise.all([
    resolveIdentities([wanted], { fetchImpl, chain, store, ens }).catch(() => ({})),
    balancesAcross(wanted, chains, chainIndex),
  ]);
  const identity = identities[wanted] ?? null;
  const wallet = balances ? describeWallet(balances, contract) : { portfolio: null, chains: [], held: null, holdings: [] };
  if (contract) {
    const match = wallet.holdings.find((row) => row.chainIndex === chainIndex && row.contract === contract.toLowerCase());
    wallet.held = match ? { balance: match.balance, value: match.value } : null;
  }

  const ledger = await monadLedger(wanted, { store, hypersync, now });
  const labels = walletLabels({ identity, ledger, holdings: wallet.holdings, now: now() });
  const logos = await logosFor([
    ...wallet.holdings.map((row) => ({ chainIndex: row.chainIndex, contract: row.contract, symbol: row.symbol })),
    ...(wallet.holdings.some((row) => row.contract === "") ? [{ chainIndex: "143", contract: "" }] : []),
    ...(ledger.tokens ?? []).map((row) => ({ chainIndex: MONAD, contract: row.token, symbol: row.symbol })),
  ], { store });
  return { address: wanted, observedAt: now(), identity, ...wallet, ledger, labels, logos };
}

/// Descriptions, not verdicts: what the ledger says this wallet is like. Only a
/// sanctions source would justify a red label, and there is none in the stack.
export function walletLabels({ identity = null, ledger = {}, holdings = [], now = Date.now() } = {}) {
  const labels = [];
  const trades = ledger.trades ?? [];
  const day = trades.filter((trade) => now - trade.time < 86_400_000).length;
  const decided = (ledger.tokens ?? []).length;
  const sells = trades.filter((trade) => trade.side === "sell");
  const wins = sells.filter((trade) => trade.gain >= 0).length;
  if (day >= 50) labels.push({ code: "bot", text: `Trades like a bot: ${day} trades today` });
  if (ledger.status === "ready" && trades.length === 0 && (ledger.tokens ?? []).some((token) => token.unpriced > 0 && token.holding === 0)) {
    labels.push({ code: "contract", text: "Never sends a transaction — likely a contract" });
  }
  if (sells.length >= 20 && wins / sells.length >= 0.55 && (ledger.realized ?? 0) > 0) {
    labels.push({ code: "top", text: `Wins ${Math.round((wins / sells.length) * 100)}% of ${sells.length} closed trades` });
  }
  if (identity?.perplAccount) labels.push({ code: "perpl", text: `Trades perps here · Perpl #${identity.perplAccount}` });
  if (trades.length > 0) {
    const first = Math.min(...trades.map((trade) => trade.time));
    const days = (now - first) / 86_400_000;
    if (days < 7 && ledger.status === "ready") labels.push({ code: "fresh", text: `First trade seen ${Math.max(1, Math.round(days))} day${Math.round(days) === 1 ? "" : "s"} ago` });
  }
  void decided; void holdings;
  return labels;
}

/// OKX refuses a whole balance call if one chain in it is not one it serves, and which
/// chains those are changes. Small groups in parallel, with the chain in view and Monad
/// in a group of their own, so one refusal costs a few chains rather than all of them.
async function balancesAcross(address, chains, chainIndex) {
  const first = [...new Set([chainIndex, MONAD])];
  const rest = chains.filter((index) => !first.includes(index));
  const groups = [first];
  for (let start = 0; start < rest.length; start += 4) groups.push(rest.slice(start, start + 4));
  const answers = await Promise.all(groups.map((group) => walletBalances(address, group).catch(() => null)));
  const rows = answers.filter(Boolean).flat();
  return answers.some(Boolean) ? rows : null;
}

async function monadLedger(address, { store, hypersync, now }) {
  if (!store || !hypersync) return { status: "unavailable" };
  const price = priceReader({ store });
  const meta = metaReader({ store });
  let result;
  try {
    result = await indexWallet(address, {
      store, hypersync, price, meta, backfillBlocks: BACKFILL_BLOCKS, now, deadline: now() + INDEX_BUDGET_MS,
    });
  } catch (error) {
    const stored = await store.get(ledgerKey(address)).catch(() => null);
    // HyperSync's free tier rate-limits; the worker will get to this wallet, so the page
    // is told the history is on its way rather than that there is none.
    if (!stored) {
      store.sadd(TRACKED_KEY, address).catch(() => {});
      return { status: /429/.test(error.message) ? "indexing" : "unavailable", detail: error.message, behind: null };
    }
    result = { ledger: JSON.parse(stored), complete: false, behind: null };
  }
  store.sadd(TRACKED_KEY, address).catch(() => {});
  const tokens = Object.keys(result.ledger.positions);
  const prices = await currentPrices(MONAD, tokens);
  return {
    status: result.complete ? "ready" : "indexing",
    indexedAt: result.ledger.indexedAt,
    behind: result.behind,
    ...summarize(result.ledger, (token) => prices.get(token) ?? null, { now: now() }),
  };
}

export { MAX_TRACKED };
