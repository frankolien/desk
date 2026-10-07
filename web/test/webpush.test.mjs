import assert from "node:assert/strict";
import { createDecipheriv, createECDH, createPublicKey, hkdfSync, randomBytes, verify } from "node:crypto";
import { test } from "node:test";

import {
  encrypt, generateVapidKeys, landing, parseWebSubscription, pushServiceAllowed, vapidHeader, webPayload, webPushClient,
} from "../api/_webpush.mjs";

function browser(endpoint = "https://fcm.googleapis.com/fcm/send/abc-123") {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  const auth = randomBytes(16);
  return { ecdh, auth, subscription: { endpoint, p256dh: ecdh.getPublicKey().toString("base64url"), auth: auth.toString("base64url") } };
}

/// RFC 8291 from the receiving side, as a browser's push service hands it to the page.
function decrypt({ ecdh, auth }, body) {
  const salt = body.subarray(0, 16);
  const recordSize = body.readUInt32BE(16);
  const idLength = body[20];
  const senderPublic = body.subarray(21, 21 + idLength);
  const cipherText = body.subarray(21 + idLength);
  const shared = ecdh.computeSecret(senderPublic);
  const ikm = Buffer.from(hkdfSync("sha256", shared, auth, Buffer.concat([Buffer.from("WebPush: info\0"), ecdh.getPublicKey(), senderPublic]), 32));
  const key = Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: aes128gcm\0"), 16));
  const nonce = Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: nonce\0"), 12));
  const decipher = createDecipheriv("aes-128-gcm", key, nonce);
  decipher.setAuthTag(cipherText.subarray(-16));
  const padded = Buffer.concat([decipher.update(cipherText.subarray(0, -16)), decipher.final()]);
  assert.equal(padded.at(-1), 2, "the single record ends with the last-record delimiter");
  return { recordSize, text: padded.subarray(0, -1).toString() };
}

test("a message is encrypted so that only the subscribed browser can read it", () => {
  const me = browser();
  const body = encrypt(me.subscription, JSON.stringify({ title: "Whale opened a long" }));
  const opened = decrypt(me, body);
  assert.equal(opened.recordSize, 4096);
  assert.deepEqual(JSON.parse(opened.text), { title: "Whale opened a long" });
  assert.equal(body[20], 65);
  assert.throws(() => decrypt(browser(), body), /auth|Unsupported state/i);
  assert.throws(() => encrypt(me.subscription, "x".repeat(5000)), /over/);
});

test("the request is signed for the push service with a token it can check against the public key", () => {
  const keys = generateVapidKeys();
  assert.equal(Buffer.from(keys.publicKey, "base64url").length, 65);
  assert.equal(Buffer.from(keys.privateKey, "base64url").length, 32);
  const now = 1_791_359_643_440;
  const header = vapidHeader({ ...keys, subject: "https://trydesk.trade" }, "https://fcm.googleapis.com", now);
  const [, token, key] = header.match(/^vapid t=([^,]+), k=(.+)$/);
  assert.equal(key, keys.publicKey);
  const [head, claims, signature] = token.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(head, "base64url")), { typ: "JWT", alg: "ES256" });
  assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url")), { aud: "https://fcm.googleapis.com", exp: Math.floor(now / 1000) + 12 * 3600, sub: "https://trydesk.trade" });
  const point = Buffer.from(keys.publicKey, "base64url");
  const publicKey = createPublicKey({ format: "jwk", key: { kty: "EC", crv: "P-256", x: point.subarray(1, 33).toString("base64url"), y: point.subarray(33).toString("base64url") } });
  assert.equal(verify("sha256", Buffer.from(`${head}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")), true);
});

test("send posts the encrypted message with the push headers and reads the service's answer like Apple's", async () => {
  const keys = generateVapidKeys();
  const me = browser();
  const calls = [];
  let answer = { status: 201, text: "" };
  const fetchImpl = async (url, init) => { calls.push({ url, init }); return { status: answer.status, statusText: "", text: async () => answer.text }; };
  const client = webPushClient({ ...keys, fetchImpl });
  assert.equal(client.configured, true);
  assert.equal(client.publicKey, keys.publicKey);

  const sent = await client.send(me.subscription, { title: "Whale flipped short on ETH", body: "Now 5× short.", url: "/app/trade/ETH" }, { topic: "95d2602d30da-20-flipped" });
  assert.deepEqual(sent, { status: 200 });
  assert.equal(calls[0].url, me.subscription.endpoint);
  const { headers, body, method } = calls[0].init;
  assert.equal(method, "POST");
  assert.equal(headers["content-encoding"], "aes128gcm");
  assert.equal(headers["content-type"], "application/octet-stream");
  assert.equal(headers.ttl, "3600");
  assert.equal(headers.urgency, "high");
  assert.equal(headers.topic, "95d2602d30da-20-flipped");
  assert.match(headers.authorization, /^vapid t=.+, k=.+$/);
  assert.deepEqual(JSON.parse(decrypt(me, body).text), { title: "Whale flipped short on ETH", body: "Now 5× short.", url: "/app/trade/ETH" });

  answer = { status: 410, text: "" };
  assert.deepEqual(await client.send(me.subscription, { title: "x" }), { status: 410, reason: "Gone" });
  answer = { status: 404, text: "" };
  assert.deepEqual(await client.send(me.subscription, { title: "x" }), { status: 410, reason: "Gone" });
  answer = { status: 429, text: "slow down" };
  assert.deepEqual(await client.send(me.subscription, { title: "x" }), { status: 429, reason: "slow down" });
  assert.deepEqual(await webPushClient({ fetchImpl }).send(me.subscription, { title: "x" }), { status: 0, reason: "NotConfigured" });
  const down = webPushClient({ ...keys, fetchImpl: async () => { throw new TypeError("fetch failed"); } });
  assert.deepEqual(await down.send(me.subscription, { title: "x" }), { status: 0, reason: "Unreachable" });
});

test("a subscription must point at a browser push service and carry well-formed keys", () => {
  assert.equal(pushServiceAllowed("https://fcm.googleapis.com/fcm/send/abc"), true);
  assert.equal(pushServiceAllowed("https://web.push.apple.com/QGxyz"), true);
  assert.equal(pushServiceAllowed("https://updates.push.services.mozilla.com/wpush/v2/abc"), true);
  assert.equal(pushServiceAllowed("https://wns2-par02p.notify.windows.com/w/?token=abc"), true);
  assert.equal(pushServiceAllowed("https://evil.example.com/fcm.googleapis.com"), false);
  assert.equal(pushServiceAllowed("http://fcm.googleapis.com/fcm/send/abc"), false);
  assert.equal(pushServiceAllowed("not a url"), false);

  const me = browser();
  const nested = parseWebSubscription({ endpoint: me.subscription.endpoint, keys: { p256dh: me.subscription.p256dh, auth: me.subscription.auth } });
  assert.deepEqual(nested, me.subscription);
  assert.deepEqual(parseWebSubscription(me.subscription), me.subscription);
  assert.equal(parseWebSubscription(null), null);
  assert.match(parseWebSubscription({ ...me.subscription, endpoint: "https://example.com/push" }).error, /push services/);
  assert.match(parseWebSubscription({ ...me.subscription, p256dh: "AAAA" }).error, /P-256/);
  assert.match(parseWebSubscription({ ...me.subscription, auth: "AAAA" }).error, /16 bytes/);
});

test("an alert becomes a notification with a place to land, and a silent wake becomes nothing", () => {
  const trade = { aps: { alert: { title: "Whale opened a long", body: "ETH 5× at $1,847.99, $23K position. Tap to copy." } }, desk: { type: "trade", trader: "0x95d2602d30da1179fd13274839e60345857ca648", market: "ETH" } };
  assert.deepEqual(webPayload(trade, { collapseId: "95d2602d30da-20-opened" }), {
    title: "Whale opened a long", body: "ETH 5× at $1,847.99, $23K position.", url: "/app/trade/ETH?person=0x95d2602d30da1179fd13274839e60345857ca648", tag: "95d2602d30da-20-opened",
  });
  assert.equal(webPayload({ aps: { "content-available": 1 }, desk: { type: "wake" } }), null);
  assert.equal(webPayload({ aps: { alert: "Desk is back" } }).title, "Desk");
  assert.equal(landing({ type: "trade", trader: "0x95d2602d30da1179fd13274839e60345857ca648" }), "/app?person=0x95d2602d30da1179fd13274839e60345857ca648");
  assert.equal(landing({ type: "wallet", chainIndex: "143", token: "0xabc", wallet: "0x95d2602d30da1179fd13274839e60345857ca648" }), "/app/token/143/0xabc?person=0x95d2602d30da1179fd13274839e60345857ca648");
  assert.equal(landing({ type: "wallet", wallet: "0x95d2602d30da1179fd13274839e60345857ca648" }), "/app/wallet/0x95d2602d30da1179fd13274839e60345857ca648");
  assert.equal(landing({ type: "price", market: "BTC" }), "/app/trade/BTC");
  assert.equal(landing({ type: "receipt" }), "/app/portfolio");
  assert.equal(landing({ type: "confirmation" }), "/app");
});
