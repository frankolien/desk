// Cross-check vectors for DeskChain's EIP-1559 transaction encoding, from viem.
//
// RLP has two rules that break a signature silently rather than loudly: a quantity is
// minimal big-endian so zero is the empty string and never 0x00, and a single byte below
// 0x80 encodes as itself. Both are exercised here on purpose.
//
//   node reference/perpl/tx-vectors.mjs > Tests/DeskChainTests/TransactionVectors.json
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { keccak256 } = require("/Users/hi/hackatons/recourse/web/node_modules/viem");
const { privateKeyToAccount } = require("/Users/hi/hackatons/recourse/web/node_modules/viem/accounts");

// The canonical Ethereum test key, never funded anywhere.
const PRIVATE_KEY = "0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318";
const account = privateKeyToAccount(PRIVATE_KEY);

const AUSD = "0xa9012a055bd4e0edff8ce09f960291c09d5322dc";
const EXCHANGE = "0x1964c32f0be608e7d29302aff5e61268e72080cc";
const approve = "0x095ea7b3" + EXCHANGE.slice(2).padStart(64, "0") + "f".repeat(64);

const cases = [
  ["every quantity zero", { nonce: 0, gas: 21000n, maxFeePerGas: 0n, maxPriorityFeePerGas: 0n, to: AUSD, value: 0n, data: "0x" }],
  ["a plain transfer", { nonce: 7, gas: 21000n, maxFeePerGas: 202000000000n, maxPriorityFeePerGas: 2000000000n, to: AUSD, value: 1000000000000000000n, data: "0x" }],
  ["single byte under 0x80", { nonce: 127, gas: 21000n, maxFeePerGas: 100000000000n, maxPriorityFeePerGas: 127n, to: AUSD, value: 127n, data: "0x" }],
  ["single byte at 0x80", { nonce: 128, gas: 21000n, maxFeePerGas: 100000000000n, maxPriorityFeePerGas: 128n, to: AUSD, value: 128n, data: "0x" }],
  ["an approve call", { nonce: 0, gas: 76432n, maxFeePerGas: 202000000000n, maxPriorityFeePerGas: 2000000000n, to: AUSD, value: 0n, data: approve }],
  ["a contract creation", { nonce: 3, gas: 150000n, maxFeePerGas: 202000000000n, maxPriorityFeePerGas: 2000000000n, to: null, value: 0n, data: "0x6080604052" }],
  ["a value past UInt64", { nonce: 1, gas: 21000n, maxFeePerGas: 202000000000n, maxPriorityFeePerGas: 2000000000n, to: AUSD, value: 123456789012345678901234567890n, data: "0x" }],
];

const out = [];
for (const [label, fields] of cases) {
  const transaction = { ...fields, chainId: 10143, type: "eip1559" };
  const raw = await account.signTransaction(transaction);
  out.push({
    label,
    chainId: 10143,
    nonce: fields.nonce,
    maxPriorityFeePerGas: fields.maxPriorityFeePerGas.toString(),
    maxFeePerGas: fields.maxFeePerGas.toString(),
    gasLimit: fields.gas.toString(),
    to: fields.to,
    value: fields.value.toString(),
    data: fields.data,
    raw,
    hash: keccak256(raw),
    from: account.address,
  });
}
console.log(JSON.stringify(out, null, 1));
