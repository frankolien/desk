import crypto from "node:crypto";

export const config = { maxDuration: 300 };

const TOKENS = {
  BTC: { chainIndex: "1", address: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" },
  ETH: { chainIndex: "1", address: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" },
  SOL: { chainIndex: "501", address: "So11111111111111111111111111111111111111112" },
  PUMP: { chainIndex: "501", address: "pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn" },
};

const PERIODS = new Set(["1s", "1m", "3m", "5m", "15m", "30m", "1H", "4H"]);

function loginFrame() {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const sign = crypto
    .createHmac("sha256", process.env.OKX_SECRET_KEY)
    .update(timestamp + "GET/users/self/verify")
    .digest("base64");
  return JSON.stringify({
    op: "login",
    args: [{
      apiKey: process.env.OKX_API_KEY,
      passphrase: process.env.OKX_PASSPHRASE,
      timestamp,
      sign,
    }],
  });
}

function write(res, event, value) {
  res.write(`event: ${event}\ndata: ${typeof value === "string" ? value : JSON.stringify(value)}\n\n`);
}

export default function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  if (!process.env.OKX_API_KEY || !process.env.OKX_SECRET_KEY || !process.env.OKX_PASSPHRASE) {
    return res.status(503).json({ error: "Market stream is not configured" });
  }

  const symbol = String(req.query.symbol || "").toUpperCase();
  const period = String(req.query.period || "1m");
  const token = TOKENS[symbol];
  if (!token || !PERIODS.has(period)) return res.status(400).json({ error: "Unsupported market" });

  res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();

  const socket = new WebSocket("wss://wsdex.okx.com/ws/v6/dex");
  let loggedIn = false;
  let subscriptions = 0;
  const candleChannel = `dex-token-candle${period}`;
  const subscribe = () => socket.send(JSON.stringify({
    op: "subscribe",
    args: [
      { channel: candleChannel, chainIndex: token.chainIndex, tokenContractAddress: token.address },
      { channel: "price-info", chainIndex: token.chainIndex, tokenContractAddress: token.address },
      { channel: "trades", chainIndex: token.chainIndex, tokenContractAddress: token.address },
    ],
  }));

  socket.onopen = () => socket.send(loginFrame());
  socket.onmessage = ({ data }) => {
    if (data === "pong") return;
    let frame;
    try { frame = JSON.parse(String(data)); } catch { return; }
    if (frame.event === "login" && frame.code === "0" && !loggedIn) {
      loggedIn = true;
      subscribe();
      write(res, "status", { state: "authenticating" });
      return;
    }
    if (frame.event === "subscribe") {
      subscriptions += 1;
      if (subscriptions === 3) write(res, "status", { state: "live" });
      return;
    }
    if (frame.event === "error") {
      write(res, "error", { message: frame.msg || "Upstream rejected the stream" });
      if (String(frame.msg || "").includes("active Market API subscription")) {
        setTimeout(() => socket.close(), 50);
      }
      return;
    }
    const channel = frame.arg?.channel || "message";
    for (const item of frame.data || []) write(res, channel, item);
  };
  socket.onerror = () => write(res, "error", { message: "Market stream disconnected" });
  socket.onclose = () => res.end();

  const ping = setInterval(() => {
    if (socket.readyState === WebSocket.OPEN) socket.send("ping");
  }, 25_000);
  const close = () => {
    clearInterval(ping);
    if (socket.readyState < WebSocket.CLOSING) socket.close();
  };
  req.on("close", close);
}
