import { CHAINS } from "./_chains.mjs";
import { hypersyncClient } from "./_history.mjs";
import { resolveIdentities } from "./_identity.mjs";
import { TRACKED_KEY, indexWallet, ledgerKey, summarize } from "./_ledger.mjs";
import { currentPrices, describeWallet, metaReader, priceReader, walletBalances } from "./_wallet.mjs";

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
  return { address: wanted, observedAt: now(), identity, ...wallet, ledger };
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
