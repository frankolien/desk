/// A wallet's transfers on Monad, from Etherscan's V2 API, named in Desk's terms.
///
/// The key stays here. Transfers to and from Perpl's exchange, Agora's faucet and Relay's
/// depository are labelled as what they are, so a deposit reads "Deposited to Perpl"
/// rather than "Sent to 0x1964…".
import { redisStore } from "./_store.mjs";
import { walletResource } from "./_wallet-resource.mjs";

const ETHERSCAN = "https://api.etherscan.io/v2/api";

export const NETWORKS = {
  testnet: { chainId: 10143, symbol: "MON" },
  mainnet: { chainId: 143, symbol: "MON" },
};

const COUNTERPARTIES = {
  "0x1964c32f0be608e7d29302aff5e61268e72080cc": "perpl",
  "0x34b6552d57a35a1d042ccae1951bd1c370112a6f": "perpl",
  "0xd236c18d274e54faccc3dd9dda4b27965a73ee6c": "faucet",
  "0x4cd00e387622c35bddb9b4c962c136462338bc31": "relay",
};

const validAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(value);
const validSolana = (value) => /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(value);

export function formatUnits(raw, decimals) {
  if (!/^\d+$/.test(String(raw ?? "")) || !Number.isInteger(decimals) || decimals < 0) return null;
  const padded = String(raw).padStart(decimals + 1, "0");
  const whole = padded.slice(0, padded.length - decimals).replace(/^0+(?=\d)/, "");
  const fraction = decimals ? padded.slice(-decimals).replace(/0+$/, "") : "";
  return fraction ? `${whole}.${fraction}` : whole;
}

/// One entry per transfer the wallet took part in, newest first.
export function normalize({ address, native = [], tokens = [], nativeSymbol }) {
  const me = address.toLowerCase();
  const entries = [];
  const push = (row, symbol, decimals, contract) => {
    const from = String(row.from).toLowerCase();
    const to = String(row.to).toLowerCase();
    if (from !== me && to !== me) return;
    const direction = from === me ? "sent" : "received";
    const counterparty = direction === "sent" ? to : from;
    const amount = formatUnits(row.value, decimals);
    if (amount === null || amount === "0") return;
    entries.push({
      hash: row.hash,
      time: Number(row.timeStamp) * 1000,
      direction,
      counterparty,
      label: COUNTERPARTIES[counterparty] ?? null,
      symbol,
      amount,
      token: contract,
    });
  };
  for (const row of native) {
    if (row.isError === "1") continue;
    push(row, nativeSymbol, 18, null);
  }
  for (const row of tokens) {
    const decimals = Number(row.tokenDecimal);
    if (!row.tokenSymbol || !Number.isInteger(decimals)) continue;
    push(row, row.tokenSymbol, decimals, String(row.contractAddress).toLowerCase());
  }
  return entries.sort((a, b) => b.time - a.time).slice(0, 100);
}

async function list(fetchImpl, chainId, action, address, key) {
  const url = `${ETHERSCAN}?chainid=${chainId}&module=account&action=${action}&address=${address}`
    + `&page=1&offset=50&sort=desc&apikey=${key}`;
  const response = await fetchImpl(url);
  const body = await response.json();
  // "No transactions found" arrives as status 0 with an empty array, and is an answer.
  if (Array.isArray(body.result)) return body.result;
  throw new Error("etherscan");
}

export function createHandler(fetchImpl = fetch, key = () => process.env.ETHERSCAN_API_KEY, { store = redisStore(), wallet = walletResource } = {}) {
  return async function handler(req, res) {
    res.setHeader("Cache-Control", "private, no-store");
    if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
    const address = String(req.query.address || "");

    if (req.query.view === "wallet") {
      if (!validAddress(address) && !validSolana(address)) return res.status(400).json({ error: "A wallet address is required." });
      try {
        const body = await wallet(address, {
          chainIndex: String(req.query.chainIndex || "143"), contract: String(req.query.contract || ""), store, fetchImpl,
        });
        res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=300");
        return res.status(200).json(body);
      } catch (error) {
        return res.status(502).json({ error: "The wallet could not be read right now.", detail: error.message });
      }
    }

    const network = NETWORKS[String(req.query.network || "")];
    if (!validAddress(address) || !network) {
      return res.status(400).json({ error: "A wallet address and network are required." });
    }
    const apiKey = key();
    if (!apiKey) return res.status(503).json({ error: "Activity is not configured.", reason: "not-configured" });
    try {
      const [native, tokens] = await Promise.all([
        list(fetchImpl, network.chainId, "txlist", address, apiKey),
        list(fetchImpl, network.chainId, "tokentx", address, apiKey),
      ]);
      return res.status(200).json({
        entries: normalize({ address, native, tokens, nativeSymbol: network.symbol }),
      });
    } catch {
      return res.status(502).json({ error: "Activity could not be read right now." });
    }
  };
}

export default createHandler();
