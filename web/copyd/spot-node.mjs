/// The live wiring for spot copy: Monad through viem, Desk's KMS key as the sender, and quotes
/// from Desk's API. Kept apart from the executor so tests run on stand-ins.
import { createPublicClient, createWalletClient, defineChain, http } from "viem";
import { CALIBUR_ABI, HOOK, SPOT, delegationOf, keyHashOf } from "./spot-chain.mjs";

export const monad = defineChain({
  id: SPOT.chainId, name: "Monad", nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.monad.xyz"] } },
});

export function monadClients({ rpc = process.env.MONAD_MAINNET_RPC || "https://rpc.monad.xyz", account }) {
  const transport = http(rpc, { retryCount: 2, timeout: 15_000 });
  const reader = createPublicClient({ chain: monad, transport });
  const writer = account ? createWalletClient({ chain: monad, transport, account }) : null;
  return { reader, writer };
}

/// `chain` for the executor: simulate and send as Desk's key, and wait for the receipt.
export function spotChain({ reader, writer }) {
  const account = writer.account;
  // One key, many senders (copies, any-chain sends): transactions leave one at a time so two
  // never take the same nonce.
  let queue = Promise.resolve();
  const oneAtATime = (work) => { const run = queue.then(work, work); queue = run.catch(() => {}); return run; };
  return {
    async simulate({ to, data }) {
      await reader.call({ account: account.address, to, data });
    },
    send({ to, data, authorizationList }) {
      return oneAtATime(async () => {
        const gas = await reader.estimateGas({ account: account.address, to, data, authorizationList });
        // Monad charges the gas limit, not the gas used: a tight margin is money.
        return writer.sendTransaction({ to, data, authorizationList, gas: (gas * 115n) / 100n });
      });
    },
    wait: (hash) => reader.waitForTransactionReceipt({ hash, timeout: 60_000 }),
  };
}

/// What the API and the engine read from a wallet: its code, nonces and the hook's books.
export function spotReads({ reader, hook, desk }) {
  const keyHash = keyHashOf(desk);
  return {
    async wallet(wallet) {
      const [code, transactions] = await Promise.all([
        reader.getCode({ address: wallet }).catch(() => "0x"),
        reader.getTransactionCount({ address: wallet }),
      ]);
      const delegation = delegationOf(code);
      const seq = delegation === "calibur"
        ? await reader.readContract({ address: wallet, abi: CALIBUR_ABI, functionName: "getSeq", args: [0n] })
        : 0n;
      const registered = delegation === "calibur"
        ? await reader.readContract({ address: wallet, abi: CALIBUR_ABI, functionName: "isRegistered", args: [keyHash] }).catch(() => false)
        : false;
      return { delegation, transactions, seq, registered };
    },
    copied: (wallet, token) => reader.readContract({ address: hook, abi: HOOK, functionName: "copied", args: [wallet, keyHash, token] }),
    remainingToday: (wallet) => reader.readContract({ address: hook, abi: HOOK, functionName: "remainingToday", args: [wallet, keyHash] }),
    limits: async (wallet) => {
      const [perTrade, perDay] = await reader.readContract({ address: hook, abi: HOOK, functionName: "limits", args: [wallet, keyHash] });
      return { perTrade, perDay };
    },
    balance: (address) => reader.getBalance({ address }),
  };
}

/// Desk's copy quote view, with CRON_SECRET.
export function apiQuote({ base = process.env.DESK_API, secret = process.env.CRON_SECRET, fetchImpl = fetch } = {}) {
  return async ({ kind, taker, sellToken, buyToken, sellAmount, slippageBps }) => {
    const query = new URLSearchParams({ view: "copy", kind, taker, sellToken, buyToken, sellAmount: String(sellAmount), slippageBps: String(slippageBps) });
    const response = await fetchImpl(`${base}/api/swap-quote?${query}`, { headers: { authorization: `Bearer ${secret}` } });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.reason === "no-liquidity" ? "Not enough liquidity to copy" : (body.error || `No quote (${response.status})`));
    return body;
  };
}
