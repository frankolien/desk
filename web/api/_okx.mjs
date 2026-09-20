import crypto from "node:crypto";

/// OKX's DEX API, signed. The key lives in Vercel's environment and nowhere else.

export function okxConfigured() {
  return Boolean(process.env.OKX_API_KEY && process.env.OKX_SECRET_KEY && process.env.OKX_PASSPHRASE);
}

function headers(timestamp, method, requestPath, body = "") {
  const sign = crypto.createHmac("sha256", process.env.OKX_SECRET_KEY)
    .update(timestamp + method + requestPath + body).digest("base64");
  return {
    "Content-Type": "application/json",
    "OK-ACCESS-KEY": process.env.OKX_API_KEY,
    "OK-ACCESS-SIGN": sign,
    "OK-ACCESS-PASSPHRASE": process.env.OKX_PASSPHRASE,
    "OK-ACCESS-TIMESTAMP": timestamp,
  };
}

export async function okxGet(path, params) {
  const requestPath = `${path}?${new URLSearchParams(params)}`;
  const timestamp = new Date().toISOString();
  const response = await fetch("https://web3.okx.com" + requestPath, {
    headers: headers(timestamp, "GET", requestPath),
  });
  const payload = await response.json();
  if (!response.ok || String(payload.code) !== "0") {
    throw new Error(payload.msg || `OKX HTTP ${response.status}`);
  }
  return payload.data;
}

export async function okxPost(path, value) {
  const body = JSON.stringify(value);
  const timestamp = new Date().toISOString();
  const response = await fetch("https://web3.okx.com" + path, {
    method: "POST",
    headers: headers(timestamp, "POST", path, body),
    body,
  });
  const payload = await response.json();
  if (!response.ok || String(payload.code) !== "0") {
    throw new Error(payload.msg || `OKX HTTP ${response.status}`);
  }
  return payload.data;
}
