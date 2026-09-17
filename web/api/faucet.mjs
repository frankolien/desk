import {
  createPublicClient, createWalletClient, encodeFunctionData, http,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { monadTestnet } from "viem/chains";

export const AUSD = "0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC";
export const AGORA_FAUCET = "0xd236c18D274E54FAccC3dd9DDA4b27965a73ee6C";

/// Matches the app's `hasSetupGas`, so a wallet the app calls unfunded is always dripped.
export const MON_THRESHOLD = 50_000_000_000_000_000n;
export const MON_DRIP = 100_000_000_000_000_000n;
/// Left in the faucet wallet so it can still pay for the AUSD claim it makes.
export const MON_RESERVE = 50_000_000_000_000_000n;
export const AUSD_MINIMUM = 100_000_000n;

const MIN_FEE_WEI = 100_000_000_000n;
const PRIORITY_FEE_WEI = 2_000_000_000n;
const RECENT_WINDOW_MS = 60_000;

const ERC20_ABI = [{
  type: "function", name: "balanceOf", stateMutability: "view",
  inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }],
}];
const FAUCET_ABI = [{
  type: "function", name: "requestFunds", stateMutability: "nonpayable",
  inputs: [{ name: "recipient", type: "address" }], outputs: [],
}];

const REVERTS = {
  "0x20e5bc67": "cooldown",
  "0x0949dab9": "already-funded",
  "0x5274afe7": "faucet-empty",
};

export function validRecipient(value) {
  return typeof value === "string" && /^0x[a-fA-F0-9]{40}$/.test(value)
    && !/^0x0{40}$/.test(value);
}

/// What a wallet should receive, decided from balances alone so it is testable without
/// a chain.
export function plan({ recipientMON, recipientAUSD, faucetMON }) {
  const needsMON = recipientMON < MON_THRESHOLD;
  return {
    mon: !needsMON ? "enough"
      : faucetMON >= MON_DRIP + MON_RESERVE ? "send" : "faucet-empty",
    ausd: recipientAUSD >= AUSD_MINIMUM ? "enough"
      : faucetMON >= (needsMON ? MON_DRIP + MON_RESERVE : MON_RESERVE) ? "claim" : "faucet-empty",
  };
}

export function revertReason(data) {
  if (typeof data !== "string") return null;
  return REVERTS[data.slice(0, 10).toLowerCase()] ?? null;
}

function revertData(error) {
  let cursor = error;
  while (cursor) {
    if (typeof cursor.data === "string") return cursor.data;
    if (typeof cursor.data?.data === "string") return cursor.data.data;
    cursor = cursor.cause;
  }
  return null;
}

export function chainDependencies(privateKey, rpcURL = monadTestnet.rpcUrls.default.http[0]) {
  const account = privateKeyToAccount(privateKey);
  const transport = http(rpcURL, { timeout: 8_000 });
  const reader = createPublicClient({ chain: monadTestnet, transport });
  const writer = createWalletClient({ account, chain: monadTestnet, transport });

  async function fees() {
    const block = await reader.getBlock();
    const base = block.baseFeePerGas ?? MIN_FEE_WEI;
    const cap = base * 2n + PRIORITY_FEE_WEI;
    return {
      maxFeePerGas: cap > MIN_FEE_WEI * 2n ? cap : MIN_FEE_WEI * 2n,
      maxPriorityFeePerGas: PRIORITY_FEE_WEI,
    };
  }

  return {
    async balances(recipient) {
      const [recipientMON, recipientAUSD, faucetMON] = await Promise.all([
        reader.getBalance({ address: recipient }),
        reader.readContract({ address: AUSD, abi: ERC20_ABI, functionName: "balanceOf", args: [recipient] }),
        reader.getBalance({ address: account.address }),
      ]);
      return { recipientMON, recipientAUSD, faucetMON };
    },

    async simulateClaim(recipient) {
      const data = encodeFunctionData({ abi: FAUCET_ABI, functionName: "requestFunds", args: [recipient] });
      try {
        const gas = await reader.estimateGas({ account: account.address, to: AGORA_FAUCET, data });
        return { ok: true, gas: (gas * 10_750n + 9_999n) / 10_000n };
      } catch (error) {
        return { ok: false, reason: revertReason(revertData(error)) ?? "claim-failed" };
      }
    },

    async nonce() {
      return reader.getTransactionCount({ address: account.address, blockTag: "pending" });
    },

    async sendMON(recipient, nonce) {
      return writer.sendTransaction({
        to: recipient, value: MON_DRIP, gas: 21_000n, nonce, ...(await fees()),
      });
    },

    async claimAUSD(recipient, gas, nonce) {
      const data = encodeFunctionData({ abi: FAUCET_ABI, functionName: "requestFunds", args: [recipient] });
      return writer.sendTransaction({ to: AGORA_FAUCET, data, gas, nonce, ...(await fees()) });
    },

    async confirmed(hash) {
      const receipt = await reader.waitForTransactionReceipt({ hash, timeout: 15_000, pollingInterval: 400 });
      return receipt.status === "success";
    },
  };
}

/// One wallet per minute per instance. Balance gating is the real limit: a wallet above
/// the thresholds is never paid, so this only stops a burst from racing the first read.
const recent = new Map();

export function throttled(key, now = Date.now(), memory = recent) {
  for (const [entry, at] of memory) if (now - at > RECENT_WINDOW_MS) memory.delete(entry);
  if (memory.has(key)) return true;
  memory.set(key, now);
  return false;
}

/// Sends from one wallet share a nonce sequence, so an instance issues them one request
/// at a time rather than letting two requests read the same pending nonce.
let sending = Promise.resolve();

function serially(work) {
  const turn = sending.then(work, work);
  sending = turn.catch(() => {});
  return turn;
}

export function createHandler(resolveDependencies, memory = recent) {
  return async function handler(req, res) {
    res.setHeader("Cache-Control", "private, no-store");
    if (req.method !== "POST") return res.status(405).json({ error: "POST required" });
    const body = typeof req.body === "string" ? safeJSON(req.body) : req.body;
    const recipient = body?.address;
    if (!validRecipient(recipient)) {
      return res.status(400).json({ error: "A wallet address is required.", reason: "invalid-address" });
    }

    const chain = resolveDependencies();
    if (!chain) {
      return res.status(503).json({ error: "The Desk faucet is not configured.", reason: "not-configured" });
    }
    if (throttled(recipient.toLowerCase(), Date.now(), memory)) {
      return res.status(429).json({ error: "This wallet was just funded.", reason: "too-soon" });
    }

    try {
      const decision = plan(await chain.balances(recipient));
      const result = { mon: { status: decision.mon }, ausd: { status: decision.ausd } };

      let claimGas = null;
      if (decision.ausd === "claim") {
        const simulation = await chain.simulateClaim(recipient);
        if (simulation.ok) claimGas = simulation.gas;
        else result.ausd = { status: simulation.reason === "already-funded" ? "enough" : "unavailable", reason: simulation.reason };
      }

      const pending = [];
      if (decision.mon === "send" || claimGas) await serially(async () => {
        let nonce = await chain.nonce();
        if (decision.mon === "send") {
          const hash = await chain.sendMON(recipient, nonce++);
          result.mon = { status: "sent", hash };
          pending.push(["mon", hash]);
        }
        if (claimGas) {
          const hash = await chain.claimAUSD(recipient, claimGas, nonce);
          result.ausd = { status: "sent", hash };
          pending.push(["ausd", hash]);
        }
      });

      const outcomes = await Promise.allSettled(pending.map(([, hash]) => chain.confirmed(hash)));
      outcomes.forEach((outcome, index) => {
        const [asset] = pending[index];
        if (outcome.status === "rejected") result[asset] = { ...result[asset], status: "pending" };
        else if (!outcome.value) result[asset] = { status: "unavailable", reason: "reverted" };
      });

      for (const asset of ["mon", "ausd"]) {
        if (result[asset].status === "faucet-empty") {
          result[asset] = { status: "unavailable", reason: "faucet-empty" };
        }
      }
      // Anything undelivered may be asked for again straight away: Agora's cooldown is
      // shared by every caller, so the wallet should not also wait out Desk's.
      if (result.mon.status === "unavailable" || result.ausd.status === "unavailable") {
        memory.delete(recipient.toLowerCase());
      }
      return res.status(200).json(result);
    } catch {
      memory.delete(recipient.toLowerCase());
      return res.status(502).json({ error: "The faucet could not reach Monad testnet.", reason: "chain-unavailable" });
    }
  };
}

function safeJSON(text) {
  try { return JSON.parse(text); } catch { return null; }
}

function productionDependencies() {
  const key = process.env.FAUCET_PRIVATE_KEY;
  if (!/^0x[a-fA-F0-9]{64}$/.test(key ?? "")) return null;
  return chainDependencies(key, process.env.MONAD_TESTNET_RPC || undefined);
}

export default createHandler(productionDependencies);
