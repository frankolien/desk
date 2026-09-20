import { rpcEndpoint } from "./_chains.mjs";
import { okxConfigured, okxPost } from "./_okx.mjs";

/// What a wallet holds of the tokens it bought through Desk: the balance read from each
/// token's own chain, and the price OKX quotes for it now.
///
/// The app keeps the list of what was bought; this reads the chain for how much is
/// still held, so a token sent elsewhere or sold shows as what it is rather than as
/// what was paid for.
///
///   GET /api/token-details?view=holdings&address=0x…&items=<chainIndex>:<contract>,…   (up to 20)
///
/// A view on token-details rather than a function of its own: the Hobby plan allows
/// twelve functions per deployment and this would have been the thirteenth.

const BALANCE_OF = "0x70a08231";
const DECIMALS = "0x313ce567";
const MAX_ITEMS = 20;

/// A balance in the token's own units, from the raw integer and its decimals, written
/// with as many places as the amount needs and no more. Truncated, never rounded up.
export function describeHolding(rawHex, decimals, price) {
  if (typeof rawHex !== "string" || !/^0x[0-9a-fA-F]*$/.test(rawHex)) return null;
  const raw = BigInt(rawHex === "0x" ? "0x0" : rawHex);
  const scale = 10n ** BigInt(decimals);
  const whole = raw / scale;
  const fraction = (raw % scale).toString().padStart(decimals, "0");
  const shown = fraction.slice(0, 6).replace(/0+$/, "");
  const balance = shown ? `${whole}.${shown}` : String(whole);
  const units = Number(raw) / Number(scale);
  const value = price == null || !Number.isFinite(price) ? null : units * price;
  return { balance, units, price: price ?? null, value };
}

function parseItems(text) {
  return String(text ?? "")
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .slice(0, MAX_ITEMS)
    .map((entry) => {
      const [chainIndex, contract] = entry.split(":");
      return chainIndex && contract ? { chainIndex, contract: contract.toLowerCase() } : null;
    })
    .filter(Boolean);
}

async function rpcBatch(endpoint, calls) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(calls.map((call, id) => ({ jsonrpc: "2.0", id, method: "eth_call", params: [call, "latest"] }))),
  });
  if (!response.ok) throw new Error(`rpc ${response.status}`);
  const rows = await response.json();
  return Array.isArray(rows) ? rows.sort((a, b) => a.id - b.id).map((row) => row.result ?? null) : [];
}

async function prices(items) {
  if (!okxConfigured() || items.length === 0) return new Map();
  try {
    const rows = await okxPost("/api/v6/dex/market/price-info",
      items.map(({ chainIndex, contract }) => ({ chainIndex, tokenContractAddress: contract })));
    const map = new Map();
    for (const row of Array.isArray(rows) ? rows : []) {
      const key = `${row.chainIndex}:${String(row.tokenContractAddress ?? "").toLowerCase()}`;
      const price = Number(row.price);
      if (Number.isFinite(price)) map.set(key, price);
    }
    return map;
  } catch {
    return new Map();
  }
}

export async function handleHoldings(req, res) {
  const address = String(req.query.address ?? "").toLowerCase();
  const items = parseItems(req.query.items);
  if (!/^0x[0-9a-f]{40}$/.test(address)) {
    res.status(400).json({ error: "address must be an EVM address" });
    return;
  }
  const padded = address.slice(2).padStart(64, "0");
  const priceMap = await prices(items);

  const byChain = new Map();
  for (const item of items) {
    if (!byChain.has(item.chainIndex)) byChain.set(item.chainIndex, []);
    byChain.get(item.chainIndex).push(item);
  }

  const holdings = [];
  await Promise.all([...byChain].map(async ([chainIndex, chainItems]) => {
    const endpoint = rpcEndpoint(chainIndex);
    let results = null;
    if (endpoint) {
      try {
        results = await rpcBatch(endpoint, chainItems.flatMap(({ contract }) => [
          { to: contract, data: BALANCE_OF + padded },
          { to: contract, data: DECIMALS },
        ]));
      } catch {
        results = null;
      }
    }
    chainItems.forEach(({ contract }, index) => {
      const rawBalance = results?.[index * 2] ?? null;
      const rawDecimals = results?.[index * 2 + 1] ?? null;
      const decimals = rawDecimals && /^0x[0-9a-fA-F]+$/.test(rawDecimals) ? Number(BigInt(rawDecimals)) : null;
      const price = priceMap.get(`${chainIndex}:${contract}`) ?? null;
      const described = rawBalance && decimals != null && decimals <= 36
        ? describeHolding(rawBalance, decimals, price)
        : null;
      holdings.push({ chainIndex, contract, readable: described != null, ...(described ?? { balance: null, units: null, price, value: null }) });
    });
  }));

  res.setHeader("cache-control", "public, max-age=15, stale-while-revalidate=60");
  res.status(200).json({ observedAt: Date.now(), holdings });
}
