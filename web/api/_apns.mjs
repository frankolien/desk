import { sign } from "node:crypto";
import { connect } from "node:http2";

const HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

const base64url = (value) => Buffer.from(value).toString("base64url");

/// Apple's provider token: ES256 over the team and key id. Apple refuses a token refreshed
/// more than once every twenty minutes and one older than an hour, so it is reused for forty.
export function providerToken({ keyId, teamId, privateKey }, now = Date.now()) {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), { key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${header}.${claims}.${signature.toString("base64url")}`;
}

/// A .p8 pasted into an environment variable arrives with its newlines escaped, or as
/// base64 when a dashboard would not take newlines at all.
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
      // A background push wakes the app without showing anything. Apple requires the
      // type to say so and the priority to be 5; a 10 is rejected outright.
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
      // A stream closed by the timeout ends without "end"; it must still answer.
      request.on("close", () => resolve({ status, reason: status ? null : "Timeout" }));
      request.end(JSON.stringify(payload));
    });
  }

  return {
    /// A debug build's token only works against the sandbox and a TestFlight build's only
    /// against production. The app says which it is, and a token refused as the wrong kind
    /// is tried once against the other, so a guess never silently drops an alert.
    async send({ token, environment }, payload, options) {
      const first = environment === "production" ? "production" : "sandbox";
      const result = await post(first, token, payload, options);
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

/// Apple has said this token will never deliver again.
export const isDeadToken = ({ status, reason }) =>
  status === 410 || (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
