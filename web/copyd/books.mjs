/// A trader's book read off the exchange contract, in the shape the copy engine diffs: one
/// position per symbol, numbers as the app parses them from /api/traders?view=following. An
/// unreadable book is `{unreadable: true}`, never an empty one: one RPC timeout read as "no
/// positions" once closed every live copy and reopened it on the next read (audit C1).
import { describePosition, perpIdsFromBitmap, noAccount } from "../api/traders.mjs";
import { marketFromContext } from "./planner.mjs";

const finite = (text) => {
  const value = Number(text);
  return Number.isFinite(value) ? value : NaN;
};

/// `markets` maps market id to the context's raw market, open markets only.
export async function readTrader(chain, markets, address) {
  let account;
  try {
    account = await chain.accountByAddress(address);
  } catch (error) {
    return noAccount(error) ? { accountId: null, balance: 0, portfolio: 0, positions: {} } : { unreadable: true };
  }
  if (!account || account.accountId === 0n) return { accountId: null, balance: 0, portfolio: 0, positions: {} };
  const ids = perpIdsFromBitmap(account.positions).filter((id) => markets.has(id));
  let found;
  try {
    // A mark the venue would not price is not a close: openPosition falls back to the entry.
    found = await Promise.all(ids.map((id) => chain.openPosition(id, account.accountId)));
  } catch {
    return { unreadable: true };
  }
  const balance = Number(account.balanceCNS ?? 0n) / 1_000_000;
  const positions = {};
  let held = 0;
  found.forEach((entry, index) => {
    if (!entry) return;
    const raw = markets.get(ids[index]);
    const described = describePosition(entry.row, entry.mark, { ...raw, name: raw.name ?? raw.symbol });
    const size = finite(described.size), entry_ = finite(described.entry), mark = finite(described.mark);
    if (!(size > 0) || !(entry_ > 0) || !(mark >= 0)) return;
    const collateral = Number.isFinite(finite(described.collateral)) ? finite(described.collateral) : 0;
    const pnl = Number.isFinite(finite(described.pnl)) ? finite(described.pnl) : 0;
    const leverage = described.leverage != null && Number.isFinite(described.leverage) && described.leverage > 0 ? described.leverage : null;
    const symbol = marketFromContext(raw).symbol;
    positions[symbol] = { symbol, side: described.side, size, entry: entry_, mark, collateral, leverage, marketId: ids[index] };
    held += collateral + pnl;
  });
  return { accountId: String(account.accountId), balance, portfolio: balance + held, positions };
}
