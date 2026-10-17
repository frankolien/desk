/// /api/copy/spot-*: spot Auto-Copy (docs/spot-copy.md), served by the same copy handler.
///
/// spot-prepare  what the phone needs to sign: Desk's copy key, the hook, the wallet's nonces.
/// spot-enable   the one Face ID: the wallet's Calibur batch that registers Desk's key behind the
///               hook (and the EIP-7702 authorization if the wallet doesn't run Calibur on Monad
///               yet), and a short grant text naming the phone's device key. The server rebuilds
///               every byte it expects, checks both signatures and queues the batch for copyd.
/// Everything after is signed by the device key: spot-state, spot-rules, spot-pause,
/// spot-resume. spot-limits and spot-disable also carry a new wallet-signed batch.
import { getAddress, isAddress, verifyMessage } from "viem";
import { SPOT, authorizedByWallet, batchFor, keyHashOf, signedByWallet } from "../copyd/spot-chain.mjs";
import { S, SPOT_LOG_LIMIT, live } from "../copyd/spot-engine.mjs";
import { DEFAULT_SPOT_RULES, checkedSpotRules } from "../copyd/spot-rules.mjs";
import { deviceCanonical, deviceKeyObject, verifyDevice } from "./_copy.mjs";

const DEADLINE_MAX_S = 30 * 60;
const GRANT_SKEW_MS = 10 * 60_000;
const REQUEST_WINDOW_MS = 60_000;
const NONCE_TTL_S = 120;
const MAX_DAYS = 90;
const MAX_LEADERS = 25;

export class SpotRefusal extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const refuse = (status, message) => { throw new SpotRefusal(status, message); };

export const DEFAULT_LIMITS = Object.freeze({ perTrade: 25, perDay: 100, days: 30 });

/// The text the wallet signs (EIP-191) to name the phone that may steer copying afterwards.
export function spotGrantText({ wallet, desk, deviceKey, perTrade, perDay, expiry, issuedAt }) {
  return [
    "Desk Spot Auto-Copy",
    "I let Desk's key copy token trades for this wallet, within these limits, until the date below.",
    `Wallet: ${getAddress(wallet)}`,
    `Desk key: ${getAddress(desk)}`,
    `Device key: ${deviceKey}`,
    `Max per buy: ${perTrade} AUSD`,
    `Max per day: ${perDay} AUSD`,
    `Until: ${new Date(expiry * 1000).toISOString()}`,
    `Issued: ${new Date(issuedAt).toISOString()}`,
  ].join("\n");
}

const number = (value, name, { min, max }) => {
  const n = Number(value);
  if (!Number.isFinite(n) || n < min || n > max) refuse(400, `${name} must be from ${min} to ${max}.`);
  return n;
};

function checkedLimits(body, nowMs) {
  const perTrade = number(body.perTrade, "Max per buy", { min: 1, max: 100_000 });
  const perDay = number(body.perDay, "Max per day", { min: 1, max: 1_000_000 });
  // Whole AUSD, so the phone's encoding and the server's can't differ by a rounding.
  if (!Number.isInteger(perTrade) || !Number.isInteger(perDay)) refuse(400, "Limits are whole AUSD.");
  if (perTrade > perDay) refuse(400, "Max per buy can't be more than max per day.");
  const expiry = number(body.expiry, "The end date", { min: Math.floor(nowMs / 1000) + 3600, max: Math.floor(nowMs / 1000) + MAX_DAYS * 86_400 });
  if (!Number.isInteger(expiry)) refuse(400, "The end date must be whole seconds.");
  return { perTrade, perDay, expiry };
}

function checkedBatchFields(body, nowMs) {
  const nonce = String(body.nonce ?? "");
  const deadline = Number(body.deadline);
  if (!/^\d{1,78}$/.test(nonce)) refuse(400, "The batch nonce is missing.");
  const nowS = Math.floor(nowMs / 1000);
  if (!Number.isInteger(deadline) || deadline <= nowS || deadline > nowS + DEADLINE_MAX_S) refuse(400, "The batch deadline must be within 30 minutes.");
  if (!/^0x[0-9a-fA-F]{128,130}$/.test(String(body.signature ?? ""))) refuse(400, "The batch signature is missing.");
  return { nonce, deadline, signature: body.signature };
}

const parse = (text) => { try { return text ? JSON.parse(text) : null; } catch { return null; } };

export function publicSpotView(copier) {
  if (!copier) return null;
  return {
    wallet: copier.wallet, stage: copier.stage, limits: copier.limits, expiry: copier.expiry,
    paused: Boolean(copier.paused), pausedBy: copier.paused ? (copier.pausedBy ?? "you") : null,
    leaders: copier.leaders ?? {}, error: copier.error ?? null, enabledAt: copier.enabledAt ?? null,
    lastHash: copier.lastHash ?? null,
  };
}

async function deskInfo(store) {
  const info = parse(await store.get(S.desk));
  if (!info?.address || !info?.hook) refuse(503, "Spot Auto-Copy isn't switched on yet.");
  return info;
}

function pushFrom(push) {
  if (!push?.token || !/^[0-9a-f]{64,200}$/i.test(push.token)) return null;
  return { token: push.token, environment: push.environment === "sandbox" ? "sandbox" : "production" };
}

/// deps: store, spotReads(desk) → the chain reads (spot-node's spotReads over a Monad reader).
export async function handleSpot({ action, req, deps, text, now, header }) {
  const { store } = deps;
  const desk = await deskInfo(store);
  if (!deps.spotReads) refuse(503, "Spot Auto-Copy isn't switched on yet.");
  const reads = deps.spotReads(desk);
  const unsigned = () => parse(text) ?? (typeof req.body === "object" && req.body ? req.body : {});
  if (action === "spot-prepare") return prepare({ store, desk, reads, body: unsigned(), now });
  if (action === "spot-enable") return enable({ store, desk, reads, body: unsigned(), now });
  const signed = ["spot-state", "spot-rules", "spot-pause", "spot-resume", "spot-limits", "spot-disable"];
  if (!signed.includes(action)) refuse(404, "No such Auto-Copy action.");
  if (text === null) refuse(415, "Send the body as text/plain, exactly as it was signed.");
  const copier = await authenticate({ store, header, now, action, text });
  return SIGNED[action]({ store, desk, reads, copier, body: parse(text) ?? {}, now });
}

async function prepare({ store, desk, reads, body, now }) {
  if (!isAddress(String(body.wallet ?? ""))) refuse(400, "That isn't a wallet address.");
  const wallet = getAddress(body.wallet);
  const state = await reads.wallet(wallet);
  if (state.delegation === "other") refuse(409, "This wallet already runs other smart-account code on Monad, so Desk can't add its key.");
  const nowS = Math.floor(now() / 1000);
  return {
    chainId: SPOT.chainId, calibur: SPOT.calibur, ausd: SPOT.ausd, holder: SPOT.holder,
    desk: desk.address, hook: desk.hook, keyHash: keyHashOf(desk.address), executor: desk.address,
    delegation: state.delegation, registered: state.registered,
    authorizationNonce: state.delegation === "none" ? String(state.transactions) : null,
    batchNonce: String(state.seq), deadline: nowS + 15 * 60,
    defaults: DEFAULT_LIMITS, rules: DEFAULT_SPOT_RULES, feeBps: desk.feeBps ?? 0,
    copier: publicSpotView(parse(await store.get(S.copier(wallet)))),
  };
}

async function enable({ store, desk, reads, body, now }) {
  if (!isAddress(String(body.wallet ?? ""))) refuse(400, "That isn't a wallet address.");
  const wallet = getAddress(body.wallet);
  const existing = parse(await store.get(S.copier(wallet)));
  if (existing && ["enabling", "live"].includes(existing.stage)) refuse(409, "Spot Auto-Copy is already on for this wallet.");
  deviceKeyObject(body.deviceKey);
  const limits = checkedLimits(body, now());
  const batch = checkedBatchFields(body, now());

  const issuedAt = Number(body.grant?.issuedAt);
  if (!Number.isFinite(issuedAt) || Math.abs(now() - issuedAt) > GRANT_SKEW_MS) refuse(400, "The grant is too old; try again.");
  const grant = spotGrantText({ wallet, desk: desk.address, deviceKey: body.deviceKey, ...limits, issuedAt });
  const grantOk = await verifyMessage({ address: wallet, message: grant, signature: body.grant?.signature }).catch(() => false);
  if (!grantOk) refuse(401, "The grant wasn't signed by this wallet.");

  const state = await reads.wallet(wallet);
  if (state.delegation === "other") refuse(409, "This wallet already runs other smart-account code on Monad, so Desk can't add its key.");
  if (state.registered) refuse(409, "Desk's key is already on this wallet; turn it off first.");
  let authorization = null;
  if (state.delegation === "none") {
    const a = body.authorization;
    if (!a || String(a.nonce) !== String(state.transactions)) refuse(400, "The wallet's EIP-7702 authorization is missing or stale.");
    authorization = { chainId: Number(a.chainId), address: getAddress(a.address), nonce: Number(a.nonce), r: a.r, s: a.s, yParity: Number(a.yParity) };
    if (!(await authorizedByWallet({ wallet, authorization }))) refuse(401, "The EIP-7702 authorization wasn't signed by this wallet for Calibur on Monad.");
  }
  if (batch.nonce !== String(state.seq)) refuse(409, "The wallet's batch nonce moved; try again.");
  const typed = batchFor({ kind: "enable", wallet, desk: desk.address, hook: desk.hook, ...batch, ...limits });
  if (!(await signedByWallet({ wallet, typed, signature: batch.signature }))) refuse(401, "The setup wasn't signed by this wallet.");

  const leaders = checkedLeaders(body.leaders ?? {}, limits.perTrade, existing?.leaders, now());
  const copier = {
    wallet: wallet.toLowerCase(), stage: "enabling", deviceKey: body.deviceKey, push: pushFrom(body.push),
    limits: { perTrade: limits.perTrade, perDay: limits.perDay }, expiry: limits.expiry,
    leaders, paused: false, failures: 0, requestedAt: now(),
  };
  const job = { kind: "enable", wallet: copier.wallet, batch: { ...batch, ...limits }, authorization };
  await store.pipeline([
    ["SET", S.copier(wallet), JSON.stringify(copier)], ["SADD", S.wallets, copier.wallet],
    ...followCommands(existing?.leaders ?? {}, leaders, copier.wallet),
    ["RPUSH", S.jobs, JSON.stringify(job)],
  ]);
  return { copier: publicSpotView(copier) };
}

function checkedLeaders(json, perTradeAusd, previous = {}, nowMs) {
  if (typeof json !== "object" || json === null || Array.isArray(json)) refuse(400, "Leaders must be an object of address to rules.");
  const entries = Object.entries(json);
  if (entries.length > MAX_LEADERS) refuse(400, `Copy at most ${MAX_LEADERS} wallets.`);
  const out = {};
  for (const [address, entry] of entries) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(address)) refuse(400, `${address} isn't a Monad wallet.`);
    const key = address.toLowerCase();
    let rules;
    try { rules = checkedSpotRules(entry?.rules ?? {}, { perTradeAusd }); } catch (error) { refuse(400, error.message); }
    out[key] = { rules, since: previous?.[key]?.since ?? nowMs, name: typeof entry?.name === "string" ? entry.name.slice(0, 40) : null };
  }
  return out;
}

function followCommands(before, after, wallet) {
  const commands = [];
  for (const leader of Object.keys(before)) if (!after[leader]) commands.push(["SREM", S.followers(leader), wallet]);
  for (const leader of Object.keys(after)) commands.push(["SADD", S.followers(leader), wallet], ["SADD", S.leaders, leader]);
  return commands;
}

async function authenticate({ store, header, now, action, text }) {
  const wallet = header("X-Desk-Wallet");
  const time = header("X-Desk-Time");
  const nonce = header("X-Desk-Nonce");
  const signature = header("X-Desk-Signature");
  if (!isAddress(String(wallet ?? "")) || !/^\d{10,16}$/.test(String(time ?? "")) || !/^[A-Za-z0-9_-]{16,64}$/.test(String(nonce ?? "")) || !signature) {
    refuse(401, "This request isn't signed.");
  }
  if (Math.abs(now() - Number(time)) > REQUEST_WINDOW_MS) refuse(401, "This request's clock is off by more than a minute.");
  const copier = parse(await store.get(S.copier(wallet)));
  if (!copier || copier.stage === "off") refuse(404, "Spot Auto-Copy isn't on for this wallet.");
  const message = deviceCanonical({ chainId: SPOT.chainId, method: "POST", target: `/api/copy/${action}`, time, nonce, body: text });
  if (!verifyDevice(copier.deviceKey, message, signature)) refuse(401, "This request wasn't signed by the phone that turned Spot Auto-Copy on.");
  if (!(await store.set(`copy:spot:nonce:${copier.wallet}:${nonce}`, "1", { nx: true, ex: NONCE_TTL_S }))) refuse(409, "This request was already used.");
  return copier;
}

const SIGNED = {
  async "spot-state"({ store, reads, copier, now }) {
    const rows = (await store.lrange(S.log(copier.wallet), 0, Math.min(100, SPOT_LOG_LIMIT) - 1)).map((row) => JSON.parse(row));
    const tokens = [...new Set(rows.filter((row) => row.side === "buy" && row.status === "copied").map((row) => row.token))].slice(0, 20);
    const [held, remaining] = await Promise.all([
      Promise.all(tokens.map((token) => reads.copied(copier.wallet, token).then(String).catch(() => null))),
      copier.stage === "live" ? reads.remainingToday(copier.wallet).then(String).catch(() => null) : null,
    ]);
    const positions = tokens.map((token, i) => ({ token, symbol: rows.find((row) => row.token === token)?.symbol ?? null, copiedRaw: held[i] }))
      .filter((position) => position.copiedRaw && position.copiedRaw !== "0");
    return { copier: publicSpotView(copier), live: live(copier, now()), remainingTodayRaw: remaining, positions, log: rows };
  },

  async "spot-rules"({ store, copier, body, now }) {
    const next = { ...copier };
    const commands = [];
    if (body.leaders !== undefined) {
      next.leaders = checkedLeaders(body.leaders, copier.limits.perTrade, copier.leaders, now());
      commands.push(...followCommands(copier.leaders ?? {}, next.leaders, copier.wallet));
    }
    if (body.push !== undefined) next.push = pushFrom(body.push);
    await store.pipeline([["SET", S.copier(copier.wallet), JSON.stringify(next)], ...commands]);
    return { copier: publicSpotView(next) };
  },

  async "spot-pause"({ store, copier }) {
    const next = { ...copier, paused: true, pausedBy: "you" };
    await store.set(S.copier(copier.wallet), JSON.stringify(next));
    return { copier: publicSpotView(next) };
  },

  async "spot-resume"({ store, copier }) {
    const next = { ...copier, paused: false, pausedBy: null, failures: 0 };
    await store.set(S.copier(copier.wallet), JSON.stringify(next));
    return { copier: publicSpotView(next) };
  },

  /// New limits or a new end date: one more wallet-signed batch, relayed like the first.
  async "spot-limits"({ store, desk, reads, copier, body, now }) {
    if (copier.stage !== "live") refuse(409, "Spot Auto-Copy isn't running on this wallet.");
    const limits = checkedLimits(body, now());
    const batch = checkedBatchFields(body, now());
    const state = await reads.wallet(copier.wallet);
    if (batch.nonce !== String(state.seq)) refuse(409, "The wallet's batch nonce moved; try again.");
    const typed = batchFor({ kind: "limits", wallet: copier.wallet, desk: desk.address, hook: desk.hook, ...batch, ...limits });
    if (!(await signedByWallet({ wallet: copier.wallet, typed, signature: batch.signature }))) refuse(401, "The new limits weren't signed by this wallet.");
    await store.rpush(S.jobs, JSON.stringify({ kind: "limits", wallet: copier.wallet, batch: { ...batch, ...limits }, limits: { perTrade: limits.perTrade, perDay: limits.perDay }, expiry: limits.expiry }));
    return { copier: publicSpotView(copier), pending: "limits" };
  },

  /// Copying stops at once (no leaders); Desk's key comes off the wallet when copyd relays the
  /// signed revoke. If it never did, the app can send the same revoke with the wallet's own gas.
  async "spot-disable"({ store, desk, reads, copier, body, now }) {
    const batch = checkedBatchFields(body, now());
    const state = await reads.wallet(copier.wallet);
    if (batch.nonce !== String(state.seq)) refuse(409, "The wallet's batch nonce moved; try again.");
    const typed = batchFor({ kind: "disable", wallet: copier.wallet, desk: desk.address, hook: desk.hook, ...batch });
    if (!(await signedByWallet({ wallet: copier.wallet, typed, signature: batch.signature }))) refuse(401, "Turning off wasn't signed by this wallet.");
    const next = { ...copier, stage: "stopping", leaders: {} };
    await store.pipeline([
      ["SET", S.copier(copier.wallet), JSON.stringify(next)],
      ...followCommands(copier.leaders ?? {}, {}, copier.wallet),
      ["RPUSH", S.jobs, JSON.stringify({ kind: "disable", wallet: copier.wallet, batch })],
    ]);
    return { copier: publicSpotView(next) };
  },
};
