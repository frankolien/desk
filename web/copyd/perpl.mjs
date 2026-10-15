/// Perpl's trading API as the server speaks it: canonical request signing behind a pluggable
/// signer (a local Ed25519 seed in tests, AWS KMS in production, where the key never leaves the
/// HSM), the API-key enrolment checks and byte-exact splicing, and REST order specs built with
/// the same validation as DeskKit's OrderRequest. Pinned to DeskKit/Tests/DeskPerplTests/
/// CanonicalVectors.json and the EIP-712 enrolment fixture.
import { createHash, createPrivateKey, createPublicKey, randomBytes, sign as edSign, verify as edVerify } from "node:crypto";
import { hashTypedData, recoverAddress, getAddress } from "viem";

export const NETWORKS = {
  mainnet: { chainId: 143, base: "https://app.perpl.xyz/api", socket: "wss://app.perpl.xyz/ws/v1/trading" },
  testnet: { chainId: 10143, base: "https://testnet.perpl.xyz/api", socket: "wss://testnet.perpl.xyz/ws/v1/trading" },
};

const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
const sha256Hex = (text) => createHash("sha256").update(text).digest("hex");

// ---------- signers ----------

const PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

/// An Ed25519 key held in this process. For tests and local development only: production keys
/// live in KMS (`kms.mjs`) and expose the same shape.
export function localSigner(seedHex) {
  const key = createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, Buffer.from(seedHex, "hex")]), format: "der", type: "pkcs8" });
  const publicKey = createPublicKey(key).export({ format: "der", type: "spki" }).subarray(SPKI_PREFIX.length);
  return {
    kind: "local",
    publicKey: Buffer.from(publicKey),
    async sign(message) { return edSign(null, Buffer.from(message), key); },
  };
}

/// Every signature is checked before it leaves the process: a KMS key swapped under an alias,
/// or a bug in DER handling, fails here rather than at the venue.
export function verifyEd25519(publicKey, message, signature) {
  const key = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, Buffer.from(publicKey)]), format: "der", type: "spki" });
  return edVerify(null, Buffer.from(message), key, Buffer.from(signature));
}

async function signChecked(signer, message) {
  const signature = await signer.sign(message);
  if (signature.length !== 64 || !verifyEd25519(signer.publicKey, message, signature)) {
    throw new Error("the signer returned a signature its own public key does not verify");
  }
  return signature;
}

// ---------- canonical strings ----------

/// `{chainId}\n{METHOD}\n{target}\n{tsMillis}\n{nonce}\n{sha256hex(body)}`, no trailing newline.
/// `target` excludes `/api`, and is path plus query exactly as sent.
export function canonical(chainId, method, target, timestamp, nonce, body = "") {
  return [chainId, method, target, timestamp, nonce, sha256Hex(body)].join("\n");
}

export const signinCanonical = (chainId, timestamp, nonce) => [chainId, "trading-ws-signin", timestamp, nonce].join("\n");

export const freshNonce = () => b64url(randomBytes(16));

/// The four headers, signed over the same timestamp and nonce they carry: the gateway rebuilds
/// the string from them. A nonce is single-use, so a retry is a new stamp.
export async function stamp({ signer, apiKey, chainId, method, target, body = "", timestamp = String(Date.now()), nonce = freshNonce() }) {
  const signature = await signChecked(signer, canonical(chainId, method, target, timestamp, nonce, body));
  return {
    "X-API-Key": apiKey, "X-API-Timestamp": timestamp, "X-API-Nonce": nonce, "X-API-Signature": b64url(signature),
  };
}

export async function signinFrame({ signer, apiKey, chainId, timestamp = String(Date.now()), nonce = freshNonce() }) {
  const signature = await signChecked(signer, signinCanonical(chainId, timestamp, nonce));
  return JSON.stringify({ mt: 29, chain_id: chainId, api_key: apiKey, timestamp, nonce, signature: b64url(signature) });
}

export class PerplError extends Error {
  constructor(message, { status, body } = {}) { super(message); this.status = status; this.body = body; }
}

/// A signed REST client. Writes are never retried (a retried order is a second order); reads
/// are retried on 5xx, re-stamped each time.
export function restClient({ network, signer, apiKey, fetchImpl = fetch }) {
  const { chainId, base } = NETWORKS[network];
  async function request(method, target, { body = "", signed = true } = {}) {
    const attempts = method === "GET" ? 3 : 1;
    let last;
    for (let i = 0; i < attempts; i++) {
      const headers = { Accept: "application/json" };
      if (body) headers["Content-Type"] = "application/json";
      if (signed) Object.assign(headers, await stamp({ signer, apiKey, chainId, method, target, body }));
      const response = await fetchImpl(`${base}${target}`, { method, headers, body: body || undefined, redirect: "error" });
      const text = await response.text();
      if (response.ok) return { status: response.status, text, json: text ? JSON.parse(text) : null };
      last = new PerplError(`Perpl answered ${response.status} to ${method} ${target}`, { status: response.status, body: text });
      if (response.status < 500) break;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    throw last;
  }
  return {
    request,
    wallet: () => request("GET", "/v1/trading/wallet"),
    positions: () => request("GET", "/v1/trading/positions"),
    orders: () => request("GET", "/v1/trading/orders"),
    /// `specs` from the builders below; the answer's per-order code 0 means accepted for
    /// forwarding, not filled. Fills arrive on the trading socket.
    place: (specs) => request("POST", "/v1/trading/orders", { body: JSON.stringify({ mt: 30, d: specs }) }),
  };
}

// ---------- enrolment ----------

export const ENROL_STATEMENT = "I authorize the creation of Perpl API key with the specified scope and parameters";
const ENROL_FIELDS = ["signer", "statement", "publicKey", "scope", "label", "expiresAt", "ipCidrs", "origin", "builderId", "maxBuilderFeePer100K", "time"];

/// The raw bytes of one top-level member, so what Perpl signed its mac over goes back untouched.
export function jsonSpan(text, key) {
  const marker = `"${key}"`;
  let i = text.indexOf(marker);
  while (i !== -1) {
    let j = i + marker.length;
    while (/\s/.test(text[j])) j++;
    if (text[j] === ":") {
      j++;
      while (/\s/.test(text[j])) j++;
      const start = j;
      if (text[j] === '"') {
        j++;
        while (j < text.length) { if (text[j] === "\\") j += 2; else if (text[j] === '"') { j++; break; } else j++; }
        return text.slice(start, j);
      }
      if (text[j] === "{" || text[j] === "[") {
        let depth = 0, inString = false;
        for (; j < text.length; j++) {
          const ch = text[j];
          if (inString) { if (ch === "\\") j++; else if (ch === '"') inString = false; continue; }
          if (ch === '"') inString = true;
          else if (ch === "{" || ch === "[") depth++;
          else if (ch === "}" || ch === "]") { depth--; if (depth === 0) return text.slice(start, j + 1); }
        }
      }
      const end = text.slice(j).search(/[,}\]]/);
      return text.slice(start, end === -1 ? undefined : j + end).trim();
    }
    i = text.indexOf(marker, i + 1);
  }
  throw new PerplError(`Perpl's answer has no ${key}.`);
}

function integersAsBigInt(types, primaryType, message) {
  const out = { ...message };
  for (const { name, type } of types[primaryType] ?? []) {
    if (out[name] == null) continue;
    if (/^u?int\d*$/.test(type)) out[name] = BigInt(out[name]);
    else if (types[type] && typeof out[name] === "object") out[name] = integersAsBigInt(types, type, out[name]);
  }
  return out;
}

/// Perpl writes chainId and time as hex strings; hashed as text the gateway answers 400.
export function enrolmentDigest(typedData) {
  const { domain, types, primaryType, message } = typedData;
  const clean = Object.fromEntries(Object.entries(types).filter(([name]) => name !== "EIP712Domain"));
  return hashTypedData({
    domain: { ...domain, ...(domain.chainId != null ? { chainId: BigInt(domain.chainId) } : {}) },
    types: clean, primaryType, message: integersAsBigInt(clean, primaryType, message),
  });
}

/// The server signs a proof of possession with a key whose public half it chose, so it checks
/// that Perpl's payload is for exactly that key, this wallet, this chain, trade scope and nothing
/// it did not declare, before anything is signed.
export function checkEnrolmentPayload(typedData, { address, publicKey, chainId }) {
  const { domain, types, primaryType, message } = typedData ?? {};
  const fail = (why) => { throw new PerplError(`Perpl's enrolment payload ${why}`); };
  if (primaryType !== "PerplRegisterApiKey") fail("has another primary type");
  if (domain?.name !== "perpl.xyz" || String(domain?.version) !== "1") fail("is for another domain");
  if (Number(BigInt(domain?.chainId ?? -1)) !== chainId) fail("names another chain");
  const declared = (types?.PerplRegisterApiKey ?? []).map((f) => f.name);
  if (declared.join() !== ENROL_FIELDS.join()) fail("declares unexpected fields");
  const extra = Object.keys(message ?? {}).filter((k) => !ENROL_FIELDS.includes(k));
  if (extra.length) fail(`carries undeclared fields: ${extra.join(", ")}`);
  if (getAddress(message.signer) !== getAddress(address)) fail("names another wallet");
  if (message.statement !== ENROL_STATEMENT) fail("has another statement");
  if (message.publicKey !== b64url(publicKey)) fail("names another key");
  if (String(message.scope) !== "3") fail("asks for another scope");
  return true;
}

export const payloadBody = ({ chainId, address, publicKey, label }) =>
  JSON.stringify({ chain_id: chainId, address: getAddress(address), public_key: `0x${Buffer.from(publicKey).toString("hex")}`, scope_mask: 3, label });

/// The wallet's signature (made on the phone) must recover this account over the digest the
/// server computed itself; then the server key proves possession over the same raw digest.
export async function enrolBody({ payloadText, chainId, address, walletSignature, signer }) {
  const typedRaw = jsonSpan(payloadText, "typed_data");
  const macRaw = jsonSpan(payloadText, "mac");
  const typedData = JSON.parse(typedRaw);
  checkEnrolmentPayload(typedData, { address, publicKey: signer.publicKey, chainId });
  const digest = enrolmentDigest(typedData);
  const recovered = await recoverAddress({ hash: digest, signature: walletSignature });
  if (getAddress(recovered) !== getAddress(address)) throw new PerplError("the wallet signature is not this account's");
  const pop = await signChecked(signer, Buffer.from(digest.slice(2), "hex"));
  const body = `{"chain_id":${chainId},"address":"${getAddress(address)}","typed_data":${typedRaw},"mac":${macRaw},"signature":"${walletSignature}","pop_signature":"0x${Buffer.from(pop).toString("hex")}"}`;
  return { body, digest };
}

export function tokenFrom(answer) {
  const token = typeof answer?.api_key === "string" ? answer.api_key : answer?.api_key?.api_key;
  if (!token) throw new PerplError("Perpl returned an enrolment without a key.");
  return token;
}

// ---------- orders ----------

export const ORDER_TYPE = { openLong: 1, openShort: 2, closeLong: 3, closeShort: 4, cancel: 5 };
export const FLAGS = { goodTillCancelled: 0, postOnly: 1, fillOrKill: 2, immediateOrCancel: 4 };
export const TRIGGER = { lastAtOrAbove: 1, lastAtOrBelow: 2, markAtOrAbove: 3, markAtOrBelow: 4 };

/// Strictly increasing per account, and the account is shared with the phone and the browser:
/// past what Perpl last forwarded, past anything this process handed out, and at least now.
export function requestCounter(now = () => BigInt(Date.now())) {
  let last = 0n;
  return (lastForwarded) => {
    const floor = (lastForwarded ?? 0n) + 1n;
    let next = floor > last + 1n ? floor : last + 1n;
    const clock = now();
    if (clock > next) next = clock;
    last = next;
    return next;
  };
}

function check(condition, why) { if (!condition) throw new PerplError(why); }

const sizeChecks = (market, size) => {
  check(size.raw > 0n, "size must be positive");
  check(size.decimals === market.config.sizeDecimals, "size scale does not match the market");
};
const slippageChecks = (market, bps) => check(bps > 0 && bps <= market.maxMarketSlippageBps, `slippage ${bps} outside 1..${market.maxMarketSlippageBps}`);

/// A marketable open: price 0 with immediate-or-cancel, bounded by `slippageBps`. `lb` is 0 on
/// protocol v235.
export function marketOpen({ market, account, side, size, leverageHundredths, slippageBps, rq }) {
  sizeChecks(market, size);
  check(leverageHundredths >= 100 && leverageHundredths <= market.config.initialMarginFraction, "leverage outside the market's range");
  slippageChecks(market, slippageBps);
  return { rq: Number(rq), mkt: market.id, acc: account, t: side === "long" ? ORDER_TYPE.openLong : ORDER_TYPE.openShort, p: 0, s: Number(size.raw), fl: FLAGS.immediateOrCancel, lv: leverageHundredths, lb: 0, ms: slippageBps };
}

/// Closing uses its own types, never an opposing open: exempt from the initial-margin check, so
/// an underwater position can always be closed, and unable to open the other side.
export function marketClose({ market, account, side, size, slippageBps, rq }) {
  sizeChecks(market, size);
  slippageChecks(market, slippageBps);
  return { rq: Number(rq), mkt: market.id, acc: account, t: side === "long" ? ORDER_TYPE.closeLong : ORDER_TYPE.closeShort, p: 0, s: Number(size.raw), fl: FLAGS.immediateOrCancel, lv: 100, lb: 0, ms: slippageBps };
}

/// A stop or take on the venue, linked to the opening request (`tr`) or a position (`lp`), so
/// Perpl ends it with the position.
export function protectiveClose({ market, account, side, size, trigger, condition, linkedRequest = null, linkedPosition = null, slippageBps, rq }) {
  sizeChecks(market, size);
  check(trigger.decimals === market.config.priceDecimals, "trigger scale does not match the market");
  check(trigger.raw > 0n, "trigger must be positive");
  check(linkedRequest != null || linkedPosition != null, "a trigger needs a linked request or position");
  slippageChecks(market, slippageBps);
  const spec = { rq: Number(rq), mkt: market.id, acc: account, t: side === "long" ? ORDER_TYPE.closeLong : ORDER_TYPE.closeShort, p: 0, s: Number(size.raw), fl: FLAGS.immediateOrCancel, lv: 100, lb: 0, ms: slippageBps, tp: Number(trigger.raw), tpc: condition };
  if (linkedRequest != null) spec.tr = Number(linkedRequest);
  if (linkedPosition != null) spec.lp = Number(linkedPosition);
  return spec;
}

/// Stop and take conditions by the copy's side: a long's stop fires at or below the mark.
export const stopCondition = (side) => (side === "long" ? TRIGGER.markAtOrBelow : TRIGGER.markAtOrAbove);
export const takeCondition = (side) => (side === "long" ? TRIGGER.markAtOrAbove : TRIGGER.markAtOrBelow);
