import { sign } from "node:crypto";
import { connect } from "node:http2";

const HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

const base64url = (value) => Buffer.from(value).toString("base64url");

/// Apple refuses a token refreshed more than every 20 minutes or older than an hour; reused for 40.
export function providerToken({ keyId, teamId, privateKey }, now = Date.now()) {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), { key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${header}.${claims}.${signature.toString("base64url")}`;
}

export function readPrivateKey(value) {
  if (!value) return null;
  const text = value.includes("BEGIN") ? value : Buffer.from(value, "base64").toString("utf8");
  return text.replace(/\\n/g, "\n");
}

export function apnsClient({
  keyId = process.env.APNS_KEY_ID,
  teamId = process.env.APNS_TEAM_ID,
  privateKey = readPrivateKey(process.env.APNS_PRIVATE_KEY),
  topic = process.env.APNS_TOPIC || "com.opia.desk",
} = {}) {
  if (!keyId || !teamId || !privateKey) return null;
  let cached = { token: null, at: 0 };
  const sessions = new Map();

  function bearer() {
    if (!cached.token || Date.now() - cached.at > 40 * 60_000) {
      cached = { token: providerToken({ keyId, teamId, privateKey }), at: Date.now() };
    }
    return cached.token;
  }

  function session(environment) {
    const existing = sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const created = connect(HOSTS[environment]);
    created.on("error", () => sessions.delete(environment));
    sessions.set(environment, created);
    return created;
  }

  function post(environment, deviceToken, payload, { collapseId, background = false } = {}) {
    return new Promise((resolve) => {
      // Apple requires a background push to declare itself with priority 5; a 10 is rejected outright.
      const headers = {
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        authorization: `bearer ${bearer()}`,
        "apns-topic": topic,
        "apns-push-type": background ? "background" : "alert",
        "apns-priority": background ? "5" : "10",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + (background ? 600 : 3600)),
      };
      if (collapseId) headers["apns-collapse-id"] = collapseId.slice(0, 64);
      let request;
      try {
        request = session(environment).request(headers);
      } catch {
        return resolve({ status: 0, reason: "Unreachable" });
      }
      let body = "";
      let status = 0;
      request.setTimeout(10_000, () => request.close());
      request.on("response", (response) => { status = Number(response[":status"]); });
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        let reason = null;
        try { reason = body ? JSON.parse(body).reason : null; } catch { reason = null; }
        resolve({ status, reason });
      });
      request.on("error", () => resolve({ status: 0, reason: "Unreachable" }));
      request.on("close", () => resolve({ status, reason: status ? null : "Timeout" }));
      request.end(JSON.stringify(payload));
    });
  }

  return {
    /// A token refused as the wrong environment (sandbox vs production) is retried once against the other.
    async send({ token, environment }, payload, options) {
      const first = environment === "production" ? "production" : "sandbox";
      let result = await post(first, token, payload, options);
      // No answer at all is a dropped connection, not a refusal: one more try on a fresh one.
      if (result.status === 0) {
        sessions.get(first)?.destroy();
        sessions.delete(first);
        result = await post(first, token, payload, options);
      }
      if (result.reason !== "BadDeviceToken") return { ...result, environment: first };
      const other = first === "production" ? "sandbox" : "production";
      const retried = await post(other, token, payload, options);
      return { ...retried, environment: retried.status === 200 ? other : first };
    },
    close() {
      sessions.forEach((entry) => entry.close());
      sessions.clear();
    },
  };
}

export const isDeadToken = ({ status, reason }) =>
  status === 410 || (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
