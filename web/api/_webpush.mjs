import { createCipheriv, createECDH, createPrivateKey, hkdfSync, randomBytes, sign } from "node:crypto";

/// Browser push with Node's crypto alone: RFC 8030 delivery, RFC 8291 encryption and
/// RFC 8292 VAPID. A browser's subscription is an endpoint at its push service plus two
/// keys; each message is encrypted to those keys and the request is signed with Desk's
/// VAPID key, so the service knows who sends and only that browser can read.

/// Where browsers' endpoints live. The server posts to whatever endpoint a subscription
/// names, so it only accepts the services browsers actually use.
export const PUSH_SERVICES = [
  /(^|\.)fcm\.googleapis\.com$/,
  /(^|\.)push\.apple\.com$/,
  /(^|\.)push\.services\.mozilla\.com$/,
  /(^|\.)notify\.windows\.com$/,
];
const RECORD_SIZE = 4096;
const MAX_PLAINTEXT = RECORD_SIZE - 1 - 16 - 86;
const TOKEN_LIFETIME_S = 12 * 3600;

export function pushServiceAllowed(endpoint) {
  let url;
  try { url = new URL(endpoint); } catch { return false; }
  return url.protocol === "https:" && PUSH_SERVICES.some((rule) => rule.test(url.hostname));
}

/// What the browser hands over (`PushSubscription.toJSON()`), checked and kept as three strings.
export function parseWebSubscription(web) {
  if (!web || typeof web !== "object") return null;
  const endpoint = String(web.endpoint ?? "");
  const keys = web.keys && typeof web.keys === "object" ? web.keys : web;
  const p256dh = Buffer.from(String(keys.p256dh ?? ""), "base64url");
  const auth = Buffer.from(String(keys.auth ?? ""), "base64url");
  if (endpoint.length > 1024 || !pushServiceAllowed(endpoint)) return { error: "The push endpoint is not one of the browser push services." };
  if (p256dh.length !== 65 || p256dh[0] !== 4) return { error: "The subscription's p256dh key is not a P-256 point." };
  if (auth.length !== 16) return { error: "The subscription's auth secret must be 16 bytes." };
  return { endpoint, p256dh: p256dh.toString("base64url"), auth: auth.toString("base64url") };
}

const padScalar = (buffer) => (buffer.length >= 32 ? buffer : Buffer.concat([Buffer.alloc(32 - buffer.length), buffer]));

export function generateVapidKeys() {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  return { publicKey: ecdh.getPublicKey().toString("base64url"), privateKey: padScalar(ecdh.getPrivateKey()).toString("base64url") };
}

export function vapidFromEnv(env = process.env) {
  return {
    publicKey: env.VAPID_PUBLIC_KEY || null,
    privateKey: env.VAPID_PRIVATE_KEY || null,
    subject: env.VAPID_SUBJECT || "https://trydesk.trade",
  };
}

function signingKey(publicKey, privateKey) {
  const point = Buffer.from(publicKey, "base64url");
  return createPrivateKey({
    format: "jwk",
    key: { kty: "EC", crv: "P-256", x: point.subarray(1, 33).toString("base64url"), y: point.subarray(33, 65).toString("base64url"), d: privateKey },
  });
}

const b64json = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

/// The Authorization header for one push service: a JWT for its origin, signed ES256.
export function vapidHeader({ publicKey, privateKey, subject }, audience, now = Date.now()) {
  const data = `${b64json({ typ: "JWT", alg: "ES256" })}.${b64json({ aud: audience, exp: Math.floor(now / 1000) + TOKEN_LIFETIME_S, sub: subject })}`;
  const signature = sign("sha256", Buffer.from(data), { key: signingKey(publicKey, privateKey), dsaEncoding: "ieee-p1363" });
  return `vapid t=${data}.${signature.toString("base64url")}, k=${publicKey}`;
}

/// One aes128gcm record: salt, record size and the sender's public key up front, then the
/// ciphertext of the message plus the delimiter that marks it as the last record.
export function encrypt(subscription, plaintext, { salt = randomBytes(16), senderPrivateKey = null } = {}) {
  const text = Buffer.from(plaintext);
  if (text.length > MAX_PLAINTEXT) throw new Error(`push message over ${MAX_PLAINTEXT} bytes`);
  const receiver = Buffer.from(subscription.p256dh, "base64url");
  const auth = Buffer.from(subscription.auth, "base64url");
  const sender = createECDH("prime256v1");
  if (senderPrivateKey) sender.setPrivateKey(senderPrivateKey); else sender.generateKeys();
  const senderPublic = sender.getPublicKey();
  const shared = sender.computeSecret(receiver);
  const ikm = Buffer.from(hkdfSync("sha256", shared, auth, Buffer.concat([Buffer.from("WebPush: info\0"), receiver, senderPublic]), 32));
  const key = Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: aes128gcm\0"), 16));
  const nonce = Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: nonce\0"), 12));
  const cipher = createCipheriv("aes-128-gcm", key, nonce);
  const body = Buffer.concat([cipher.update(Buffer.concat([text, Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const header = Buffer.alloc(21);
  salt.copy(header, 0);
  header.writeUInt32BE(RECORD_SIZE, 16);
  header[20] = senderPublic.length;
  return Buffer.concat([header, senderPublic, body]);
}

const topicOf = (text) => String(text).replace(/[^A-Za-z0-9_-]/g, "").slice(0, 32);

/// Sends like the Apple client does: `{status, reason}`, with 200 for accepted and 410 for
/// a subscription the service says is gone, so the scan treats both kinds alike.
export function webPushClient({ publicKey = null, privateKey = null, subject = "https://trydesk.trade", fetchImpl = fetch, timeoutMs = 10_000 } = {}) {
  const configured = Boolean(publicKey && privateKey);
  return {
    configured,
    publicKey: configured ? publicKey : null,
    async send(subscription, message, { ttl = 3600, topic = null, urgency = "high" } = {}) {
      if (!configured) return { status: 0, reason: "NotConfigured" };
      let body;
      try { body = encrypt(subscription, JSON.stringify(message)); } catch (error) { return { status: 0, reason: `Encrypt: ${error.message}` }; }
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const headers = {
          "content-type": "application/octet-stream",
          "content-encoding": "aes128gcm",
          ttl: String(ttl),
          urgency,
          authorization: vapidHeader({ publicKey, privateKey, subject }, new URL(subscription.endpoint).origin),
        };
        if (topic) headers.topic = topicOf(topic);
        const response = await fetchImpl(subscription.endpoint, { method: "POST", headers, body, signal: controller.signal });
        if (response.status >= 200 && response.status < 300) return { status: 200 };
        if (response.status === 404 || response.status === 410) return { status: 410, reason: "Gone" };
        const detail = await response.text().catch(() => "");
        return { status: response.status, reason: detail.trim().slice(0, 120) || response.statusText || "Refused" };
      } catch (error) {
        return { status: 0, reason: error?.name === "AbortError" ? "Timeout" : "Unreachable" };
      } finally {
        clearTimeout(timer);
      }
    },
    close() {},
  };
}

const EVM = /^0x[0-9a-fA-F]{40}$/;
const personQuery = (address) => (EVM.test(address ?? "") ? `?person=${address}` : "");

/// Where a click on the notification lands in the web app.
export function landing(desk = {}) {
  switch (desk.type) {
    case "trade":
      return desk.market ? `/app/trade/${desk.market}${personQuery(desk.trader)}` : `/app${personQuery(desk.trader)}`;
    case "wallet":
      if (desk.token && desk.chainIndex) return `/app/token/${desk.chainIndex}/${desk.token}${personQuery(desk.wallet)}`;
      return EVM.test(desk.wallet ?? "") ? `/app/wallet/${desk.wallet}` : "/app";
    case "price":
      return desk.market ? `/app/trade/${desk.market}` : "/app";
    case "receipt":
      return "/app/portfolio";
    default:
      return "/app";
  }
}

/// An Apple payload as a browser notification. A silent wake has nothing to show, so it is
/// nothing; "Tap to copy" is the app's offer, not the browser's.
export function webPayload(payload, { collapseId = null } = {}) {
  const alert = payload?.aps?.alert;
  if (!alert) return null;
  const title = typeof alert === "string" ? "Desk" : String(alert.title ?? "Desk");
  const body = (typeof alert === "string" ? alert : String(alert.body ?? "")).replace(/\s*Tap to copy\.$/, "");
  return { title, body, url: landing(payload.desk ?? {}), ...(collapseId ? { tag: topicOf(collapseId) } : {}) };
}
