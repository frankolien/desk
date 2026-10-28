/// How much of a token can actually be sold, from the pools DexScreener indexes. OKX's
/// liquidity figure misses pools on DEXes it doesn't index: CHOG's nad.fun pool held about
/// $88K while OKX reported $6.6K, so Desk called a tradeable token's liquidity thin.
///
/// Only pools against the chain's own coin or a major stablecoin count, matched by address:
/// a pool against a token someone named "USDC" could show any depth it likes.

const DEX_CHAIN = {
  "1": "ethereum", "10": "optimism", "56": "bsc", "137": "polygon", "143": "monad", "8453": "base",
  "42161": "arbitrum", "43114": "avalanche", "501": "solana",
};

const RESERVES = {
  "143": ["0x3bd359c1119da7da1d913d1c4d2b7c461115433a", "0x754704bc059f8c67012fed69bc8a327a5aafb603", "0x00000000efe302beaa2b3e6e1b18d08d69a9012a"],
  "1": ["0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "0xdac17f958d2ee523a2206206994597c13d831ec7", "0x6b175474e89094c44da98b954eedeac495271d0f"],
  "8453": ["0x4200000000000000000000000000000000000006", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"],
  "56": ["0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c", "0x55d398326f99059ff775485246999027b3197955", "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d"],
  "42161": ["0x82af49447d8a07e3bd95bd0d56f35241523fbab1", "0xaf88d065e77c8cc2239327c5edb3a432268e5831", "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9"],
  "10": ["0x4200000000000000000000000000000000000006", "0x0b2c639c533813f4aa9d7837caf62653d097ff85", "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58"],
  "137": ["0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270", "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", "0xc2132d05d31c914a87c6611c10748aeb04b58e8f"],
  "43114": ["0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7", "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e", "0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7"],
  "501": ["So11111111111111111111111111111111111111112", "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"],
};

const KEEP_S = 120;
const BATCH = 30;
const key = (chainIndex, address) => `pools1:${chainIndex}:${chainIndex === "501" ? address : address.toLowerCase()}`;
const same = (chainIndex, a, b) => (chainIndex === "501" ? a === b : String(a).toLowerCase() === String(b).toLowerCase());

/// One token's pools out of DexScreener's pairs: the depth of those against a reserve asset,
/// how many there are, and every pool address, which is never a holder worth counting.
export function poolsOf(chainIndex, token, pairs) {
  const reserves = new Set(RESERVES[chainIndex] ?? []);
  const reserve = (address) => reserves.has(chainIndex === "501" ? address : String(address ?? "").toLowerCase());
  let usd = 0;
  let pools = 0;
  const addresses = [];
  for (const pair of pairs) {
    const base = pair?.baseToken?.address, quote = pair?.quoteToken?.address;
    const other = same(chainIndex, base, token) ? quote : same(chainIndex, quote, token) ? base : null;
    if (!other) continue;
    if (pair.pairAddress) addresses.push(chainIndex === "501" ? pair.pairAddress : String(pair.pairAddress).toLowerCase());
    const depth = Number(pair?.liquidity?.usd);
    if (!reserve(other) || !Number.isFinite(depth) || depth <= 0) continue;
    usd += depth;
    pools += 1;
  }
  return { usd, pools, addresses };
}

/// Pools for up to thirty tokens a call, cached two minutes each. A token DexScreener can't
/// answer for is simply missing from the result: callers fall back to OKX's figure.
export async function poolsFor(chainIndex, addresses, { fetchImpl = fetch, store = null, timeoutMs = 2_500 } = {}) {
  const chain = DEX_CHAIN[chainIndex];
  const out = new Map();
  if (!chain || !RESERVES[chainIndex]) return out;
  const wanted = [...new Set(addresses.filter(Boolean))];
  const cached = store && wanted.length ? await store.mget(wanted.map((a) => key(chainIndex, a))).catch(() => wanted.map(() => null)) : wanted.map(() => null);
  const missing = [];
  wanted.forEach((address, i) => {
    try { if (cached[i]) { out.set(address, JSON.parse(cached[i])); return; } } catch {}
    missing.push(address);
  });
  const fresh = [];
  for (let start = 0; start < missing.length; start += BATCH) {
    const group = missing.slice(start, start + BATCH);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchImpl(`https://api.dexscreener.com/tokens/v1/${chain}/${group.join(",")}`, { signal: controller.signal, headers: { accept: "application/json" } });
      const pairs = response.ok ? await response.json() : null;
      if (!Array.isArray(pairs)) continue;
      for (const address of group) {
        const found = poolsOf(chainIndex, address, pairs);
        out.set(address, found);
        fresh.push([key(chainIndex, address), JSON.stringify(found), KEEP_S]);
      }
    } catch {
      // Unanswered tokens keep OKX's figure.
    } finally {
      clearTimeout(timer);
    }
  }
  if (store && fresh.length) store.setMany(fresh, KEEP_S).catch(() => {});
  return out;
}

/// The depth to report: the larger of OKX's figure and the reserve-asset pools'. Neither
/// source sees every DEX, and a pool one of them misses is still a pool.
export function deeper(okxLiquidity, pools) {
  const okx = Number.isFinite(okxLiquidity) && okxLiquidity > 0 ? okxLiquidity : null;
  const dex = pools && pools.usd > 0 ? pools.usd : null;
  if (okx == null) return dex;
  if (dex == null) return okx;
  return Math.max(okx, dex);
}

/// A list of tokens (chainIndex, contract, liquidity) with each liquidity deepened from its
/// pools: one DexScreener call per chain for up to thirty tokens.
export async function withPoolDepth(tokens, options = {}) {
  const byChain = new Map();
  for (const token of tokens) {
    if (!token?.contract) continue;
    if (!byChain.has(token.chainIndex)) byChain.set(token.chainIndex, []);
    byChain.get(token.chainIndex).push(token.contract);
  }
  const answers = await Promise.all([...byChain].map(([chainIndex, list]) => poolsFor(chainIndex, list, options).catch(() => new Map())));
  const found = new Map();
  [...byChain.keys()].forEach((chainIndex, i) => answers[i].forEach((pools, contract) => found.set(`${chainIndex}:${contract}`, pools)));
  return tokens.map((token) => {
    const depth = deeper(token?.liquidity, found.get(`${token?.chainIndex}:${token?.contract}`));
    return depth == null || depth === token.liquidity ? token : { ...token, liquidity: depth };
  });
}
