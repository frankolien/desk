/// Currencies Desk can show balances in. AUSD is a dollar stablecoin, so every rate is
/// dollars to that currency; trading itself stays in AUSD.
export const CURRENCIES = [
  "USD", "EUR", "GBP", "NGN", "GHS", "KES", "ZAR", "INR", "JPY", "CNY",
  "KRW", "CAD", "AUD", "BRL", "MXN", "AED", "TRY", "CHF", "SGD",
];

const SOURCE = "https://open.er-api.com/v6/latest/USD";

export function pickRates(body) {
  if (body?.result !== "success" || typeof body.rates !== "object") return null;
  const rates = {};
  for (const code of CURRENCIES) {
    const rate = Number(body.rates[code]);
    if (!Number.isFinite(rate) || rate <= 0) return null;
    rates[code] = rate;
  }
  return rates.USD === 1 ? rates : null;
}

export function createHandler(fetchImpl = fetch) {
  return async function handler(req, res) {
    if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
    try {
      const response = await fetchImpl(SOURCE);
      const body = await response.json();
      const rates = pickRates(body);
      if (!response.ok || !rates) throw new Error("rates");
      res.setHeader("Cache-Control", "public, s-maxage=3600, stale-while-revalidate=86400");
      return res.status(200).json({
        base: "USD",
        updatedAt: Number(body.time_last_update_unix) * 1000 || Date.now(),
        rates,
      });
    } catch {
      return res.status(502).json({ error: "Exchange rates are unavailable right now." });
    }
  };
}

export default createHandler();
