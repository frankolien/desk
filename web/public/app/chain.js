// Monad, from the browser, with the desk's own wallet key: reading balances and allowances,
// and the three transactions that open a desk (approve, create the account, allow order
// forwarding) plus deposits. Gas follows DeskChain's policy: Monad charges the limit, not
// the gas used, so the estimate is padded 7.5%, never doubled; the fee cap is generous
// because a cap costs nothing.
import { createPublicClient, decodeFunctionResult, encodeFunctionData, http, parseAbi } from "./vendor/desk-crypto.js";

export const CHAIN_ID = 143;
const RPC = "https://rpc.monad.xyz";
const ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function createAccount(uint256 amount)",
  "function depositCollateral(uint256 amount)",
  "function withdrawCollateral(uint256 amount)",
  "function allowOrderForwarding(bool allow)",
  "function getAccountByAddr(address owner) view returns (uint256)",
]);
const PRIORITY_FEE = 2_000_000_000n;
const MINIMUM_FEE = 100_000_000_000n;
const MARGIN_BPS = 10_750n;

let client = null;
const rpc = () => (client ??= createPublicClient({ chain: { id: CHAIN_ID, name: "Monad", nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } }, transport: http(RPC, { timeout: 12_000 }) }));

export const call = (functionName, args) => encodeFunctionData({ abi: ABI, functionName, args });

export async function readUint(to, functionName, args) {
  const data = await rpc().call({ to, data: call(functionName, args) });
  return decodeFunctionResult({ abi: ABI, functionName, data: data.data });
}

export const ausdBalance = (token, owner) => readUint(token, "balanceOf", [owner]);
export const allowance = (token, owner, spender) => readUint(token, "allowance", [owner, spender]);

/// getAccountByAddr reverts when there is no account, so a revert is the answer, not an error.
export async function hasAccount(exchange, owner) {
  try { const id = await readUint(exchange, "getAccountByAddr", [owner]); return id > 0n; }
  catch { return false; }
}

/// Signs and sends one call from the wallet, then waits for its receipt. A reverted estimate
/// is surfaced, never replaced with a large limit the sender would be billed for.
export async function sendCall({ account, to, data, onSent }) {
  const node = rpc();
  const estimate = await node.estimateGas({ account: account.address, to, data });
  const gas = (() => { const padded = (estimate * MARGIN_BPS + 9_999n) / 10_000n; return padded < 21_000n ? 21_000n : padded; })();
  const block = await node.getBlock({ blockTag: "latest" });
  const base = block.baseFeePerGas ?? MINIMUM_FEE;
  const maxFeePerGas = (() => { const cap = base * 2n + PRIORITY_FEE; const floor = MINIMUM_FEE * 2n; return cap > floor ? cap : floor; })();
  const nonce = await node.getTransactionCount({ address: account.address, blockTag: "pending" });
  const signed = await account.signTransaction({ chainId: CHAIN_ID, type: "eip1559", to, data, gas, maxFeePerGas, maxPriorityFeePerGas: PRIORITY_FEE, nonce, value: 0n });
  const hash = await node.sendRawTransaction({ serializedTransaction: signed });
  onSent?.(hash);
  const receipt = await node.waitForTransactionReceipt({ hash, timeout: 60_000 });
  if (receipt.status !== "success") throw new Error(`The transaction reverted (${hash}).`);
  return hash;
}

/// Opens a desk: approve what the exchange will pull, create the account with that deposit,
/// then allow order forwarding so the trading key may act. Each step is checked before it
/// runs, and `report(step, state, hash?)` hears about every one.
export async function openDesk({ account, exchange, token, depositRaw, report = () => {} }) {
  const owner = account.address;
  if (await hasAccount(exchange, owner)) {
    report("approve", "done"); report("create", "done");
  } else {
    const held = await ausdBalance(token, owner);
    if (held < depositRaw) throw new Error("Your wallet does not hold that much AUSD.");
    if ((await allowance(token, owner, exchange)) >= depositRaw) report("approve", "done");
    else {
      report("approve", "sending");
      await sendCall({ account, to: token, data: call("approve", [exchange, depositRaw]), onSent: (hash) => report("approve", "sent", hash) });
      report("approve", "done");
    }
    report("create", "sending");
    await sendCall({ account, to: exchange, data: call("createAccount", [depositRaw]), onSent: (hash) => report("create", "sent", hash) });
    report("create", "done");
  }
  report("forwarding", "sending");
  await sendCall({ account, to: exchange, data: call("allowOrderForwarding", [true]), onSent: (hash) => report("forwarding", "sent", hash) });
  report("forwarding", "done");
}

/// Adds collateral to an open desk: approve if the allowance is short, then deposit.
export async function deposit({ account, exchange, token, amountRaw, report = () => {} }) {
  const owner = account.address;
  if ((await allowance(token, owner, exchange)) < amountRaw) {
    report("approve", "sending");
    await sendCall({ account, to: token, data: call("approve", [exchange, amountRaw]), onSent: (hash) => report("approve", "sent", hash) });
  }
  report("approve", "done");
  report("deposit", "sending");
  const hash = await sendCall({ account, to: exchange, data: call("depositCollateral", [amountRaw]), onSent: (h) => report("deposit", "sent", h) });
  report("deposit", "done", hash);
  return hash;
}

export async function withdraw({ account, exchange, amountRaw, report = () => {} }) {
  report("withdraw", "sending");
  const hash = await sendCall({ account, to: exchange, data: call("withdrawCollateral", [amountRaw]), onSent: (h) => report("withdraw", "sent", h) });
  report("withdraw", "done", hash);
  return hash;
}

export const explorerTx = (hash) => `https://monadvision.com/tx/${hash}`;
