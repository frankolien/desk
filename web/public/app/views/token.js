import { $, $$, esc, api, poll, fmtUsd, fmtSmall, fmtCompact, fmtPct, fmtAmount, short, ago, dirClass, logo, nativeLogo, person, hydratePeople, handoff } from "../app.js";

const STYLE = `<style>
.tk-back { margin-bottom: 12px; }
.tk-head { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; margin-bottom: 18px; }
.tk-id { display: flex; align-items: center; gap: 12px; min-width: 0; }
.tk-id .name { display: grid; gap: 2px; }
.tk-id .name b { font-size: 18px; font-weight: 800; letter-spacing: -0.02em; display: flex; align-items: center; gap: 8px; }
.tk-id .name b small { font-size: 13px; font-weight: 600; color: var(--muted); }
.tk-id .addr { display: inline-flex; align-items: center; gap: 6px; font-family: var(--mono); font-size: 12px; color: var(--muted); }
.tk-copy { display: inline-flex; color: var(--muted); border-radius: 6px; padding: 2px; }
.tk-copy:hover { color: var(--text); background: var(--chip); }
.tk-copy svg { width: 14px; height: 14px; }
.tk-stats { display: flex; align-items: center; gap: 22px; flex-wrap: wrap; margin-left: 12px; }
.tk-stat { display: grid; gap: 2px; }
.tk-stat span { font-size: 11px; color: var(--muted); font-weight: 600; }
.tk-stat b { font-family: var(--rounded); font-variant-numeric: tabular-nums; font-size: 15px; font-weight: 700; display: flex; align-items: baseline; gap: 6px; }
.tk-stat b small { font-size: 12px; font-weight: 700; }
.tk-star { margin-left: auto; width: 34px; height: 34px; display: inline-flex; align-items: center; justify-content: center; border-radius: 10px; color: var(--faint); border: 1px solid var(--line); }
.tk-star:hover { color: var(--text-2); background: var(--chip); }
.tk-star[aria-pressed="true"] { color: var(--amber); }
.tk-star svg { width: 18px; height: 18px; }
.tk-grid { display: grid; grid-template-columns: minmax(0, 1fr) 340px; gap: 20px; align-items: start; }
.tk-main, .tk-side { display: grid; grid-template-columns: minmax(0, 1fr); gap: 20px; min-width: 0; }
.tk-main > .card, .tk-side > .card { min-width: 0; }
.tk-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 10px 12px; border-bottom: 1px solid var(--line); }
.tk-chart { height: 420px; position: relative; }
.tk-chart .empty { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; }
.tk .table td { height: 40px; }
.tk-share { display: inline-flex; align-items: center; gap: 8px; justify-content: flex-end; }
.tk-share i { width: 60px; height: 4px; border-radius: 2px; background: var(--chip); overflow: hidden; display: block; }
.tk-share i b { display: block; height: 100%; background: var(--brand); }
.tk-amt { display: flex; align-items: center; justify-content: center; gap: 2px; margin: 18px 0 6px; }
.tk-amt span { font-family: var(--rounded); font-size: 30px; font-weight: 700; letter-spacing: -0.03em; color: var(--muted); line-height: 1; }
.tk-amt input { width: 1.4ch; max-width: 100%; min-width: 0; background: none; border: 0; outline: none; text-align: center; font-family: var(--rounded); font-size: 30px; font-weight: 700; letter-spacing: -0.03em; line-height: 1; padding: 0; -moz-appearance: textfield; }
.tk-amt input::-webkit-outer-spin-button, .tk-amt input::-webkit-inner-spin-button { -webkit-appearance: none; margin: 0; }
.tk-est { text-align: center; font-size: 12px; color: var(--muted); min-height: 17px; font-family: var(--rounded); font-variant-numeric: tabular-nums; }
.tk-chips { display: flex; gap: 6px; flex-wrap: wrap; }
.tk-chips .chip { flex: 1; justify-content: center; }
.tk-act { display: grid; gap: 10px; }
.tk-act .row-between { font-size: 12px; }
.tk-act .row-between b { font-family: var(--rounded); font-variant-numeric: tabular-nums; font-weight: 700; font-size: 12px; }
.tk-act .bar { margin-top: 5px; }
.tk-risk .line { display: flex; align-items: flex-start; gap: 8px; font-size: 13px; line-height: 1.35; }
.tk-risk .line i { flex: none; width: 6px; height: 6px; border-radius: 50%; margin-top: 6px; background: var(--faint); }
.tk-risk .line.high i { background: var(--fall); }
.tk-risk .line.caution i { background: var(--amber); }
.tk-risk .checked { font-size: 11px; color: var(--faint); margin-top: 4px; }
.tk-about .row-between { font-size: 13px; }
.tk-about .row-between > span:first-child { color: var(--muted); }
.tk-about .k { font-size: 12px; }
@media (max-width: 1100px) { .tk-grid { grid-template-columns: minmax(0, 1fr); } .tk-side { order: 2; } }
@media (max-width: 720px) { .tk-stats { margin-left: 0; gap: 14px; } .tk-chart { height: 320px; } }
</style>`;

const BARS = ["1m", "5m", "15m", "1H", "4H"];
const WINDOWS = [["5m", 5 * 60e3], ["15m", 15 * 60e3], ["1h", 3600e3], ["24h", 86400e3]];
const RISK_LABEL = { low: "Low risk", caution: "Caution", high: "High risk", unchecked: "Not checked" };
const WATCH_KEY = "desk.web.watch";

const num = (value) => { const n = Number(value); return value === "" || value == null || !Number.isFinite(n) ? null : n; };
const first = (...values) => values.find((v) => v != null) ?? null;
const skel = (w = "100%", h = 14) => `<div class="skel" style="width:${w};height:${h}px"></div>`;
const icon = (id) => `<svg aria-hidden="true"><use href="#${id}"/></svg>`;

function readWatch() { try { return JSON.parse(localStorage.getItem(WATCH_KEY) || "[]"); } catch { return []; } }
function writeWatch(list) { try { localStorage.setItem(WATCH_KEY, JSON.stringify(list)); } catch { /* private mode */ } }

function precisionFor(price) {
  if (price == null || price <= 0) return 2;
  if (price >= 1000) return 2;
  if (price >= 1) return 4;
  return Math.min(12, -Math.floor(Math.log10(price)) + 3);
}

/// Token prices keep their significant digits where fmtUsd would round them to cents.
const tokenPrice = (value) => (value == null || !Number.isFinite(Number(value)) ? "—" : Number(value) >= 1 ? fmtUsd(value) : `$${fmtSmall(Number(value)).replace(/(\.\d*?[1-9])0+$/, "$1")}`);

function copyButton(text) {
  return `<button class="tk-copy" type="button" data-copy="${esc(text)}" aria-label="Copy contract">${icon("i-copy")}</button>`;
}

export default async function mount(el, { chainIndex, address, query = {} }) {
  const key = `${chainIndex}:${address}`;
  const aborter = new AbortController();
  const signal = aborter.signal;
  let dead = false;
  let chart = null;
  let observer = null;
  let stopPoll = null;

  el.innerHTML = `${STYLE}<div class="tk">
    <div class="tk-back"><a class="btn btn-ghost btn-xs" href="/app/markets" data-link>← Markets</a></div>
    <header class="tk-head" id="tk-head">
      <div class="tk-id">${skel("44px", 44)}<div class="name">${skel("140px", 18)}${skel("100px", 12)}</div></div>
      <div class="tk-stats">${skel("90px", 30)}${skel("70px", 30)}${skel("70px", 30)}${skel("70px", 30)}</div>
    </header>
    <div class="tk-grid">
      <div class="tk-main">
        <div class="card">
          <div class="tk-toolbar">
            <div class="seg seg-sm" id="tk-bars">${BARS.map((b) => `<button type="button" data-bar="${b}" aria-selected="${b === "5m"}">${b}</button>`).join("")}</div>
            <div class="seg seg-sm seg-line" id="tk-scale"><button type="button" data-scale="price" aria-selected="true">Price</button><button type="button" data-scale="mc" aria-selected="false">MC</button></div>
          </div>
          <div class="tk-chart" id="tk-chart"></div>
        </div>
        <div class="card">
          <div class="tabs" style="padding:0 16px" id="tk-tabs"><button type="button" data-tab="trades" aria-selected="true">Trades</button><button type="button" data-tab="holders" aria-selected="false">Holders</button></div>
          <div class="table-wrap" id="tk-table">${[1, 2, 3, 4, 5].map(() => `<div class="skel-row"><div class="skel"></div><div class="skel"></div><div class="skel"></div><div class="skel"></div></div>`).join("")}</div>
        </div>
      </div>
      <aside class="tk-side">
        <div class="card card-pad" id="tk-ticket">
          <div class="seg" style="display:flex" id="tk-side-seg"><button type="button" data-side="buy" aria-selected="true" style="flex:1">Buy</button><button type="button" data-side="sell" aria-selected="false" style="flex:1">Sell</button></div>
          <div class="tk-amt"><span id="tk-prefix">$</span><input id="tk-amount" type="number" inputmode="decimal" min="0" step="any" placeholder="0" aria-label="Amount"></div>
          <div class="tk-est" id="tk-est"></div>
          <div class="sub" style="text-align:center;margin:4px 0 14px" id="tk-ticket-sub">Buy in USD</div>
          <div class="eyebrow" style="margin-bottom:8px">Quick actions</div>
          <div class="tk-chips" id="tk-chips"></div>
          <button class="btn btn-lg btn-block btn-rise" type="button" id="tk-go" style="margin-top:14px">Buy in Desk</button>
        </div>
        <div class="card" id="tk-activity">
          <div class="card-head"><h3>Market activity</h3><div class="seg seg-sm seg-line" id="tk-win">${WINDOWS.map(([w]) => `<button type="button" data-win="${w}" aria-selected="${w === "1h"}">${w}</button>`).join("")}</div></div>
          <div class="card-pad tk-act" id="tk-act">${skel()}${skel()}${skel()}</div>
        </div>
        <div class="card tk-risk" id="tk-risk">
          <div class="card-head"><h3>Risk</h3><span id="tk-risk-chip"></span></div>
          <div class="card-pad stack" style="gap:8px" id="tk-risk-body">${skel("80%")}${skel("60%")}${skel("40%", 11)}</div>
        </div>
        <div class="card tk-about" id="tk-about">
          <div class="card-head"><h3>About</h3></div>
          <div class="card-pad stack" id="tk-about-body">${skel()}${skel()}</div>
        </div>
      </aside>
    </div>
  </div>`;

  const q = (s) => $(s, el);

  // ── Identity and stats ────────────────────────────────

  const [discovery, details] = await Promise.all([
    api(`/api/token-discovery?q=${encodeURIComponent(address)}`, { ttl: 60_000, signal }).catch(() => null),
    api(`/api/token-details?chainIndex=${chainIndex}&address=${address}`, { ttl: 15_000, signal }).catch(() => null),
  ]);
  if (dead) return cleanup;

  const row = (discovery?.tokens ?? []).find((t) => String(t.chainIndex) === String(chainIndex) && String(t.contract ?? "").toLowerCase() === address.toLowerCase()) ?? null;
  const info = details?.priceInfo ?? null;
  if (!row && !info) {
    el.innerHTML = `${STYLE}<div class="tk"><div class="tk-back"><a class="btn btn-ghost btn-xs" href="/app/markets" data-link>← Markets</a></div><div class="empty">Nothing is known about this token yet.</div></div>`;
    return cleanup;
  }

  const symbol = row?.symbol || details?.symbol || short(address);
  const name = row?.name || symbol;
  const chainName = row?.chainName || `Chain ${chainIndex}`;
  const price = first(num(info?.price), num(row?.price));
  const change = first(num(info?.priceChange24H), num(row?.change));
  const marketCap = first(num(info?.marketCap), num(row?.marketCap));
  const liquidity = first(num(info?.liquidity), num(row?.liquidity));
  const volume = first(num(info?.volume24H), num(info?.volume), num(row?.volume24H));
  const holdersCount = first(num(info?.holders), num(row?.holders));
  const supply = first(num(info?.circSupply), marketCap != null && price > 0 ? marketCap / price : null);

  const stat = (label, value, extra = "") => `<div class="tk-stat"><span>${label}</span><b>${value}${extra}</b></div>`;
  q("#tk-head").innerHTML = `
    <div class="tk-id">${logo(row?.logoURL, symbol, 44)}
      <div class="name"><b>${esc(name)} <small>${esc(symbol)}</small></b><span class="addr">${esc(short(address))} ${copyButton(address)}</span></div>
    </div>
    <div class="tk-stats">
      ${stat("Price", tokenPrice(price), change == null ? "" : `<small class="${dirClass(change)}">${fmtPct(change / 100)}</small>`)}
      ${stat("Mcap", fmtUsd(marketCap, { compact: true }))}
      ${stat("Liquidity", fmtUsd(liquidity, { compact: true }))}
      ${stat("24h Volume", fmtUsd(volume, { compact: true }))}
      ${stat("Holders", holdersCount > 0 ? fmtCompact(holdersCount) : "—")}
    </div>
    <button class="tk-star" type="button" id="tk-star" aria-label="Watch" aria-pressed="${readWatch().includes(key)}">${icon("i-star")}</button>`;

  q("#tk-star").addEventListener("click", (event) => {
    const button = event.currentTarget;
    const on = button.getAttribute("aria-pressed") !== "true";
    const list = readWatch().filter((k) => k !== key);
    if (on) list.push(key);
    writeWatch(list);
    button.setAttribute("aria-pressed", String(on));
  });

  el.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-copy]");
    if (!button) return;
    try { await navigator.clipboard.writeText(button.dataset.copy); } catch { return; }
    const use = button.querySelector("use");
    use.setAttribute("href", "#i-check");
    setTimeout(() => use.setAttribute("href", "#i-copy"), 1200);
  });

  // ── About ─────────────────────────────────────────────

  q("#tk-about-body").innerHTML = `
    <div class="row-between"><span>Chain</span><span class="row" style="gap:6px">${logo(nativeLogo(chainIndex), chainName, 16)}${esc(chainName)}</span></div>
    <div class="row-between"><span>Contract</span><span class="row mono k" style="gap:6px">${esc(short(address))} ${copyButton(address)}</span></div>
    ${supply != null ? `<div class="row-between"><span>Supply</span><span class="num k">${fmtAmount(supply, 0)}</span></div>` : ""}
    ${row?.explorerURL && !/\/null$/.test(row.explorerURL) ? `<div class="row-between"><span>Explorer</span><a class="btn btn-ghost btn-xs" href="${esc(row.explorerURL)}" target="_blank" rel="noopener">Explorer ${icon("i-ext")}</a></div>` : ""}`;
  $$("#tk-about-body .btn svg", el).forEach((svg) => { svg.style.width = "12px"; svg.style.height = "12px"; });

  // ── Ticket ────────────────────────────────────────────

  let side = query.side === "sell" ? "sell" : "buy";
  let pct = null;
  $$("[data-side]", el).forEach((b) => b.setAttribute("aria-selected", String(b.dataset.side === side)));
  const amountInput = q("#tk-amount");
  const paintTicket = () => {
    const buying = side === "buy";
    q("#tk-prefix").textContent = buying ? "$" : "";
    q("#tk-prefix").hidden = !buying;
    q("#tk-ticket-sub").textContent = buying ? `Buy ${symbol} in USD` : `Sell ${symbol} for USD`;
    q("#tk-chips").innerHTML = buying
      ? [25, 50, 100, 250].map((v) => `<button class="chip" type="button" data-usd="${v}">$${v}</button>`).join("")
      : [25, 50, 75, 100].map((v) => `<button class="chip" type="button" data-pct="${v}" aria-pressed="${pct === v}">${v}%</button>`).join("");
    const go = q("#tk-go");
    go.className = `btn btn-lg btn-block ${buying ? "btn-rise" : "btn-fall"}`;
    go.textContent = `${buying ? "Buy" : "Sell"} ${symbol} in Desk`;
    paintEstimate();
  };
  const paintEstimate = () => {
    const amount = Number(amountInput.value);
    amountInput.style.width = `${Math.max(1, amountInput.value.length) + 0.4}ch`;
    const est = q("#tk-est");
    if (!(amount > 0) || !(price > 0)) { est.textContent = side === "sell" && pct ? `${pct}% of your ${symbol}` : ""; return; }
    est.textContent = side === "buy" ? `≈ ${fmtAmount(amount / price)} ${symbol} at ${tokenPrice(price)}` : `≈ ${fmtUsd(amount * price)} at ${tokenPrice(price)}`;
  };
  q("#tk-side-seg").addEventListener("click", (event) => {
    const button = event.target.closest("[data-side]");
    if (!button || button.dataset.side === side) return;
    side = button.dataset.side;
    $$("[data-side]", el).forEach((b) => b.setAttribute("aria-selected", String(b === button)));
    amountInput.value = "";
    pct = null;
    paintTicket();
  });
  q("#tk-chips").addEventListener("click", (event) => {
    const chip = event.target.closest(".chip");
    if (!chip) return;
    if (chip.dataset.usd) { amountInput.value = chip.dataset.usd; }
    else { pct = Number(chip.dataset.pct); amountInput.value = ""; $$("[data-pct]", el).forEach((c) => c.setAttribute("aria-pressed", String(Number(c.dataset.pct) === pct))); }
    paintEstimate();
  });
  amountInput.addEventListener("input", () => { if (side === "sell" && amountInput.value) { pct = null; $$("[data-pct]", el).forEach((c) => c.setAttribute("aria-pressed", "false")); } paintEstimate(); });
  q("#tk-go").addEventListener("click", () => {
    const amount = Number(amountInput.value);
    const what = side === "buy"
      ? (amount > 0 ? `${fmtUsd(amount)} of ${symbol}` : symbol)
      : (amount > 0 ? `${fmtAmount(amount)} ${symbol}` : pct ? `${pct}% of your ${symbol}` : symbol);
    handoff({ title: `${side === "buy" ? "Buy" : "Sell"} ${symbol} in Desk`, sub: `${side === "buy" ? "Buy" : "Sell"} ${what} on ${chainName}. Every order signs with Face ID in the app.` });
  });
  paintTicket();

  // ── Risk ──────────────────────────────────────────────

  api(`/api/token-details?view=risk&chainIndex=${chainIndex}&address=${address}&riskLevel=${encodeURIComponent(row?.riskLevel ?? "")}&communityRecognized=${row?.communityRecognized ?? ""}`, { ttl: 60_000, signal })
    .catch(() => null)
    .then((risk) => {
      if (dead) return;
      const level = RISK_LABEL[risk?.level] ? risk.level : "unchecked";
      q("#tk-risk-chip").innerHTML = `<span class="risk ${level}"><i></i>${RISK_LABEL[level]}</span>`;
      const reasons = risk?.reasons ?? [];
      const facts = risk?.facts ?? [];
      q("#tk-risk-body").innerHTML = (risk
        ? (reasons.length ? reasons.map((r) => `<div class="line ${esc(r.severity ?? "info")}"><i></i><span>${esc(r.text)}</span></div>`).join("") : `<div class="line"><i></i><span>Nothing stood out.</span></div>`)
          + facts.map((f) => `<div class="line muted"><i></i><span>${esc(f.text)}</span></div>`).join("")
        : `<div class="line muted"><i></i><span>No checks ran for this token.</span></div>`)
        + (risk ? `<div class="checked">Checked${risk.checkedAt ? ` ${ago(risk.checkedAt)}` : ""} · OKX, nad.fun, on-chain</div>` : "");
    });

  // ── Chart ─────────────────────────────────────────────

  let bar = "5m";
  let scale = query.scale === "mc" ? "mc" : "price";
  $$("[data-scale]", el).forEach((b) => b.setAttribute("aria-selected", String(b.dataset.scale === scale)));
  let candleSeries = null;
  let volumeSeries = null;
  let candles = [];
  let lastTime = 0;
  let generation = 0;
  const chartEl = q("#tk-chart");
  const factor = () => (scale === "mc" && supply != null ? supply : 1);
  const priceFormatter = (v) => (scale === "mc" ? `$${fmtCompact(v)}` : price < 0.01 ? `$${fmtSmall(v)}` : `$${v.toLocaleString("en-US", { minimumFractionDigits: precisionFor(price), maximumFractionDigits: precisionFor(price) })}`);
  const toPoint = (c) => ({ time: c.time, open: c.open * factor(), high: c.high * factor(), low: c.low * factor(), close: c.close * factor() });
  const toVolume = (c) => ({ time: c.time, value: c.volUsd, color: c.close >= c.open ? "rgba(47,214,123,0.35)" : "rgba(255,92,92,0.35)" });
  // Lightweight Charts labels the axis in UTC, so times are shifted to read as local.
  const tzShift = -new Date().getTimezoneOffset() * 60;
  const parseCandles = (rows) => (rows ?? []).map((c) => ({ time: Math.floor(Number(c[0]) / 1000) + tzShift, open: Number(c[1]), high: Number(c[2]), low: Number(c[3]), close: Number(c[4]), volUsd: Number(c[6] ?? c[5]) })).filter((c) => Number.isFinite(c.time) && Number.isFinite(c.close)).sort((a, b) => a.time - b.time).filter((c, i, all) => !i || c.time !== all[i - 1].time);

  const ensureChart = () => {
    if (chart || !window.LightweightCharts) return;
    const LW = window.LightweightCharts;
    chart = LW.createChart(chartEl, {
      width: chartEl.clientWidth, height: chartEl.clientHeight,
      layout: { background: { type: "solid", color: "transparent" }, textColor: "#8a8a92", fontFamily: getComputedStyle(document.body).fontFamily, fontSize: 11 },
      grid: { vertLines: { color: "rgba(255,255,255,0.05)" }, horzLines: { color: "rgba(255,255,255,0.05)" } },
      rightPriceScale: { borderVisible: false, scaleMargins: { top: 0.08, bottom: 0.22 } },
      timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false, rightOffset: 4 },
      crosshair: { mode: LW.CrosshairMode.Normal, vertLine: { color: "rgba(255,255,255,0.2)", labelBackgroundColor: "#222" }, horzLine: { color: "rgba(255,255,255,0.2)", labelBackgroundColor: "#222" } },
      localization: { priceFormatter },
      handleScale: { axisPressedMouseMove: true },
    });
    candleSeries = chart.addCandlestickSeries({ upColor: "#2fd67b", downColor: "#ff5c5c", borderVisible: false, wickUpColor: "#2fd67b", wickDownColor: "#ff5c5c", priceFormat: { type: "custom", minMove: 10 ** -precisionFor(price), formatter: priceFormatter } });
    volumeSeries = chart.addHistogramSeries({ priceScaleId: "", priceFormat: { type: "volume" }, lastValueVisible: false, priceLineVisible: false });
    volumeSeries.priceScale().applyOptions({ scaleMargins: { top: 0.8, bottom: 0 } });
    observer = new ResizeObserver(() => { if (chart) chart.applyOptions({ width: chartEl.clientWidth, height: chartEl.clientHeight }); });
    observer.observe(chartEl);
  };

  const paintChart = () => {
    ensureChart();
    if (!chart) return;
    const p = price * factor();
    candleSeries.applyOptions({ priceFormat: { type: "custom", minMove: 10 ** -precisionFor(p), formatter: priceFormatter } });
    chart.applyOptions({ localization: { priceFormatter } });
    candleSeries.setData(candles.map(toPoint));
    volumeSeries.setData(candles.map(toVolume));
    lastTime = candles.length ? candles[candles.length - 1].time : 0;
    chart.timeScale().fitContent();
    chartEl.querySelector(".empty")?.remove();
    if (!candles.length) chartEl.insertAdjacentHTML("beforeend", `<div class="empty">No candles yet.</div>`);
  };

  // ── Trades, holders, activity ─────────────────────────

  let tab = query.tab === "holders" ? "holders" : "trades";
  $$("[data-tab]", el).forEach((b) => b.setAttribute("aria-selected", String(b.dataset.tab === tab)));
  let trades = [];
  let seenTrades = new Set();
  let win = "1h";
  const holders = (details?.holders ?? []).map((h) => ({ address: h.holderWalletAddress, amount: num(h.holdAmount), pct: num(h.holdPercent) }));

  const tradeKey = (t) => t.id ?? `${t.time}:${t.userAddress}:${t.volume}`;
  const tokenAmount = (t) => {
    const hit = (t.changedTokenInfo ?? []).find((c) => String(c.tokenAddress ?? "").toLowerCase() === address.toLowerCase()) ?? (t.changedTokenInfo ?? []).find((c) => c.tokenSymbol === symbol);
    return num(hit?.amount);
  };

  const paintTable = ({ fresh = new Set() } = {}) => {
    const host = q("#tk-table");
    if (tab === "trades") {
      if (!trades.length) { host.innerHTML = `<div class="empty">No trades yet.</div>`; return; }
      host.innerHTML = `<table class="table table-compact"><thead><tr><th>Wallet</th><th class="left">Type</th><th>USD</th><th>Amount</th><th>Price</th><th class="left">Venue</th><th>Time</th></tr></thead><tbody>${trades.map((t) => `
        <tr class="${fresh.has(tradeKey(t)) ? "enter" : ""}">
          <td>${person(t.userAddress)}</td>
          <td class="left"><span class="side-chip ${t.type === "buy" ? "buy" : "sell"}">${t.type === "buy" ? "BUY" : "SELL"}</span></td>
          <td class="num">${fmtUsd(num(t.volume))}</td>
          <td class="num">${fmtAmount(tokenAmount(t))}</td>
          <td class="num">${tokenPrice(num(t.price))}</td>
          <td class="left muted">${esc(t.dexName ?? "")}</td>
          <td class="mono muted">${ago(Number(t.time), { suffix: false })}</td>
        </tr>`).join("")}</tbody></table>`;
    } else {
      if (!holders.length) { host.innerHTML = `<div class="empty">No holders listed.</div>`; return; }
      const top = Math.max(...holders.map((h) => h.pct ?? 0), 0) || 1;
      host.innerHTML = `<table class="table table-compact"><thead><tr><th class="rank">#</th><th class="left">Wallet</th><th>Amount</th><th>Share</th></tr></thead><tbody>${holders.map((h, i) => `
        <tr>
          <td class="rank">${i + 1}</td>
          <td class="left">${person(h.address)}</td>
          <td class="num">${fmtAmount(h.amount)}</td>
          <td><span class="tk-share num">${fmtPct(h.pct == null ? null : h.pct / 100, { sign: false })}<i><b style="width:${Math.min(100, Math.max(0, ((h.pct ?? 0) / top) * 100))}%"></b></i></span></td>
        </tr>`).join("")}</tbody></table>`;
    }
    hydratePeople(host);
  };

  const paintActivity = () => {
    const span = WINDOWS.find(([w]) => w === win)[1];
    const since = Date.now() - span;
    const inWindow = trades.filter((t) => Number(t.time) >= since);
    const sum = (list, side) => list.filter((t) => t.type === side).reduce((s, t) => s + (num(t.volume) ?? 0), 0);
    const uniq = (list, side) => new Set(list.filter((t) => t.type === side).map((t) => t.userAddress)).size;
    const count = (list, side) => list.filter((t) => t.type === side).length;
    const line = (label, buy, sell, fmt) => {
      const total = buy + sell;
      return `<div><div class="row-between"><span class="muted">${label}</span><span class="row" style="gap:10px"><b class="up">${fmt(buy)}</b><b class="down">${fmt(sell)}</b></span></div><div class="bar bar-thin" style="${total ? "" : "background:var(--chip)"}"><i style="width:${total ? (buy / total) * 100 : 0}%"></i></div></div>`;
    };
    q("#tk-act").innerHTML = (inWindow.length
      ? line("Volume", sum(inWindow, "buy"), sum(inWindow, "sell"), (v) => fmtUsd(v, { compact: true }))
        + line("Traders", uniq(inWindow, "buy"), uniq(inWindow, "sell"), String)
        + line("Txns", count(inWindow, "buy"), count(inWindow, "sell"), String)
      : `<div class="empty" style="padding:14px 0 6px">No trades in the last ${win}.</div>`)
      + `<div class="faint" style="font-size:11px">From the last ${trades.length || 60} trades</div>`;
  };

  q("#tk-tabs").addEventListener("click", (event) => {
    const button = event.target.closest("[data-tab]");
    if (!button || button.dataset.tab === tab) return;
    tab = button.dataset.tab;
    $$("[data-tab]", el).forEach((b) => b.setAttribute("aria-selected", String(b === button)));
    paintTable();
  });
  q("#tk-win").addEventListener("click", (event) => {
    const button = event.target.closest("[data-win]");
    if (!button) return;
    win = button.dataset.win;
    $$("[data-win]", el).forEach((b) => b.setAttribute("aria-selected", String(b === button)));
    paintActivity();
  });
  q("#tk-scale").addEventListener("click", (event) => {
    const button = event.target.closest("[data-scale]");
    if (!button || button.dataset.scale === scale) return;
    if (button.dataset.scale === "mc" && supply == null) return;
    scale = button.dataset.scale;
    $$("[data-scale]", el).forEach((b) => b.setAttribute("aria-selected", String(b === button)));
    paintChart();
  });
  if (supply == null) q('[data-scale="mc"]', el).disabled = true;
  q("#tk-bars").addEventListener("click", (event) => {
    const button = event.target.closest("[data-bar]");
    if (!button || button.dataset.bar === bar) return;
    bar = button.dataset.bar;
    $$("[data-bar]", el).forEach((b) => b.setAttribute("aria-selected", String(b === button)));
    candles = [];
    lastTime = 0;
    const mine = ++generation;
    chartEl.insertAdjacentHTML("beforeend", `<div class="empty pulse">Loading…</div>`);
    load(mine, true).catch(() => { if (mine === generation && !dead) { candles = []; paintChart(); } });
  });

  const hasTable = () => !!q("#tk-table table");
  const load = async (mine, full) => {
    const out = await api(`/api/market-snapshot?chainIndex=${chainIndex}&address=${address}&period=${bar}`, { signal });
    if (dead || mine !== generation) return;
    const next = parseCandles(out?.candles);
    if (full || !candles.length) {
      candles = next;
      paintChart();
    } else if (chart) {
      for (const c of next) if (c.time >= lastTime) { candleSeries.update(toPoint(c)); volumeSeries.update(toVolume(c)); lastTime = c.time; }
      const merged = new Map(candles.map((c) => [c.time, c]));
      for (const c of next) merged.set(c.time, c);
      candles = [...merged.values()].sort((a, b) => a.time - b.time);
    }
    const incoming = out?.trades ?? [];
    const fresh = new Set(seenTrades.size ? incoming.map(tradeKey).filter((k) => !seenTrades.has(k)) : []);
    trades = incoming;
    seenTrades = new Set(incoming.map(tradeKey));
    if (full || fresh.size || !hasTable()) paintTable({ fresh });
    else $$("td.mono", q("#tk-table")).forEach((td, i) => { if (trades[i]) td.textContent = ago(Number(trades[i].time), { suffix: false }); });
    paintActivity();
  };

  stopPoll = poll(() => load(generation, false), 15_000);

  function cleanup() {
    dead = true;
    aborter.abort();
    if (stopPoll) stopPoll();
    if (observer) observer.disconnect();
    if (chart) { chart.remove(); chart = null; }
  }
  return cleanup;
}
