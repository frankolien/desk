import { okxConfigured, okxGet } from "./_okx.mjs";

/// What a wallet holds on one chain, read from OKX's wallet balance API: total value,
/// the largest holdings, and how much of one particular token it holds.
///
///   GET /api/token-details?view=wallet&address=0x…&chainIndex=143&contract=0x…
///
/// A view on token-details for the same reason holdings is: the twelve-function limit.

const MAX_ROWS = 8;

const number = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

/// Rows from OKX to the shape the app reads. Risk-flagged tokens are dropped; the rest
/// sort by value with the unpriced at the end.
export function describeWallet(rows, contract) {
  const wanted = String(contract ?? "").toLowerCase();
  const assets = [];
  for (const row of Array.isArray(rows) ? rows : []) {
    for (const asset of row?.tokenAssets ?? []) {
      if (String(asset?.isRiskToken) === "true" || asset?.isRiskToken === true) continue;
      const balance = number(asset?.balance);
      if (balance == null || balance <= 0) continue;
      const price = number(asset?.tokenPrice);
      assets.push({
        contract: String(asset?.tokenContractAddress ?? "").toLowerCase(),
        symbol: String(asset?.symbol ?? "").trim() || "?",
        balance,
        value: price == null ? null : balance * price,
      });
    }
  }
  assets.sort((a, b) => (b.value ?? -1) - (a.value ?? -1));
  const held = assets.find((asset) => asset.contract === wanted) ?? null;
  const portfolio = assets.reduce((sum, asset) => sum + (asset.value ?? 0), 0);
  return {
    portfolio: assets.some((asset) => asset.value != null) ? portfolio : null,
    held: held ? { balance: held.balance, value: held.value } : null,
    holdings: assets.slice(0, MAX_ROWS),
  };
}

export async function handleWallet(req, res) {
  const address = String(req.query.address ?? "").toLowerCase();
  const chainIndex = String(req.query.chainIndex ?? "");
  const contract = String(req.query.contract ?? "");
  if (!/^0x[0-9a-f]{40}$/.test(address) || !/^\d{1,10}$/.test(chainIndex)) {
    return res.status(400).json({ error: "An EVM address and a chain are required." });
  }
  if (!okxConfigured()) return res.status(503).json({ error: "Wallet reads aren't configured on this server." });
  try {
    const rows = await okxGet("/api/v6/dex/balance/all-token-balances-by-address", {
      address, chains: chainIndex, excludeRiskToken: "0",
    });
    res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=120");
    return res.status(200).json({ address, chainIndex, observedAt: Date.now(), ...describeWallet(rows, contract) });
  } catch (error) {
    return res.status(502).json({ error: error.message });
  }
}
