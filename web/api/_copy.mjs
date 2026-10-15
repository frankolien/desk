/// /api/copy: turning server copying on, steering it and turning it off (docs/server-copy.md).
/// Served by the alerts function (`?job=copy&action=…`), since the Hobby plan's function slots
/// are spoken for.
///
/// prepare  makes this enrolment's KMS key and asks Perpl for the registration to sign.
/// enroll   takes the one Face ID's two signatures: Perpl's EIP-712 registration and Desk's
///          grant (EIP-191), which names the server key, the phone's device key and the hard
///          caps. The server checks both, proves possession with KMS and registers the key.
/// Everything after is signed by the device key (P-256, Secure Enclave), not the wallet:
/// state, rules, pause, resume, close, disable.
import { createCipheriv, createDecipheriv, createHash, createPublicKey, randomBytes, verify as cryptoVerify } from "node:crypto";
import { getAddress, isAddress, recoverMessageAddress } from "viem";
import { NETWORKS, payloadBody, enrolBody, tokenFrom, jsonSpan, checkEnrolmentPayload, PerplError } from "../copyd/perpl.mjs";
import { createKey, kmsSigner, retireKey } from "../copyd/kms.mjs";
import { decodeRules, decodeGuards, DEFAULT_GUARDS } from "../copyd/planner.mjs";
import { K, copierId, LOG_LIMIT } from "../copyd/engine.mjs";
import { rateLimit, clientIp } from "./_ratelimit.mjs";

export const LABEL = "Desk Auto-Copy (server)";
const PENDING_FRESH_MS = 20 * 60_000; // a prepared key is offered again for this long
const PENDING_KEEP_S = 6 * 3600; // and remembered this long, so an abandoned one is retired
const GRANT_SKEW_MS = 10 * 60_000;
const REQUEST_WINDOW_MS = 60_000;
const NONCE_TTL_S = 120;
const PREPARES_PER_HOUR = 6;

const C = {
  pending: (id) => `copy:pending:${id}`,
  generation: (id) => `copy:generation:${id}`,
  prepares: (id, hour) => `copy:prepares:${id}:${hour}`,
  nonce: (id, nonce) => `copy:nonce:${id}:${nonce}`,
  heartbeat: "copy:heartbeat",
};

class Refusal extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const refuse = (status, message) => { throw new Refusal(status, message); };

const sha256Hex = (text) => createHash("sha256").update(text).digest("hex");

// ---------- the grant ----------

export const CAPS = [
  ["maxMarginPerTrade", "Max margin per trade", "AUSD"],
  ["maxLeverage", "Max leverage", "x"],
  ["maxOpenCopies", "Max open copies", ""],
  ["maxOpenNotional", "Max open notional", "AUSD"],
  ["maxDailyLoss", "Max daily loss", "AUSD"],
  ["maxOrdersPerHour", "Max orders per hour", ""],
];
const GRANT_HEAD = ["Desk Auto-Copy grant", "I let Desk's server copy trades for this account within these limits."];

/// The text the wallet signs (EIP-191). Line for line, so the server can read back exactly what
/// was signed, and a person reading it sees every limit.
export function grantText({ account, network, serverKey, deviceKey, caps, issuedAt }) {
  return [
    ...GRANT_HEAD,
    `Account: ${getAddress(account)}`,
    `Network: ${network}`,
    `Server key: ${serverKey}`,
    `Device key: ${deviceKey}`,
    ...CAPS.map(([key, label, unit]) => `${label}: ${caps[key]}${unit === "x" ? "x" : unit ? ` ${unit}` : ""}`),
    `Issued: ${new Date(issuedAt).toISOString()}`,
  ].join("\n");
}

export function parseGrant(text) {
  const lines = String(text ?? "").split("\n");
  const fail = () => refuse(400, "The grant isn't one Desk wrote.");
  if (lines.length !== GRANT_HEAD.length + 4 + CAPS.length + 1) fail();
  if (lines[0] !== GRANT_HEAD[0] || lines[1] !== GRANT_HEAD[1]) fail();
  const field = (line, label) => (line.startsWith(`${label}: `) ? line.slice(label.length + 2) : fail());
  const account = field(lines[2], "Account");
  const network = field(lines[3], "Network");
  const serverKey = field(lines[4], "Server key");
  const deviceKey = field(lines[5], "Device key");
  const caps = {};
  CAPS.forEach(([key, label, unit], i) => {
    const raw = field(lines[6 + i], label);
    const number = unit === "x" ? raw.replace(/x$/, "") : unit ? raw.replace(new RegExp(` ${unit}$`), "") : raw;
    const value = Number(number);
    if (!/^\d+(\.\d+)?$/.test(number) || !(value > 0)) fail();
    caps[key] = value;
  });
  const issuedAt = Date.parse(field(lines.at(-1), "Issued"));
  if (!isAddress(account) || !NETWORKS[network] || !/^0x[0-9a-f]{64}$/.test(serverKey) || !Number.isFinite(issuedAt)) fail();
  const parsed = { account: getAddress(account), network, serverKey, deviceKey, caps, issuedAt };
  if (grantText(parsed) !== text) fail();
  return parsed;
}

export async function verifyGrant({ text, signature, account }) {
  const grant = parseGrant(text);
  let signer;
  try { signer = await recoverMessageAddress({ message: text, signature }); } catch { refuse(400, "The grant's signature can't be read."); }
  if (getAddress(signer) !== getAddress(account) || grant.account !== getAddress(account)) refuse(403, "The grant wasn't signed by this account.");
  return grant;
}

// ---------- the device key ----------

const P256_SPKI = Buffer.from("3059301306072a8648ce3d020106082a8648ce3d030107034200", "hex");

/// The Secure Enclave key as iOS exports it: 65 bytes, 04‖X‖Y, base64url.
export function deviceKeyObject(deviceKey) {
  const raw = Buffer.from(String(deviceKey ?? ""), "base64url");
  if (raw.length !== 65 || raw[0] !== 0x04) refuse(400, "The device key isn't a P-256 public key.");
  try { return createPublicKey({ key: Buffer.concat([P256_SPKI, raw]), format: "der", type: "spki" }); }
  catch { return refuse(400, "The device key isn't a point on P-256."); }
}

/// Perpl's shape, with Desk's prefix: what the device key signs for every request.
export const deviceCanonical = ({ chainId, method, target, time, nonce, body = "" }) =>
  ["desk-copy", chainId, method, target, time, nonce, sha256Hex(body)].join("\n");

/// ECDSA over SHA-256, as SecKey (DER) or CryptoKit (raw r‖s) produces it.
export function verifyDevice(deviceKey, message, signatureB64) {
  const signature = Buffer.from(String(signatureB64 ?? ""), "base64url");
  const key = deviceKeyObject(deviceKey);
  try {
    return cryptoVerify("sha256", Buffer.from(message), { key, dsaEncoding: signature.length === 64 ? "ieee-p1363" : "der" }, signature);
  } catch { return false; }
}

// ---------- the Perpl token, at rest ----------

/// AES-256-GCM under COPY_TOKEN_KEY, which Vercel and copyd share. The token is Perpl's key id:
/// it signs nothing, but it isn't left readable either.
export function seal(text, keyB64) {
  const key = Buffer.from(String(keyB64 ?? ""), "base64");
  if (key.length !== 32) throw new Error("COPY_TOKEN_KEY must be 32 bytes, base64");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const body = Buffer.concat([cipher.update(text, "utf8"), cipher.final()]);
  return ["v1", iv, cipher.getAuthTag(), body].map((part) => (typeof part === "string" ? part : part.toString("base64url"))).join(".");
}

export function unseal(sealed, keyB64) {
  const [version, iv, tag, body] = String(sealed).split(".");
  if (version !== "v1") throw new Error("unknown token seal");
  const decipher = createDecipheriv("aes-256-gcm", Buffer.from(String(keyB64), "base64"), Buffer.from(iv, "base64url"));
  decipher.setAuthTag(Buffer.from(tag, "base64url"));
  return Buffer.concat([decipher.update(Buffer.from(body, "base64url")), decipher.final()]).toString("utf8");
}

// ---------- rules within the caps ----------

const positive = (value, what, { max = 1e9, integer = false } = {}) => {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0 || value > max || (integer && !Number.isInteger(value))) {
    refuse(400, `${what} must be a positive ${integer ? "whole " : ""}number.`);
  }
  return value;
};

/// Rules and guards as the planner reads them, refused where they reach past what the wallet
/// granted. Lowering a limit needs only the device key; raising one past the grant needs a new
/// grant, which needs Face ID.
export function checkedRules(json, caps) {
  let rules;
  try { rules = decodeRules(json); } catch { refuse(400, "The rules are incomplete."); }
  if (!["shadow", "live"].includes(rules.mode)) refuse(400, "Mode must be shadow or live.");
  if (!["follow", "fade"].includes(rules.direction)) refuse(400, "Direction must be follow or fade.");
  if (!["fixed", "conviction"].includes(rules.sizing)) refuse(400, "Sizing must be fixed or conviction.");
  positive(rules.marginPerTrade, "Margin per trade");
  positive(rules.maxLeverage, "Max leverage", { max: 100, integer: true });
  positive(rules.maxChaseBps, "Max chase", { max: 10_000, integer: true });
  if (rules.stopLossPercent != null) positive(rules.stopLossPercent, "Stop loss", { max: 100 });
  if (rules.takeProfitPercent != null) positive(rules.takeProfitPercent, "Take profit", { max: 10_000 });
  if (typeof rules.closeWithTrader !== "boolean") refuse(400, "Close with trader must be true or false.");
  // Conviction can double the margin, so it's the doubled figure that has to fit.
  const most = rules.marginPerTrade * (rules.sizing === "conviction" ? 2 : 1);
  if (most > caps.maxMarginPerTrade) refuse(403, `Up to ${most} AUSD a copy is more than the ${caps.maxMarginPerTrade} AUSD you approved with Face ID.`);
  if (rules.maxLeverage > caps.maxLeverage) refuse(403, `${rules.maxLeverage}x is past the ${caps.maxLeverage}x you approved with Face ID.`);
  return rules;
}

export function checkedGuards(json, caps) {
  let guards;
  try { guards = decodeGuards(json); } catch { refuse(400, "The limits are incomplete."); }
  positive(guards.maxOpenCopies, "Max open copies", { max: 100, integer: true });
  positive(guards.dailyLossLimit, "Daily loss limit");
  positive(guards.maxMarketExposure, "Max market exposure");
  if (guards.maxOpenCopies > caps.maxOpenCopies) refuse(403, `${guards.maxOpenCopies} open copies is past the ${caps.maxOpenCopies} you approved with Face ID.`);
  if (guards.dailyLossLimit > caps.maxDailyLoss) refuse(403, `A ${guards.dailyLossLimit} AUSD daily limit is past the ${caps.maxDailyLoss} AUSD you approved with Face ID.`);
  if (guards.maxMarketExposure > caps.maxOpenNotional) refuse(403, `${guards.maxMarketExposure} AUSD in one market is past the ${caps.maxOpenNotional} AUSD you approved with Face ID.`);
  return guards;
}

const guardsWithin = (caps) => ({
  maxOpenCopies: Math.min(DEFAULT_GUARDS.maxOpenCopies, caps.maxOpenCopies),
  dailyLossLimit: Math.min(DEFAULT_GUARDS.dailyLossLimit, caps.maxDailyLoss),
  maxMarketExposure: Math.min(DEFAULT_GUARDS.maxMarketExposure, caps.maxOpenNotional),
});

/// What the app may see of a copier: never the key id, the token or the grant's signature.
export function publicView(copier, { pausedBy = null } = {}) {
  return {
    account: copier.address, network: copier.network, serverKey: copier.publicKey,
    caps: copier.caps, guards: copier.guards, timeZone: copier.timeZone,
    paused: Boolean(copier.paused) || Boolean(pausedBy), pausedBy: pausedBy ?? (copier.paused ? "you" : null),
    traders: copier.traders, notifyShadow: copier.notifyShadow !== false, enrolledAt: copier.enrolledAt,
  };
}

// ---------- the handler ----------

function bodyText(req) {
  if (typeof req.body === "string") return req.body;
  if (Buffer.isBuffer(req.body)) return req.body.toString("utf8");
  return req.body == null ? "" : null; // parsed JSON: the bytes the device signed are gone
}

function parse(text) {
  if (!text) return {};
  try { return JSON.parse(text); } catch { return refuse(400, "The request body isn't JSON."); }
}

const header = (req, name) => {
  const value = req.headers?.[name.toLowerCase()];
  return Array.isArray(value) ? value[0] : value;
};

/// deps: store, kms (a KMSClient or stand-in; null when AWS isn't configured), tokenKey,
/// fetchImpl, now, kmsCommands (tests).
export function createCopyHandler(resolve) {
  return async function copy(req, res) {
    const deps = resolve();
    const { store } = deps;
    const now = deps.now ?? Date.now;
    const fetchImpl = deps.fetchImpl ?? fetch;
    res.setHeader?.("Cache-Control", "no-store");
    try {
      if (!store) refuse(503, "Auto-Copy from the server isn't switched on yet.");
      if (req.method !== "POST") refuse(405, "Send a POST.");
      const action = String(req.query?.action ?? "");
      const text = bodyText(req);

      if (action === "prepare" || action === "enroll") {
        const body = text === null ? req.body : parse(text);
        const network = body.network;
        if (!NETWORKS[network]) refuse(400, "Network must be mainnet or testnet.");
        if (!isAddress(String(body.address ?? ""))) refuse(400, "That isn't an account address.");
        const address = getAddress(body.address);
        const id = copierId(network, address);
        if (!deps.kms) refuse(503, "Auto-Copy from the server isn't switched on yet.");
        if (!deps.tokenKey) refuse(503, "Auto-Copy from the server isn't switched on yet.");
        const result = action === "prepare"
          ? await prepare({ req, deps, store, now, fetchImpl, network, address, id })
          : await enroll({ deps, store, now, fetchImpl, network, address, id, body });
        return res.status(200).json(result);
      }

      const signed = ["state", "rules", "pause", "resume", "close", "disable"];
      if (!signed.includes(action)) refuse(404, "No such Auto-Copy action.");
      if (text === null) refuse(415, "Send the body as text/plain, exactly as it was signed.");
      const { copier, body } = await authenticate({ req, store, now, action, text });
      const result = await ACTIONS[action]({ deps, store, now, copier, body });
      return res.status(200).json(result);
    } catch (error) {
      if (error instanceof Refusal) return res.status(error.status).json({ error: error.message });
      if (error instanceof PerplError) {
        const says = typeof error.body === "string" ? error.body.slice(0, 300) : null;
        return res.status(502).json({ error: "Perpl refused the key.", detail: error.message, perpl: error.status ?? null, perplSays: says });
      }
      return res.status(500).json({ error: "Something went wrong turning on Auto-Copy.", detail: String(error?.message ?? error) });
    }
  };
}

async function activeCopier(store, id) {
  const text = await store.get(K.copier(id));
  const copier = text ? JSON.parse(text) : null;
  return copier && !copier.disabled ? copier : null;
}

async function prepare({ req, deps, store, now, fetchImpl, network, address, id }) {
  const limit = await rateLimit({ store, tier: "expensive", ip: clientIp(req.headers ?? {}), now: now() });
  if (!limit.allowed) refuse(429, `Too many tries. Try again in ${limit.retryAfter}s.`);
  // Each prepare can cost a KMS key, so one account gets a handful an hour.
  const hour = Math.floor(now() / 3_600_000);
  const tries = await store.incr(C.prepares(id, hour));
  if (tries === 1) await store.expire(C.prepares(id, hour), 3_700);
  if (tries > PREPARES_PER_HOUR) refuse(429, "Too many tries for this account. Try again in an hour.");
  if (await activeCopier(store, id)) refuse(409, "Auto-Copy from the server is already on for this account.");

  const { chainId, base } = NETWORKS[network];
  const pendingText = await store.get(C.pending(id));
  const pending = pendingText ? JSON.parse(pendingText) : null;
  let signer;
  let generation;
  const reused = Boolean(pending) && now() - pending.createdAt < PENDING_FRESH_MS;
  if (reused) {
    signer = await kmsSigner({ client: deps.kms, keyId: pending.keyId, commands: deps.kmsCommands });
    generation = pending.generation;
  } else {
    // An earlier key nobody enrolled is retired before a new one is made.
    if (pending) await retireKey({ client: deps.kms, keyId: pending.keyId, commands: deps.kmsCommands }).catch(() => {});
    // The counter lives in Redis and KMS outlives it: a name already taken moves to the next.
    for (let attempt = 0; ; attempt++) {
      generation = await store.incr(C.generation(id));
      try {
        signer = await createKey({ client: deps.kms, network, address, generation, commands: deps.kmsCommands });
        break;
      } catch (error) {
        if (!/AlreadyExists|already exists/i.test(`${error?.name} ${error?.message}`) || attempt >= 20) throw error;
      }
    }
  }

  const response = await fetchImpl(`${base}/v1/api-key/payload`, {
    method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: payloadBody({ chainId, address, publicKey: signer.publicKey, label: LABEL }), redirect: "error",
  });
  const payloadText = await response.text();
  if (!response.ok) throw new PerplError(`Perpl answered ${response.status} to the payload request`, { status: response.status, body: payloadText });
  checkEnrolmentPayload(JSON.parse(jsonSpan(payloadText, "typed_data")), { address, publicKey: signer.publicKey, chainId });

  const createdAt = reused ? pending.createdAt : now();
  await store.set(C.pending(id), JSON.stringify({ keyId: signer.keyId, publicKey: signer.publicKey.toString("hex"), generation, payloadText, createdAt }), { ex: PENDING_KEEP_S });
  return { serverKey: `0x${signer.publicKey.toString("hex")}`, payload: payloadText, label: LABEL, expiresAt: createdAt + PENDING_FRESH_MS };
}

async function enroll({ deps, store, now, fetchImpl, network, address, id, body }) {
  if (await activeCopier(store, id)) refuse(409, "Auto-Copy from the server is already on for this account.");
  const pendingText = await store.get(C.pending(id));
  if (!pendingText) refuse(409, "That setup expired. Start again.");
  const pending = JSON.parse(pendingText);
  if (now() - pending.createdAt > PENDING_FRESH_MS + 5 * 60_000) refuse(409, "That setup expired. Start again.");

  const grant = await verifyGrant({ text: body.grant?.text, signature: body.grant?.signature, account: address });
  if (grant.network !== network) refuse(400, "The grant is for the other network.");
  if (grant.serverKey !== `0x${pending.publicKey}`) refuse(400, "The grant names another server key.");
  if (Math.abs(now() - grant.issuedAt) > GRANT_SKEW_MS) refuse(400, "The grant is too old. Start again.");
  deviceKeyObject(grant.deviceKey);

  const { chainId, base } = NETWORKS[network];
  const signer = await kmsSigner({ client: deps.kms, keyId: pending.keyId, commands: deps.kmsCommands });
  // These checks are the server's own, before anything reaches Perpl.
  let enrolText;
  try {
    ({ body: enrolText } = await enrolBody({ payloadText: pending.payloadText, chainId, address, walletSignature: body.walletSignature, signer }));
  } catch (error) {
    if (error instanceof PerplError || /signature/i.test(String(error?.message))) refuse(403, "The Perpl registration wasn't signed by this account.");
    throw error;
  }
  const response = await fetchImpl(`${base}/v1/api-key/enroll`, {
    method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" }, body: enrolText, redirect: "error",
  });
  const answer = await response.text();
  // Seen on testnet with a wallet that had never deposited: Perpl has no account to attach a key to.
  if (response.status === 404) refuse(409, "This wallet has no Perpl account yet. Make a first deposit, then turn Auto-Copy on.");
  if (!response.ok) throw new PerplError(`Perpl answered ${response.status} to the enrolment`, { status: response.status, body: answer });
  const token = tokenFrom(JSON.parse(answer));

  const timeZone = typeof body.timeZone === "string" && body.timeZone.length <= 64 ? body.timeZone : "UTC";
  const push = body.push?.token && /^[0-9a-f]{64,200}$/i.test(body.push.token)
    ? { token: body.push.token, environment: body.push.environment === "development" ? "development" : "production" } : null;
  const copier = {
    id, network, address, keyId: signer.keyId, publicKey: pending.publicKey, generation: pending.generation,
    apiKey: seal(token, deps.tokenKey), deviceKey: grant.deviceKey, caps: grant.caps,
    grant: { text: body.grant.text, signature: body.grant.signature },
    guards: guardsWithin(grant.caps), traders: {}, paused: false, timeZone, push,
    notifyShadow: body.notifyShadow !== false, enrolledAt: now(),
  };
  await store.pipeline([
    ["SET", K.copier(id), JSON.stringify(copier)],
    ["SADD", K.copiers, id],
    ["SADD", K.dirty, id],
    ["DEL", C.pending(id)],
  ]);
  return { enabled: true, copier: publicView(copier) };
}

/// Every request after enrolment: signed by the device key the grant registered, within a
/// minute of now, and never twice.
async function authenticate({ req, store, now, action, text }) {
  const network = header(req, "X-Desk-Network");
  const account = header(req, "X-Desk-Account");
  const time = header(req, "X-Desk-Time");
  const nonce = header(req, "X-Desk-Nonce");
  const signature = header(req, "X-Desk-Signature");
  if (!NETWORKS[network] || !isAddress(String(account ?? "")) || !/^\d{10,16}$/.test(String(time ?? "")) || !/^[A-Za-z0-9_-]{16,64}$/.test(String(nonce ?? "")) || !signature) {
    refuse(401, "This request isn't signed.");
  }
  if (Math.abs(now() - Number(time)) > REQUEST_WINDOW_MS) refuse(401, "This request's clock is off by more than a minute.");
  const id = copierId(network, account);
  const copier = await activeCopier(store, id);
  if (!copier) refuse(404, "Auto-Copy from the server isn't on for this account.");
  const message = deviceCanonical({ chainId: NETWORKS[network].chainId, method: "POST", target: `/api/copy/${action}`, time, nonce, body: text });
  if (!verifyDevice(copier.deviceKey, message, signature)) refuse(401, "This request wasn't signed by the phone that turned Auto-Copy on.");
  if (!(await store.set(C.nonce(id, nonce), "1", { nx: true, ex: NONCE_TTL_S }))) refuse(409, "This request was already used.");
  return { copier, body: parse(text) };
}

async function writeCopier(store, copier, extra = []) {
  await store.pipeline([["SET", K.copier(copier.id), JSON.stringify(copier)], ["SADD", K.dirty, copier.id], ...extra]);
}

const ACTIONS = {
  async state({ store, now, copier }) {
    const [open, log, pausedBy, heartbeat] = await Promise.all([
      store.get(K.open(copier.id)), store.lrange(K.log(copier.id), 0, Math.min(100, LOG_LIMIT) - 1),
      store.get(K.pause(copier.id)), store.get(C.heartbeat),
    ]);
    return {
      copier: publicView(copier, { pausedBy }),
      open: open ? JSON.parse(open) : [],
      log: log.map((row) => JSON.parse(row)),
      engine: { lastSweepAgoMs: heartbeat ? now() - Number(heartbeat) : null },
    };
  },

  /// Whole replacement of who is followed and how; traders kept keep their `since`.
  async rules({ store, now, copier, body }) {
    const next = { ...copier };
    const extra = [];
    if (body.traders !== undefined) {
      if (typeof body.traders !== "object" || body.traders === null || Array.isArray(body.traders)) refuse(400, "Traders must be an object of address to rules.");
      const entries = Object.entries(body.traders);
      if (entries.length > 50) refuse(400, "Follow at most 50 traders.");
      const traders = {};
      for (const [address, entry] of entries) {
        if (!isAddress(address)) refuse(400, `${address} isn't an address.`);
        const key = address.toLowerCase();
        traders[key] = { rules: checkedRules(entry?.rules, copier.caps), since: copier.traders?.[key]?.since ?? now() };
      }
      for (const trader of Object.keys(copier.traders ?? {})) if (!traders[trader]) extra.push(["SREM", K.followers(trader), copier.id]);
      for (const trader of Object.keys(traders)) extra.push(["SADD", K.followers(trader), copier.id], ["SADD", K.traders, trader]);
      next.traders = traders;
    }
    if (body.guards !== undefined) next.guards = checkedGuards(body.guards, copier.caps);
    if (body.timeZone !== undefined) {
      try { new Intl.DateTimeFormat("en-US", { timeZone: body.timeZone }); } catch { refuse(400, "That isn't a time zone."); }
      next.timeZone = body.timeZone;
    }
    if (body.notifyShadow !== undefined) next.notifyShadow = Boolean(body.notifyShadow);
    await writeCopier(store, next, extra);
    return { copier: publicView(next) };
  },

  async pause({ store, copier }) {
    const next = { ...copier, paused: true };
    await writeCopier(store, next);
    return { copier: publicView(next) };
  },

  /// Clears the engine's own pause too: the daily loss limit's pause ends when the person says so.
  async resume({ store, copier }) {
    const next = { ...copier, paused: false };
    await writeCopier(store, next, [["DEL", K.pause(copier.id)]]);
    return { copier: publicView(next) };
  },

  /// Asks the engine to close one copy now; it does on its next look, within a sweep.
  async close({ store, copier, body }) {
    const copyId = String(body.copyId ?? "");
    const open = JSON.parse((await store.get(K.open(copier.id))) ?? "[]");
    if (!open.some((copy) => copy.id === copyId)) refuse(404, "That copy isn't open.");
    await store.pipeline([["SADD", K.close(copier.id), copyId], ["SADD", K.dirty, copier.id]]);
    return { closing: copyId };
  },

  /// Stops copying at once and retires the key. Open copies stay open, with whatever stops the
  /// venue holds for them; Perpl's own revoke is the app's to offer.
  async disable({ deps, store, now, copier }) {
    let keyRetired = true;
    try { await retireKey({ client: deps.kms, keyId: copier.keyId, commands: deps.kmsCommands }); } catch { keyRetired = false; }
    const next = { ...copier, disabled: true, disabledAt: now(), traders: {} };
    const extra = [["SREM", K.copiers, copier.id]];
    for (const trader of Object.keys(copier.traders ?? {})) extra.push(["SREM", K.followers(trader), copier.id]);
    await writeCopier(store, next, extra);
    return { disabled: true, keyRetired };
  },
};

export { C as COPY_KEYS };
