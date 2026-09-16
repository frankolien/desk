// What Desk can quote on, in one place.
//
// This table used to be three disagreeing constants inside swap-quote: a native-symbol
// map, a separate 0x allowlist, and a `Chain ${n}` fallback in discovery. A token trending
// on a chain missing from any of them was rejected as malformed input, which is how every
// Arc and Robinhood token came to fail with "Valid quote parameters required".
//
// Names, native currencies and RPC endpoints are taken from the chain registry at
// chainid.network; the supported set is 0x's own published list. Both are facts that can
// be rechecked, not assumptions.

/// Chains the 0x Swap API v2 can price. Solana is quoted through OKX instead.
export const ZEROX_CHAINS = new Set([
  "1", "10", "56", "130", "137", "143", "146", "480", "999", "2741", "4217",
  "4663", "5000", "8453", "9745", "42161", "43114", "57073", "59144", "80094", "534352",
]);

/// Chain 999 is deliberately absent. 0x lists it as HyperEVM while the public registry
/// still answers with Wanchain Testnet, and a wrong RPC is worse than no RPC: quotes
/// still work there, only the native symbol and on-chain decimal lookup are unavailable.
export const CHAINS = {
  "1": { name: "Ethereum", symbol: "ETH", rpc: "https://ethereum-rpc.publicnode.com" },
  "10": { name: "OP Mainnet", symbol: "ETH", rpc: "https://mainnet.optimism.io" },
  "56": { name: "BNB Chain", symbol: "BNB", rpc: "https://bsc-rpc.publicnode.com" },
  "130": { name: "Unichain", symbol: "ETH", rpc: "https://mainnet.unichain.org" },
  "137": { name: "Polygon", symbol: "POL", rpc: "https://polygon-rpc.com" },
  "143": { name: "Monad", symbol: "MON", rpc: "https://rpc.monad.xyz" },
  "146": { name: "Sonic", symbol: "S", rpc: "https://rpc.soniclabs.com" },
  "196": { name: "X Layer", symbol: "OKB", rpc: null },
  "480": { name: "World Chain", symbol: "ETH", rpc: "https://worldchain-mainnet.g.alchemy.com/public" },
  "501": { name: "Solana", symbol: "SOL", rpc: "https://api.mainnet-beta.solana.com" },
  "999": { name: "HyperEVM", symbol: null, rpc: null },
  "2741": { name: "Abstract", symbol: "ETH", rpc: "https://api.mainnet.abs.xyz" },
  "4217": { name: "Tempo", symbol: "USD", rpc: "https://rpc.mainnet.tempo.xyz" },
  "4663": { name: "Robinhood Chain", symbol: "ETH", rpc: "https://rpc.mainnet.chain.robinhood.com" },
  "5000": { name: "Mantle", symbol: "MNT", rpc: "https://rpc.mantle.xyz" },
  "5042": { name: "Arc", symbol: "USDC", rpc: null },
  "8453": { name: "Base", symbol: "ETH", rpc: "https://mainnet.base.org" },
  "9745": { name: "Plasma", symbol: "XPL", rpc: "https://rpc.plasma.to" },
  "10143": { name: "Monad Testnet", symbol: "MON", rpc: null },
  "42161": { name: "Arbitrum One", symbol: "ETH", rpc: "https://arb1.arbitrum.io/rpc" },
  "43114": { name: "Avalanche", symbol: "AVAX", rpc: "https://api.avax.network/ext/bc/C/rpc" },
  "57073": { name: "Ink", symbol: "ETH", rpc: "https://rpc-gel.inkonchain.com" },
  "59144": { name: "Linea", symbol: "ETH", rpc: "https://rpc.linea.build" },
  "80094": { name: "Berachain", symbol: "BERA", rpc: "https://rpc.berachain.com" },
  "534352": { name: "Scroll", symbol: "ETH", rpc: "https://rpc.scroll.io" },
};

/// Every chain in this file's supported set is an 18-decimal native. Arc is the reminder
/// that this is not a law — its gas token is USDC — which is why an unlisted chain is
/// reported as unsupported rather than assumed to look like Ethereum.
export const EVM_NATIVE_ADDRESS = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
export const EVM_NATIVE_DECIMALS = 18;

export const SOLANA_NATIVE = {
  address: "11111111111111111111111111111111", symbol: "SOL", decimals: 9,
};

export function chainName(chainIndex) {
  return CHAINS[chainIndex]?.name || `Chain ${chainIndex}`;
}

/// Whether any configured provider can price this chain at all.
export function isQuotable(chainIndex) {
  return chainIndex === "501" || ZEROX_CHAINS.has(chainIndex);
}

/// The token paid with when buying, or received when selling.
export function nativeToken(chainIndex) {
  if (chainIndex === "501") return SOLANA_NATIVE;
  if (!ZEROX_CHAINS.has(chainIndex)) return null;
  return {
    address: EVM_NATIVE_ADDRESS,
    symbol: CHAINS[chainIndex]?.symbol ?? null,
    decimals: EVM_NATIVE_DECIMALS,
  };
}

export function rpcEndpoint(chainIndex) {
  return CHAINS[chainIndex]?.rpc ?? null;
}
