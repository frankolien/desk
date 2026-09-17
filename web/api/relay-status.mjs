const RELAY = "https://api.relay.link";

/// Relay's own words, folded to the four states a buyer needs to see.
export function phase(status) {
  switch (status) {
    case "success": return "filled";
    case "refund": case "refunded": return "refunded";
    case "failure": return "failed";
    default: return "pending";
  }
}

export function createHandler(fetchImpl = fetch) {
  return async function handler(req, res) {
    res.setHeader("Cache-Control", "private, no-store");
    if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
    const requestId = String(req.query.requestId || "");
    if (!/^0x[a-fA-F0-9]{64}$/.test(requestId)) {
      return res.status(400).json({ error: "A request id is required." });
    }
    try {
      const response = await fetchImpl(`${RELAY}/intents/status/v3?requestId=${requestId}`, {
        headers: process.env.RELAY_API_KEY ? { "x-api-key": process.env.RELAY_API_KEY } : {},
      });
      if (!response.ok) return res.status(502).json({ error: "Relay status is unavailable." });
      const body = await response.json();
      return res.status(200).json({
        phase: phase(body.status),
        destinationTx: Array.isArray(body.txHashes) ? body.txHashes.at(-1) ?? null : null,
      });
    } catch {
      return res.status(502).json({ error: "Relay status is unavailable." });
    }
  };
}

export default createHandler();
