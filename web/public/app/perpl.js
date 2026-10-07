// Perpl from the browser, through Desk's relay. Every signed request is signed here, over the
// exact path, query and body the relay forwards; the relay adds nothing and cannot sign. The
// API key token is kept per wallet in this browser, as the phone keeps its own in the keychain:
// it is useless without the trading key, which lives only in the unlocked session.
import { enrolmentSignatures, signedHeaders, toHex } from "./keys.js";
import { retradingKey, session } from "./session.js";

export const CHAIN_ID = 143;
const KEY_ATTEMPTS = 4;
const keyStore = (address) => `desk.web.perpl-key:${String(address).toLowerCase()}`;

export function storedKey(address) {
  try { return JSON.parse(localStorage.getItem(keyStore(address)) ?? "null"); } catch { return null; }
}
export function forgetKey(address) { try { localStorage.removeItem(keyStore(address)); } catch {} }
function rememberKey(address, token, tradingIndex) {
  try { localStorage.setItem(keyStore(address), JSON.stringify({ token, tradingIndex, at: Date.now() })); } catch {}
}

/// The signed target: path and query built with URLSearchParams, as the relay rebuilds them.
function target(path, query) {
  const search = query ? new URLSearchParams(query).toString() : "";
  return `/v1/${path}${search ? `?${search}` : ""}`;
}

export class PerplError extends Error {
  constructor(message, { status, body } = {}) { super(message); this.status = status; this.body = body; }
}

function describe(body, status) {
  if (!body) return `Perpl answered ${status}.`;
  if (typeof body === "string") return body.slice(0, 200);
  return body.error ?? body.detail ?? body.message ?? body.status?.error ?? `Perpl answered ${status}.`;
}

/// One request to Perpl. `sign` is `{ apiKey, seed }` for the trading endpoints; the payload
/// and enrol calls are public. `raw: true` returns the response text untouched.
export async function perpl(method, path, { query, body, sign, raw = false } = {}) {
  const t = target(path, query);
  const text = body == null ? "" : typeof body === "string" ? body : JSON.stringify(body);
  const headers = { accept: "application/json" };
  if (sign) Object.assign(headers, signedHeaders({ apiKey: sign.apiKey, tradingSeed: sign.seed, chainId: CHAIN_ID, method, target: t, body: text }));
  // text/plain, so the relay receives the bytes that were hashed rather than a re-parsed object.
  if (method !== "GET") headers["content-type"] = "text/plain;charset=UTF-8";
  const response = await fetch(`/api/v1/perpl${t.slice(3)}`, { method, headers, body: method === "GET" ? undefined : text });
  const answer = await response.text();
  let parsed = null;
  try { parsed = answer ? JSON.parse(answer) : null; } catch { parsed = answer; }
  if (!response.ok) throw new PerplError(describe(parsed, response.status), { status: response.status, body: parsed });
  return raw ? answer : parsed;
}

// Context: chain, instances, tokens and markets, ten seconds at a time.
let contextCache = { at: 0, value: null };
export async function context() {
  if (contextCache.value && Date.now() - contextCache.at < 10_000) return contextCache.value;
  const value = await perpl("GET", "pub/context");
  contextCache = { at: Date.now(), value };
  return value;
}

export const n = (value) => (value == null ? null : Number(value));

/// The exchange, the collateral token and the limits that matter, from the context.
export function exchangeOf(ctx) {
  const instance = ctx.instances?.[0];
  const token = (ctx.tokens ?? []).find((t) => t.symbol === "AUSD") ?? (ctx.tokens ?? []).find((t) => n(t.id) === n(instance?.collateral_token_id));
  if (!instance || !token) throw new PerplError("Perpl's context has no exchange or no AUSD.");
  return {
    exchange: instance.address, token: token.address, tokenDecimals: n(token.decimals) ?? 6,
    minAccountOpenRaw: BigInt(instance.min_account_open_amount ?? 0), minDepositRaw: BigInt(instance.min_deposit_amount ?? 0), minWithdrawRaw: BigInt(instance.min_withdraw_amount ?? 0),
  };
}

export function marketOf(ctx, symbol) {
  // Perpl names a market in `name` and sometimes leaves `symbol` empty.
  const wanted = String(symbol).toUpperCase();
  const market = (ctx.markets ?? []).find((m) => [m.name, m.symbol].some((v) => String(v ?? "").toUpperCase() === wanted));
  if (!market) throw new PerplError(`Perpl lists no market called ${symbol}.`);
  return {
    id: n(market.id), instanceId: n(market.instance_id), symbol: market.name || market.symbol,
    priceDecimals: n(market.config?.price_decimals), sizeDecimals: n(market.config?.size_decimals),
    maxLeverageHundredths: n(market.config?.initial_margin), maxSlippageBps: n(market.order_max_market_slippage_bps) || 50,
  };
}

// --- the account

const creds = () => {
  const s = session();
  if (!s) throw new PerplError("Unlock with your passkey first.");
  const key = storedKey(s.address);
  if (!key) return null;
  if (key.tradingIndex !== s.trading.index) retradingKey(key.tradingIndex);
  return { apiKey: key.token, seed: session().trading.seed };
};

/// A minimal JSON scanner: the raw bytes of one top-level member, so what Perpl signed its
/// mac over goes back to it untouched rather than re-serialised.
function jsonSpan(text, key) {
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

/// The trading key's API token: the stored one, or an enrolment. Perpl never re-enrols a key it
/// has revoked, so a refusal moves to the next derived key inside the same session.
export async function ensureKey({ label = "Desk on the web", onEnrolling = () => {} } = {}) {
  const existing = creds();
  if (existing) return existing;
  const s = session();
  const first = s.trading.index;
  let last = null;
  for (let index = first; index < first + KEY_ATTEMPTS; index++) {
    const trading = index === session().trading.index ? session().trading : retradingKey(index);
    onEnrolling(index);
    try {
      const payloadText = await perpl("POST", "api-key/payload", {
        body: { chain_id: CHAIN_ID, address: s.address, public_key: toHex(trading.publicKey), scope_mask: 3, label }, raw: true,
      });
      const typedRaw = jsonSpan(payloadText, "typed_data");
      const macRaw = jsonSpan(payloadText, "mac");
      const typedData = JSON.parse(typedRaw);
      const { signature, pop } = await enrolmentSignatures(typedData, { wallet: s.wallet, trading, chainId: CHAIN_ID });
      const enrolBody = `{"chain_id":${CHAIN_ID},"address":"${s.address}","typed_data":${typedRaw},"mac":${macRaw},"signature":"${signature}","pop_signature":"${pop}"}`;
      let enrolled;
      try { enrolled = await perpl("POST", "api-key/enroll", { body: enrolBody }); }
      catch (error) {
        if (error.status === 404) throw new PerplError("Perpl has no account for this wallet yet. Open your desk first, then this browser's key can be registered.");
        throw error;
      }
      const token = typeof enrolled?.api_key === "string" ? enrolled.api_key : enrolled?.api_key?.api_key;
      if (!token) throw new PerplError("Perpl returned an enrolment without a key.");
      rememberKey(s.address, token, index);
      return { apiKey: token, seed: trading.seed };
    } catch (error) {
      last = error;
      if (!/already|revoked|exists|in use|duplicate/i.test(String(error.message))) throw error;
    }
  }
  throw last ?? new PerplError("Perpl refused every key Desk derived.");
}

export const wallet = (sign) => perpl("GET", "trading/wallet", { sign });
export const positions = (sign) => perpl("GET", "trading/positions", { sign });
export const orders = (sign) => perpl("GET", "trading/orders", { sign });

/// The account to trade with on `instanceId`, from the wallet snapshot: its id and the last
/// request id Perpl forwarded, which the next order must exceed.
export function accountFor(snapshot, instanceId) {
  const list = snapshot?.as ?? snapshot?.accounts ?? [];
  const found = list.find((a) => instanceId == null || a.in == null || n(a.in) === n(instanceId)) ?? list[0];
  if (!found) return null;
  return { id: n(found.id), lastForwarded: found.lfr == null ? null : BigInt(found.lfr), balanceRaw: found.b == null ? null : BigInt(found.b), forwarding: Boolean(found.fw), frozen: Boolean(found.fr) };
}

let requestClock = 0n;
/// Strictly increasing per account: one past what Perpl last forwarded, and past anything
/// handed out this session.
function nextRequestId(account) {
  const floor = (account?.lastForwarded ?? 0n) + 1n;
  const now = BigInt(Date.now());
  const next = floor > requestClock ? floor : requestClock + 1n;
  requestClock = next > now ? next : (floor > now ? floor : now);
  return requestClock;
}

/// A market order, immediate-or-cancel within `slippageBps`, as the app sends it. Opens use
/// types 1 and 2; closes use 3 and 4, which are exempt from the initial-margin check so an
/// underwater position can always be closed.
export async function placeOrder(sign, { account, market, kind, side, sizeRaw, leverageHundredths = 100, slippageBps }) {
  const type = kind === "close" ? (side === "long" ? 3 : 4) : (side === "long" ? 1 : 2);
  const rq = nextRequestId(account);
  const spec = { rq: Number(rq), mkt: market.id, acc: account.id, t: type, p: 0, s: Number(sizeRaw), fl: 4, lv: kind === "close" ? 100 : leverageHundredths, lb: 0, ms: slippageBps };
  const answer = await perpl("POST", "trading/orders", { sign, body: { mt: 30, d: [spec] } });
  const status = answer?.statuses?.[0] ?? answer?.status ?? null;
  if (status && Number(status.code) !== 0) throw new PerplError(status.error ? `Perpl refused the order: ${status.error}` : `Perpl refused the order (code ${status.code}).`, { body: answer });
  return { rq, spec, answer };
}

/// Perpl's position rows, in decimals: side, size, entry, collateral and leverage.
export function describePositions(answer, ctx) {
  const rows = answer?.d ?? answer?.positions ?? [];
  return rows.map((p) => {
    const market = (ctx.markets ?? []).find((m) => n(m.id) === n(p.mkt));
    const pd = n(market?.config?.price_decimals) ?? 2, sd = n(market?.config?.size_decimals) ?? 4;
    return {
      id: String(p.pid), marketId: n(p.mkt), market: market?.name || market?.symbol || String(p.mkt), accountId: n(p.acc),
      side: n(p.sd) === 2 ? "short" : "long", sizeRaw: BigInt(p.s ?? 0), size: Number(p.s ?? 0) / 10 ** sd,
      entry: Number(p.ep ?? 0) / 10 ** pd, collateral: Number(p.c ?? 0) / 1e6, leverage: (n(p.lv) ?? 100) / 100,
      status: n(p.st), priceDecimals: pd, sizeDecimals: sd,
    };
  }).filter((p) => p.sizeRaw > 0n);
}
