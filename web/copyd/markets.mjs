/// Perpl's public context per network: the open markets (ten minutes at a time) and their marks
/// (five seconds). A copier trades on its own network; on testnet a market's price is not the
/// mainnet trader's, so a live copy is sized at the venue it fills on.
import { NETWORKS } from "./perpl.mjs";

export function createMarketBook({ fetchImpl = fetch, now = Date.now, marketsMs = 10 * 60_000, marksMs = 5_000 } = {}) {
  const cache = new Map(); // network -> { at, body, pending }

  async function context(network, maxAge) {
    const held = cache.get(network);
    if (held?.body && now() - held.at < maxAge) return held.body;
    if (held?.pending) return held.pending;
    const pending = (async () => {
      const response = await fetchImpl(`${NETWORKS[network].base}/v1/pub/context`);
      if (!response.ok) throw new Error(`Perpl ${network} context ${response.status}`);
      const body = await response.json();
      cache.set(network, { at: now(), body });
      return body;
    })();
    cache.set(network, { ...held, pending });
    try { return await pending; } catch (error) { cache.set(network, { ...held, pending: null }); throw error; }
  }

  return {
    /// The open markets, by id, as the planner's marketFromContext reads them.
    async markets(network = "mainnet") {
      const body = await context(network, marketsMs);
      return new Map(body.markets.filter((m) => m.config?.is_open).map((m) => [m.id, m]));
    },
    /// A market's mark on its own venue, in price units, or null.
    async mark(network, marketId) {
      const body = await context(network, marksMs);
      const raw = body.markets.find((m) => m.id === marketId);
      const mark = raw?.state?.mrk;
      return mark > 0 ? mark / 10 ** raw.config.price_decimals : null;
    },
  };
}
