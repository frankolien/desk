// One passkey, the same keys as the phone. Mera's derivation rule, followed byte for byte:
// the PRF output is BIP-39 entropy; the wallet is secp256k1 at m/44'/60'/0'/0/0; the key that
// trades on Perpl is Ed25519 at m/44'/501'/{index}'/0' by SLIP-10. Any change here moves every
// address Desk has ever shown, so it is pinned to the same vectors as DeskAuth.
import {
  HDKey, base64urlnopad, ed25519, entropyToMnemonic, hashTypedData, hex, hmac, keccak_256,
  mnemonicToSeedSync, privateKeyToAccount, sha256, sha512, wordlist,
} from "./vendor/desk-crypto.js";

const utf8 = (text) => new TextEncoder().encode(text);
const HARDENED = 0x80000000;

/// sha256("mera.prf.salt.v1"): what the passkey's PRF is evaluated over.
export const PRF_SALT = sha256(utf8("mera.prf.salt.v1"));

export const toHex = (bytes) => `0x${hex.encode(bytes)}`;
export const fromHex = (text) => hex.decode(String(text).replace(/^0x/, ""));

function bip39Seed(prf) {
  if (!(prf instanceof Uint8Array) || prf.length !== 32) throw new Error("PRF output must be 32 bytes");
  return mnemonicToSeedSync(entropyToMnemonic(prf, wordlist));
}

/// SLIP-10 for Ed25519: every step hardened, as Mera does for its Solana-path account.
function slip10Ed25519(seed, path) {
  let digest = hmac(sha512, utf8("ed25519 seed"), seed);
  let key = digest.slice(0, 32);
  let chain = digest.slice(32);
  for (const step of path) {
    if (step >= HARDENED) throw new Error("path step is already hardened");
    const index = (step | HARDENED) >>> 0;
    const message = new Uint8Array(37);
    message.set(key, 1);
    message[33] = index >>> 24; message[34] = (index >>> 16) & 0xff; message[35] = (index >>> 8) & 0xff; message[36] = index & 0xff;
    digest = hmac(sha512, chain, message);
    key = digest.slice(0, 32);
    chain = digest.slice(32);
  }
  return key;
}

/// The wallet that holds the collateral: private key, address and a viem account that signs.
export function deriveWallet(prf) {
  const node = HDKey.fromMasterSeed(bip39Seed(prf)).derive("m/44'/60'/0'/0/0");
  const privateKey = node.privateKey;
  const account = privateKeyToAccount(toHex(privateKey));
  return { privateKey, address: account.address, account };
}

/// The Ed25519 key Perpl trades with. It can place and close orders and cannot withdraw.
export function deriveTradingKey(prf, index = 0) {
  if (!Number.isInteger(index) || index < 0 || index >= HARDENED) throw new Error("index out of range");
  const seed = slip10Ed25519(bip39Seed(prf), [44, 501, index, 0]);
  return { seed, publicKey: ed25519.getPublicKey(seed), index };
}

export const sha256Hex = (bytes) => hex.encode(sha256(bytes));

/// One timestamp and nonce for both the canonical string and the headers.
export function requestStamp(now = Date.now()) {
  const nonce = crypto.getRandomValues(new Uint8Array(16));
  return { timestamp: String(now), nonce: base64urlnopad.encode(nonce) };
}

/// chain_id, METHOD, target, timestamp, nonce, sha256(body) hex. `target` is the path and
/// query exactly as sent.
export function canonicalRest(chainId, method, target, body, stamp) {
  const bytes = body instanceof Uint8Array ? body : utf8(body ?? "");
  return [String(chainId), method, target, stamp.timestamp, stamp.nonce, sha256Hex(bytes)].join("\n");
}

export function canonicalSignIn(chainId, stamp) {
  return [String(chainId), "trading-ws-signin", stamp.timestamp, stamp.nonce].join("\n");
}

/// Base64url without padding, as Perpl's gateway expects.
export function signCanonical(tradingSeed, canonical) {
  return base64urlnopad.encode(ed25519.sign(utf8(canonical), tradingSeed));
}

/// The four headers a signed Perpl request carries.
export function signedHeaders({ apiKey, tradingSeed, chainId, method, target, body = "" }) {
  const stamp = requestStamp();
  return {
    "X-API-Key": apiKey,
    "X-API-Timestamp": stamp.timestamp,
    "X-API-Nonce": stamp.nonce,
    "X-API-Signature": signCanonical(tradingSeed, canonicalRest(chainId, method, target, body, stamp)),
  };
}

/// The two signatures an API key enrolment needs over Perpl's EIP-712 payload: the wallet's,
/// proving the account, and the Ed25519 key's, proving it is the key being enrolled. The
/// payload is checked before anything signs it: it must name this chain, this wallet and this
/// public key.
export async function enrolmentSignatures(typedData, { wallet, trading, chainId }) {
  const { domain, types, primaryType, message } = typedData;
  if (Number(domain?.chainId) !== Number(chainId)) throw new Error("Perpl's payload names another chain");
  const text = JSON.stringify(message);
  if (!text.toLowerCase().includes(wallet.address.toLowerCase())) throw new Error("Perpl's payload names another wallet");
  // Perpl writes the key into the message as unpadded base64url; a hex spelling is accepted too.
  const keyForms = [base64urlnopad.encode(trading.publicKey), hex.encode(trading.publicKey), `0x${hex.encode(trading.publicKey)}`];
  if (!keyForms.some((form) => text.includes(form))) throw new Error("Perpl's payload names another key");
  const cleanTypes = Object.fromEntries(Object.entries(types).filter(([name]) => name !== "EIP712Domain"));
  // Perpl writes integers as hex strings ("0x8f", "0x1a115347e6a"); the hash takes bigints.
  const digest = hashTypedData({
    domain: { ...domain, ...(domain.chainId != null ? { chainId: toBigInt(domain.chainId) } : {}) },
    types: cleanTypes, primaryType, message: integersAsBigInt(cleanTypes, primaryType, message),
  });
  const signature = await wallet.account.sign({ hash: digest });
  const pop = toHex(ed25519.sign(fromHex(digest), trading.seed));
  return { signature, pop, digest };
}

function toBigInt(value) { return typeof value === "bigint" ? value : BigInt(value); }

/// Every int/uint field of `primaryType` (and of the structs it nests) as a bigint.
function integersAsBigInt(types, primaryType, message) {
  const fields = types[primaryType] ?? [];
  const out = { ...message };
  for (const { name, type } of fields) {
    if (!(name in out) || out[name] == null) continue;
    if (/^u?int\d*$/.test(type)) out[name] = toBigInt(out[name]);
    else if (types[type] && typeof out[name] === "object") out[name] = integersAsBigInt(types, type, out[name]);
  }
  return out;
}

export const keccak = keccak_256;
