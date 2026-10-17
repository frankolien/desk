/// Spot copy on Monad, the chain half (docs/spot-copy.md): what Desk's copy key sends, what the
/// wallet signs to let it, and the KMS signer behind it. The API checks the wallet's signatures
/// with these same builders, so what the phone signed and what copyd sends can't drift apart.
import {
  decodeEventLog, encodeAbiParameters, encodeFunctionData, getAddress, keccak256, parseAbi,
  recoverTypedDataAddress, serializeTransaction, toHex, recoverAddress,
} from "viem";
import { toAccount } from "viem/accounts";
import { recoverAuthorizationAddress } from "viem/utils";

export const SPOT = Object.freeze({
  chainId: 143,
  calibur: "0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00",
  holder: "0x0000000000001fF3684f28c67538d4D072C22734",
  ausd: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a",
  ausdDecimals: 6,
});

/// The deployed DeskCopyHook. Calibur reads its callbacks from the address's low bits.
export function hookAddress(env = process.env) {
  const value = env.SPOT_HOOK;
  if (!value || !/^0x[0-9a-fA-F]{40}$/.test(value)) return null;
  return (BigInt(value) & 0x1fn) === 0x1en ? getAddress(value) : null;
}

const CALIBUR = parseAbi([
  "struct Call { address to; uint256 value; bytes data; }",
  "struct BatchedCall { Call[] calls; bool revertOnFailure; }",
  "struct SignedBatchedCall { BatchedCall batchedCall; uint256 nonce; bytes32 keyHash; address executor; uint256 deadline; }",
  "struct Key { uint8 keyType; bytes publicKey; }",
  "function execute(BatchedCall batchedCall)",
  "function execute(SignedBatchedCall signedBatchedCall, bytes wrappedSignature)",
  "function register(Key key)",
  "function update(bytes32 keyHash, uint256 settings)",
  "function revoke(bytes32 keyHash)",
  "function getSeq(uint256 key) view returns (uint256)",
  "function isRegistered(bytes32 keyHash) view returns (bool)",
  "function getKeySettings(bytes32 keyHash) view returns (uint256)",
]);
export const HOOK = parseAbi([
  "function configure(bytes32 keyHash, uint128 perTrade, uint128 perDay)",
  "function copied(address wallet, bytes32 keyHash, address token) view returns (uint256)",
  "function remainingToday(address wallet, bytes32 keyHash) view returns (uint256)",
  "function limits(address wallet, bytes32 keyHash) view returns (uint128 perTrade, uint128 perDay)",
  "event Bought(address indexed wallet, bytes32 indexed keyHash, address indexed token, uint256 spent, uint256 received)",
  "event Sold(address indexed wallet, bytes32 indexed keyHash, address indexed token, uint256 amount)",
]);
const ERC20 = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address owner) view returns (uint256)",
]);

const SECP256K1 = 2;
/// Calibur's key hash for a secp256k1 key: the hash of its type and its address, abi-encoded.
export const keyHashOf = (address) => keccak256(encodeAbiParameters(
  [{ type: "uint8" }, { type: "bytes32" }],
  [SECP256K1, keccak256(encodeAbiParameters([{ type: "address" }], [getAddress(address)]))],
));

/// Calibur key settings: hook in the low 20 bytes, expiry in the next 5, not an admin.
export const settingsOf = ({ hook, expiry }) => (BigInt(expiry) << 160n) | BigInt(hook);

const self = "0x0000000000000000000000000000000000000000"; // ERC-7821: address(0) is the wallet itself

/// The three calls that let Desk's key copy: register it, fence it with the hook until the
/// expiry, and set the AUSD limits. Amounts are AUSD base units (6 decimals).
export function setupCalls({ desk, hook, expiry, perTrade, perDay }) {
  const keyHash = keyHashOf(desk);
  return [
    { to: self, value: 0n, data: encodeFunctionData({ abi: CALIBUR, functionName: "register", args: [{ keyType: SECP256K1, publicKey: encodeAbiParameters([{ type: "address" }], [getAddress(desk)]) }] }) },
    { to: self, value: 0n, data: encodeFunctionData({ abi: CALIBUR, functionName: "update", args: [keyHash, settingsOf({ hook, expiry })] }) },
    { to: getAddress(hook), value: 0n, data: encodeFunctionData({ abi: HOOK, functionName: "configure", args: [keyHash, BigInt(perTrade), BigInt(perDay)] }) },
  ];
}

export const limitCalls = ({ desk, hook, perTrade, perDay }) => [
  { to: getAddress(hook), value: 0n, data: encodeFunctionData({ abi: HOOK, functionName: "configure", args: [keyHashOf(desk), BigInt(perTrade), BigInt(perDay)] }) },
];

const AUSD_UNIT = 10 ** SPOT.ausdDecimals;
export const ausdRaw = (ausd) => BigInt(Math.round(ausd * AUSD_UNIT));
export const ausdOf = (raw) => Number(raw) / AUSD_UNIT;

export const revokeCalls = ({ desk }) => [
  { to: self, value: 0n, data: encodeFunctionData({ abi: CALIBUR, functionName: "revoke", args: [keyHashOf(desk)] }) },
];

/// The EIP-712 the wallet's own key signs for a batch (Calibur's `SignedBatchedCall`, root key).
export function batchTypedData({ wallet, calls, nonce, deadline, executor }) {
  return {
    domain: {
      name: "Calibur", version: "1.0.0", chainId: SPOT.chainId, verifyingContract: getAddress(wallet),
      salt: toHex(BigInt(SPOT.calibur), { size: 32 }),
    },
    types: {
      SignedBatchedCall: [
        { name: "batchedCall", type: "BatchedCall" }, { name: "nonce", type: "uint256" },
        { name: "keyHash", type: "bytes32" }, { name: "executor", type: "address" }, { name: "deadline", type: "uint256" },
      ],
      BatchedCall: [{ name: "calls", type: "Call[]" }, { name: "revertOnFailure", type: "bool" }],
      Call: [{ name: "to", type: "address" }, { name: "value", type: "uint256" }, { name: "data", type: "bytes" }],
    },
    primaryType: "SignedBatchedCall",
    message: {
      batchedCall: { calls, revertOnFailure: true },
      nonce: BigInt(nonce), keyHash: `0x${"0".repeat(64)}`, executor: getAddress(executor), deadline: BigInt(deadline),
    },
  };
}

/// The batch for a job, rebuilt from its plain fields: what the wallet signed is what copyd
/// sends. `enable` registers and fences the key; `limits` moves the end date and the limits;
/// `disable` revokes the key.
export function batchFor({ kind, wallet, desk, hook, nonce, deadline, perTrade, perDay, expiry }) {
  let calls;
  if (kind === "enable") calls = setupCalls({ desk, hook, expiry, perTrade: ausdRaw(perTrade), perDay: ausdRaw(perDay) });
  else if (kind === "limits") {
    calls = [
      { to: self, value: 0n, data: encodeFunctionData({ abi: CALIBUR, functionName: "update", args: [keyHashOf(desk), settingsOf({ hook, expiry })] }) },
      ...limitCalls({ desk, hook, perTrade: ausdRaw(perTrade), perDay: ausdRaw(perDay) }),
    ];
  } else if (kind === "disable") calls = revokeCalls({ desk });
  else throw new Error(`no batch for ${kind}`);
  return batchTypedData({ wallet, calls, nonce, deadline, executor: desk });
}

/// True when the wallet itself (its root key) signed this batch.
export async function signedByWallet({ wallet, typed, signature }) {
  try {
    return (await recoverTypedDataAddress({ ...typed, signature })).toLowerCase() === wallet.toLowerCase();
  } catch { return false; }
}

/// True when the wallet signed the EIP-7702 authorization to Calibur on Monad at this nonce.
export async function authorizedByWallet({ wallet, authorization }) {
  if (!authorization) return false;
  if (Number(authorization.chainId) !== SPOT.chainId) return false;
  if (getAddress(authorization.address) !== getAddress(SPOT.calibur)) return false;
  try {
    return (await recoverAuthorizationAddress({ authorization })).toLowerCase() === wallet.toLowerCase();
  } catch { return false; }
}

/// What the wallet's code is now: Calibur, nothing, or something Desk won't touch.
export function delegationOf(code) {
  if (!code || code === "0x") return "none";
  const text = code.toLowerCase();
  if (text === `0xef0100${SPOT.calibur.slice(2).toLowerCase()}`) return "calibur";
  return "other";
}

/// The setup or revoke batch, submitted by Desk's key with the wallet's signature.
export const executeSignedData = ({ typed, signature }) => encodeFunctionData({
  abi: CALIBUR, functionName: "execute",
  args: [{ ...typed.message, batchedCall: { calls: typed.message.batchedCall.calls, revertOnFailure: true } },
    encodeAbiParameters([{ type: "bytes" }, { type: "bytes" }], [signature, "0x"])],
});

/// A copy, run by Desk's key as the wallet's registered caller: Calibur runs the hook around
/// each call.
export const executeAsKeyData = (calls) => encodeFunctionData({
  abi: CALIBUR, functionName: "execute", args: [{ calls, revertOnFailure: true }],
});

export const approveCall = (token, amount) => ({
  to: getAddress(token), value: 0n, data: encodeFunctionData({ abi: ERC20, functionName: "approve", args: [SPOT.holder, BigInt(amount)] }),
});

export const balanceOfData = (owner) => encodeFunctionData({ abi: ERC20, functionName: "balanceOf", args: [getAddress(owner)] });

/// What the hook said happened, from a copy's receipt.
export function hookEvents(logs, hook) {
  const out = [];
  for (const log of logs ?? []) {
    if (!hook || log.address?.toLowerCase() !== hook.toLowerCase()) continue;
    try {
      const event = decodeEventLog({ abi: HOOK, data: log.data, topics: log.topics });
      out.push({ name: event.eventName, ...event.args });
    } catch { /* not the hook's */ }
  }
  return out;
}

export { CALIBUR as CALIBUR_ABI };

// ---------- Desk's copy key, in KMS ----------

export const SPOT_KEY_SPEC = "ECC_SECG_P256K1";
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

/// The uncompressed point out of KMS's DER SubjectPublicKeyInfo for a secp256k1 key.
export function secpPointFromSpki(der) {
  const bytes = Buffer.from(der);
  const point = bytes.subarray(bytes.length - 65);
  if (point[0] !== 0x04) throw new Error("KMS returned a public key that is not an uncompressed secp256k1 point");
  return point;
}

export const addressOfPoint = (point) => getAddress(`0x${keccak256(toHex(point.subarray(1))).slice(-40)}`);

/// r and s out of a DER ECDSA signature.
export function derToRS(der) {
  const bytes = Buffer.from(der);
  let offset = 2;
  if (bytes[0] !== 0x30) throw new Error("not a DER signature");
  if (bytes[1] & 0x80) offset += bytes[1] & 0x7f;
  const read = () => {
    if (bytes[offset] !== 0x02) throw new Error("not a DER integer");
    const length = bytes[offset + 1];
    const value = BigInt(`0x${bytes.subarray(offset + 2, offset + 2 + length).toString("hex") || "0"}`);
    offset += 2 + length;
    return value;
  };
  return { r: read(), s: read() };
}

/// An Ethereum signature over a digest, from KMS: low-s, and the recovery bit found by trying both.
export async function signDigestWith({ signDer, address, hash }) {
  let { r, s } = derToRS(await signDer(Buffer.from(hash.slice(2), "hex")));
  if (s > N / 2n) s = N - s;
  const rh = toHex(r, { size: 32 });
  const sh = toHex(s, { size: 32 });
  for (const yParity of [0, 1]) {
    const signature = { r: rh, s: sh, yParity };
    const recovered = await recoverAddress({ hash, signature });
    if (recovered.toLowerCase() === address.toLowerCase()) return signature;
  }
  throw new Error("KMS signature does not recover to the copy key");
}

/// A viem account whose private half is the KMS key: it signs transactions and nothing else.
export async function kmsAccount({ client, keyId, commands }) {
  const { GetPublicKeyCommand, SignCommand } = commands ?? await import("@aws-sdk/client-kms");
  const info = await client.send(new GetPublicKeyCommand({ KeyId: keyId }));
  if (info.KeySpec && info.KeySpec !== SPOT_KEY_SPEC) throw new Error(`KMS key is ${info.KeySpec}, not ${SPOT_KEY_SPEC}`);
  const address = addressOfPoint(secpPointFromSpki(info.PublicKey));
  const signDer = async (digest) => Buffer.from((await client.send(new SignCommand({
    KeyId: keyId, Message: digest, MessageType: "DIGEST", SigningAlgorithm: "ECDSA_SHA_256",
  }))).Signature);
  return accountFromSigner({ address, signDer });
}

export function accountFromSigner({ address, signDer }) {
  const sign = (hash) => signDigestWith({ signDer, address, hash });
  return toAccount({
    address,
    async signMessage() { throw new Error("Desk's copy key signs transactions only"); },
    async signTypedData() { throw new Error("Desk's copy key signs transactions only"); },
    async signTransaction(transaction, { serializer = serializeTransaction } = {}) {
      const signature = await sign(keccak256(serializer(transaction)));
      return serializer(transaction, signature);
    },
  });
}

