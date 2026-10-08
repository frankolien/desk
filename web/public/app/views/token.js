import { $, $$, esc, api, poll, fmtUsd, fmtSmall, fmtCompact, fmtPct, fmtAmount, short, ago, dirClass, logo, nativeLogo, person, hydratePeople, handoff, identity, knownIdentity, navigate, connectedWallet, chartOptions, candleOptions, volumeColor, chartLegend, chartCountdown } from "../app.js";
import { isUnlocked, onSession, session } from "../session.js";
import { allowance, call as chainCall, explorerTx, monBalance, sendCall, tokenBalance, tokenDecimals, waitForReceipt } from "../chain.js";

const STYLE = `<style>
.tk-tx { display: inline-flex; color: var(--muted); } .tk-tx:hover { color: var(--text); } .tk-tx svg { width: 13px; height: 13px; }
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
.tk-toolbar .row { gap: 8px; }
.tk-toolbar .chip { height: 26px; padding: 0 10px; }
.tk-chart { height: clamp(460px, 56vh, 760px); position: relative; }
body.focus { overflow: hidden; }
body.focus .tk { position: fixed; inset: 0; z-index: 40; display: flex; flex-direction: column; background: var(--bg); }
body.focus .tk-back, body.focus .tk-side, body.focus .tk-main > .card:nth-child(2) { display: none; }
body.focus .tk-head { margin: 0; padding: 8px 16px; border-bottom: 1px solid var(--line); }
body.focus .tk-grid { flex: 1; display: flex; align-items: stretch; min-height: 0; gap: 0; }
body.focus .tk-main { flex: 1; display: flex; flex-direction: column; min-height: 0; gap: 0; }
body.focus .tk-main > .card:first-child { flex: 1; display: flex; flex-direction: column; min-height: 0; border: 0; border-radius: 0; }
body.focus .tk-chart { flex: 1; height: auto; min-height: 0; }
body.focus #tk-focus { background: var(--chip-hover); }
.tk-chart .empty { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; }
.tk-faces { position: absolute; inset: 0; z-index: 5; pointer-events: none; overflow: hidden; }
.tk-face { position: absolute; display: inline-flex; width: 20px; height: 20px; margin: -10px 0 0 -10px; border-radius: 50%; pointer-events: auto; box-shadow: 0 0 0 2px var(--rise), 0 0 0 3px #000; transition: transform 0.12s var(--ease); }
.tk-face.sell { box-shadow: 0 0 0 2px var(--fall), 0 0 0 3px #000; }
.tk-face .logo { width: 20px; height: 20px; font-size: 8px; color: #fff; }
.tk-face:hover { transform: scale(1.3); z-index: 1; }
.tk-more { position: absolute; margin: -7px 0 0 -10px; height: 14px; padding: 0 5px; border-radius: 7px; background: var(--chip); color: var(--text-2); font-family: var(--rounded); font-size: 9px; font-weight: 800; line-height: 14px; box-shadow: 0 0 0 1px #000; }
.tk-tip { position: absolute; z-index: 6; pointer-events: none; padding: 8px 10px; background: #141414; border-color: var(--line-strong); box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5); font-size: 12px; line-height: 1.4; white-space: nowrap; }
.tk-tip small { display: block; font-size: 11px; color: var(--muted); }
.tk .tabs { overflow-x: auto; scrollbar-width: none; }
.tk .tabs::-webkit-scrollbar { display: none; }
.tk .tabs button { white-space: nowrap; }
.tk-n { margin-left: 5px; font-family: var(--rounded); font-style: normal; font-size: 11px; font-weight: 700; color: var(--faint); font-variant-numeric: tabular-nums; }
.tk-n:empty { display: none; }
.tk-tabhead { display: flex; align-items: center; gap: 12px; padding: 10px 16px; font-size: 12px; color: var(--muted); border-bottom: 1px solid var(--line); }
.tk-line { padding: 24px 16px; text-align: center; color: var(--muted); font-size: 13px; }
.tk-foot { padding: 10px 16px; border-top: 1px solid var(--line); font-size: 11px; color: var(--muted); }
.tk .table .chip { height: 22px; padding: 0 8px; font-size: 11px; }
.tk-stack { display: inline-flex; align-items: center; vertical-align: middle; }
.tk-stack .logo { box-shadow: 0 0 0 2px var(--card); font-size: 8px; color: #fff; }
.tk-stack .logo + .logo { margin-left: -6px; }
.tk-stack .more { margin-left: 6px; font-size: 11px; font-weight: 600; color: var(--muted); }
.tk .table td { height: 40px; }
.tk-share { display: inline-flex; align-items: center; gap: 8px; justify-content: flex-end; }
.tk-share i { width: 60px; height: 4px; border-radius: 2px; background: var(--chip); overflow: hidden; display: block; }
.tk-share i b { display: block; height: 100%; background: var(--brand); }
.tk-amt { display: flex; align-items: center; justify-content: center; gap: 2px; margin: 18px 0 6px; }
.tk-amt span { font-family: var(--rounded); font-size: 30px; font-weight: 700; letter-spacing: -0.03em; color: var(--muted); line-height: 1; }
.tk-amt input { width: 1.4ch; max-width: 100%; min-width: 0; background: none; border: 0; outline: none; text-align: center; font-family: var(--rounded); font-size: 30px; font-weight: 700; letter-spacing: -0.03em; line-height: 1; padding: 0; -moz-appearance: textfield; }
.tk-amt input::-webkit-outer-spin-button, .tk-amt input::-webkit-inner-spin-button { -webkit-appearance: none; margin: 0; }
.tk-est { text-align: center; font-size: 12px; color: var(--muted); min-height: 17px; font-family: var(--rounded); font-variant-numeric: tabular-nums; }
.tk-note { font-size: 12px; color: var(--amber); text-align: center; margin-top: 10px; line-height: 1.4; }
.tk-note.fall { color: var(--fall); }
.tk-note:empty { display: none; }
.tk-steps { display: grid; gap: 10px; padding: 4px 0 2px; }
.tk-steps .step { display: flex; align-items: center; gap: 10px; font-size: 13px; }
.tk-steps .step i { flex: none; width: 18px; height: 18px; border-radius: 50%; border: 1.5px solid var(--line-strong); display: inline-flex; align-items: center; justify-content: center; font-size: 11px; font-style: normal; font-weight: 800; }
.tk-steps .step.running i { border-color: var(--text); border-top-color: transparent; animation: tk-spin 0.8s linear infinite; }
.tk-steps .step.done i { border-color: var(--rise); background: var(--rise-soft); color: var(--rise); }
.tk-steps .step.stopped i { border-color: var(--fall); background: var(--fall-soft); color: var(--fall); }
.tk-steps .step.waiting { color: var(--muted); }
.tk-steps .step a { margin-left: auto; font-size: 12px; color: var(--muted); text-decoration: underline; }
.tk-outcome { text-align: center; padding: 8px 0 2px; }
.tk-outcome b { display: block; font-size: 18px; font-weight: 800; letter-spacing: -0.02em; }
.tk-outcome span { display: block; font-size: 12px; color: var(--muted); margin-top: 4px; line-height: 1.4; }
@keyframes tk-spin { to { transform: rotate(360deg); } }
.tk-chips { display: flex; gap: 6px; flex-wrap: wrap; }
.tk-chips .chip { flex: 1; justify-content: center; }
.tk-act { display: grid; gap: 10px; }
.tk-act .row-between { font-size: 12px; }
.tk-act .row-between b { font-family: var(--rounded); font-variant-numeric: tabular-nums; font-weight: 700; font-size: 12px; }
.tk-act .bar { margin-top: 5px; }
.tk-score { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.tk-score .n { font-family: var(--rounded); font-variant-numeric: tabular-nums; font-size: 34px; font-weight: 800; line-height: 1; letter-spacing: -0.02em; }
.tk-score .n small { font-size: 14px; color: var(--muted); font-weight: 600; margin-left: 3px; letter-spacing: 0; }
.tk-score.low .n { color: var(--rise); }
.tk-score.caution .n { color: var(--amber); }
.tk-score.high .n { color: var(--fall); }
.tk-ticks { display: grid; grid-template-columns: repeat(10, 14px); gap: 3px; }
.tk-ticks i { height: 6px; border-radius: 2px; background: var(--chip); }
.tk-score.low .tk-ticks i.on { background: var(--rise); }
.tk-score.caution .tk-ticks i.on { background: var(--amber); }
.tk-score.high .tk-ticks i.on { background: var(--fall); }
.tk-badges { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 12px; }
.tk-badge { display: inline-flex; align-items: center; gap: 5px; height: 22px; padding: 0 8px 0 5px; border-radius: 999px; font-size: 11px; font-weight: 600; background: var(--chip); color: var(--text); }
.tk-badge i { width: 13px; height: 13px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-size: 9px; font-style: normal; font-weight: 800; line-height: 1; }
.tk-badge.ok i { background: var(--rise-soft); color: var(--rise); }
.tk-badge.warn i { background: rgba(232, 179, 57, 0.16); color: var(--amber); }
.tk-riskgrid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 6px; margin-top: 12px; }
.tk-riskgrid div { background: var(--chip); border-radius: 10px; padding: 8px 10px; min-width: 0; }
.tk-riskgrid span { display: block; font-size: 11px; color: var(--muted); white-space: nowrap; }
.tk-riskgrid b { display: block; font-family: var(--rounded); font-variant-numeric: tabular-nums; font-size: 14px; font-weight: 700; margin-top: 2px; }
.tk-riskgrid b.amber { color: var(--amber); }
.tk-riskgrid b.fall { color: var(--fall); }
.tk-riskgrid b.pulse { color: var(--faint); }
.tk-risklines { display: grid; gap: 6px; margin-top: 12px; }
.tk-risk .line { display: flex; align-items: flex-start; gap: 8px; font-size: 12px; line-height: 1.35; color: var(--muted); }
.tk-risk .line i { flex: none; width: 6px; height: 6px; border-radius: 50%; margin-top: 6px; background: var(--faint); }
.tk-risk .line.high i { background: var(--fall); }
.tk-risk .line.caution i { background: var(--amber); }
.tk-risk .checked { font-size: 11px; color: var(--faint); margin-top: 4px; }
.tk-about .row-between { font-size: 13px; }
.tk-about .row-between > span:first-child { color: var(--muted); }
.tk-about .k { font-size: 12px; }
@media (max-width: 1100px) { .tk-grid { grid-template-columns: minmax(0, 1fr); } .tk-side { order: 2; } }
@media (max-width: 720px) { .tk-stats { margin-left: 0; gap: 14px; } .tk-chart { height: clamp(340px, 50vh, 560px); } }
</style>`;

const BARS = ["1m", "5m", "15m", "1H", "4H", "1D"];
const BAR_SECONDS = { "1m": 60, "5m": 300, "15m": 900, "1H": 3600, "4H": 14400, "1D": 86400 };
const WINDOWS = [["5m", 5 * 60e3], ["15m", 15 * 60e3], ["1h", 3600e3], ["24h", 86400e3]];
const TABS = [["trades", "Trades"], ["holders", "Holders"], ["traders", "Traders"], ["bundlers", "Bundlers"], ["snipers", "Snipers"], ["insiders", "Insiders"]];
const EARLY_TABS = ["bundlers", "snipers", "insiders"];
const EARLY_LABEL = { bundlers: ["Bundles", "bundles"], snipers: ["Snipers", "snipers"], insiders: ["Insiders", "insiders"] };
const EARLY_RETRIES = 5;
const CHAIN_NAMES = { 1: "Ethereum", 10: "Optimism", 56: "BNB Chain", 137: "Polygon", 143: "Monad", 501: "Solana", 8453: "Base", 42161: "Arbitrum" };
const RISK_LABEL = { low: "Low risk", caution: "Caution", high: "High risk", unchecked: "Not checked" };
const WATCH_KEY = "desk.web.watch";
const FACES_KEY = "desk.web.chartfaces";
const FACES_MAX = 12;
const STACK_MAX = 2;

const num = (value) => { const n = Number(value); return value === "" || value == null || !Number.isFinite(n) ? null : n; };
const first = (...values) => values.find((v) => v != null) ?? null;
const ms = (value) => { const n = num(value); return n == null ? null : n < 1e12 ? n * 1000 : n; };
const hue = (text) => [...String(text)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);
const skel = (w = "100%", h = 14) => `<div class="skel" style="width:${w};height:${h}px"></div>`;
const icon = (id) => `<svg aria-hidden="true"><use href="#${id}"/></svg>`;

function readWatch() { try { return JSON.parse(localStorage.getItem(WATCH_KEY) || "[]"); } catch { return []; } }
function writeWatch(list) { try { localStorage.setItem(WATCH_KEY, JSON.stringify(list)); } catch {} }
function readFaces() { try { return localStorage.getItem(FACES_KEY) !== "0"; } catch { return true; } }
function writeFaces(on) { try { localStorage.setItem(FACES_KEY, on ? "1" : "0"); } catch {} }

function precisionFor(price) {
  if (price == null || price <= 0) return 2;
  if (price >= 1000) return 2;
  if (price >= 1) return 4;
  return Math.min(12, -Math.floor(Math.log10(price)) + 3);
}

const tokenPrice = (value) => (value == null || !Number.isFinite(Number(value)) ? "—" : Number(value) >= 1 ? fmtUsd(value) : `$${fmtSmall(Number(value)).replace(/(\.\d*?[1-9])0+$/, "$1")}`);

function copyButton(text) {
  return `<button class="tk-copy" type="button" data-copy="${esc(text)}" aria-label="Copy contract">${icon("i-copy")}</button>`;
}

function face(address, id = knownIdentity(address), size = 20) {
  if (id?.avatar) return `<span class="logo logo-${size}"><img src="${esc(id.avatar)}" alt="" loading="lazy" referrerpolicy="no-referrer" data-fallback></span>`;
  const mark = esc(String(address ?? "").replace(/^0x/i, "").slice(0, 2).toUpperCase());
  return `<span class="logo logo-${size}" style="background:linear-gradient(135deg,hsl(${hue(address)} 60% 45%),hsl(${(hue(address) + 40) % 360} 60% 30%))">${mark}</span>`;
}

const flash = (node, text, dir) => {
  if (!node || node.textContent === text) return;
  node.textContent = text;
  if (!dir) return;
  node.classList.remove("flash-up", "flash-down");
  void node.offsetWidth;
  node.classList.add(dir > 0 ? "flash-up" : "flash-down");
};

export default async function mount(el, { chainIndex, address, query = {} }) {
  const key = `${chainIndex}:${address}`;
  const aborter = new AbortController();
  const signal = aborter.signal;
  let dead = false;
  let chart = null;
  let observer = null;
  let stopSnapshot = null;
  let stopPrices = null;
  let earlyTimer = null;
  let onKey = null;
  let onFullscreen = null;
  let stopSession = null;
  let quoteTimer = null;
  let facesOn = readFaces();

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
            <div class="row">
              <button class="chip" type="button" id="tk-faces-toggle" aria-pressed="${facesOn}">Traders</button>
              <div class="seg seg-sm seg-line" id="tk-scale"><button type="button" data-scale="price" aria-selected="true">Price</button><button type="button" data-scale="mc" aria-selected="false">MC</button></div>
              <button class="chip" type="button" id="tk-focus" aria-pressed="false" title="Full screen · F">Full screen</button>
            </div>
          </div>
          <div class="tk-chart" id="tk-chart"><div class="tk-faces" id="tk-faces"></div><div class="card tk-tip" id="tk-tip" hidden></div></div>
        </div>
        <div class="card">
          <div class="tabs" style="padding:0 16px" id="tk-tabs">${TABS.map(([id, label]) => `<button type="button" data-tab="${id}" aria-selected="false">${label}<i class="tk-n" data-count="${id}"></i></button>`).join("")}</div>
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
          <div class="tk-note" id="tk-note"></div>
          <button class="btn btn-lg btn-block btn-rise" type="button" id="tk-go" style="margin-top:14px">Buy</button>
          <div id="tk-progress" hidden></div>
        </div>
        <div class="card" id="tk-activity">
          <div class="card-head"><h3>Market activity</h3><div class="seg seg-sm seg-line" id="tk-win">${WINDOWS.map(([w]) => `<button type="button" data-win="${w}" aria-selected="${w === "1h"}">${w}</button>`).join("")}</div></div>
          <div class="card-pad tk-act" id="tk-act">${skel()}${skel()}${skel()}</div>
        </div>
        <div class="card tk-risk" id="tk-risk">
          <div class="card-head"><h3>Risk score</h3><span id="tk-risk-chip"></span></div>
          <div class="card-pad" id="tk-risk-body">${skel("40%", 34)}<div style="height:12px"></div>${skel("80%")}${skel("60%")}</div>
        </div>
        <div class="card tk-about" id="tk-about">
          <div class="card-head"><h3>About</h3></div>
          <div class="card-pad stack" id="tk-about-body">${skel()}${skel()}</div>
        </div>
      </aside>
    </div>
  </div>`;

  const q = (s) => $(s, el);

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
  const chainName = row?.chainName || CHAIN_NAMES[String(chainIndex)] || `Chain ${chainIndex}`;
  let price = first(num(info?.price), num(row?.price));
  const change = first(num(info?.priceChange24H), num(row?.change));
  const marketCap = first(num(info?.marketCap), num(row?.marketCap));
  const liquidity = first(num(info?.liquidity), num(row?.liquidity));
  const volume = first(num(info?.volume24H), num(info?.volume), num(row?.volume24H));
  const holdersCount = first(num(info?.holders), num(row?.holders));
  const supply = first(num(info?.circSupply), marketCap != null && price > 0 ? marketCap / price : null);

  const stat = (label, id, value, extra = "") => `<div class="tk-stat"><span>${label}</span><b><span id="${id}">${value}</span>${extra}</b></div>`;
  q("#tk-head").innerHTML = `
    <div class="tk-id">${logo(row?.logoURL, symbol, 44)}
      <div class="name"><b>${esc(name)} <small>${esc(symbol)}</small></b><span class="addr">${esc(short(address))} ${copyButton(address)}</span></div>
    </div>
    <div class="tk-stats">
      ${stat("Price", "tk-price", tokenPrice(price), `<small id="tk-change" class="${dirClass(change)}">${change == null ? "" : fmtPct(change / 100)}</small>`)}
      ${stat("Mcap", "tk-mcap", fmtUsd(marketCap, { compact: true }))}
      ${stat("Liquidity", "tk-liq", fmtUsd(liquidity, { compact: true }))}
      ${stat("24h Volume", "tk-vol", fmtUsd(volume, { compact: true }))}
      ${stat("Holders", "tk-holders", holdersCount > 0 ? fmtCompact(holdersCount) : "—")}
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

  q("#tk-about-body").innerHTML = `
    <div class="row-between"><span>Chain</span><span class="row" style="gap:6px">${logo(nativeLogo(chainIndex), chainName, 16)}${esc(chainName)}</span></div>
    <div class="row-between"><span>Contract</span><span class="row mono k" style="gap:6px">${esc(short(address))} ${copyButton(address)}</span></div>
    ${supply != null ? `<div class="row-between"><span>Supply</span><span class="num k">${fmtAmount(supply, 0)}</span></div>` : ""}
    ${row?.explorerURL && !/\/null$/.test(row.explorerURL) ? `<div class="row-between"><span>Explorer</span><a class="btn btn-ghost btn-xs" href="${esc(row.explorerURL)}" target="_blank" rel="noopener">Explorer ${icon("i-ext")}</a></div>` : ""}`;
  $$("#tk-about-body .btn svg", el).forEach((svg) => { svg.style.width = "12px"; svg.style.height = "12px"; });

  let side = query.side === "sell" ? "sell" : "buy";
  let pct = null;
  $$("[data-side]", el).forEach((b) => b.setAttribute("aria-selected", String(b.dataset.side === side)));
  const amountInput = q("#tk-amount");
  // On Monad the ticket swaps MON for the token through 0x's allowance holder, signed here, and
  // sells by approving exactly the typed amount to the holder first. On other chains Relay
  // delivers the token for MON paid on Monad, the app's route; selling there is still the app's.
  const onMonad = String(chainIndex) === "143";
  const GAS_RESERVE = 10n ** 16n;
  const canBuy = onMonad || row?.buyable !== false;
  const canSell = onMonad;
  let quote = null;
  let quoteAt = 0;
  let quoteError = null;
  let quoting = false;
  let quoteSeq = 0;
  let balance = null;
  let held = null;
  let decimals = null;
  let monPrice = null;
  let trade = null;

  const kind = () => connectedWallet()?.via ?? null;
  const canSign = () => kind() === "passkey" || kind() === "browser";
  const owner = () => { const a = connectedWallet()?.address; return /^0x[0-9a-fA-F]{40}$/.test(a ?? "") ? a : null; };
  const trim = (text) => text.replace(/\.?0+$/, "");
  const decimalText = (text) => (/^\d+(\.\d+)?$/.test(text) && Number(text) > 0 ? text : null);
  const monText = (usd) => (usd > 0 && monPrice > 0 ? decimalText(trim((usd / monPrice).toFixed(6))) : null);
  const units = (text, d) => { const [w, f = ""] = String(text).split("."); return BigInt((w || "0") + f.slice(0, d).padEnd(d, "0")); };
  const readable = (raw, d) => { const s = raw.toString().padStart(d + 1, "0"); const whole = s.slice(0, s.length - d); const frac = s.slice(s.length - d).replace(/0+$/, ""); return frac ? `${whole}.${frac}` : whole; };
  const fmtMON = (wei) => fmtAmount(Number(wei) / 1e18, 4);
  const sellText = () => {
    if (amountInput.value) return decimalText(trim(Number(amountInput.value).toFixed(Math.min(decimals ?? 18, 8))));
    if (pct && held != null && decimals != null) { const raw = (held * BigInt(pct)) / 100n; return raw > 0n ? readable(raw, decimals) : null; }
    return null;
  };

  const refreshMON = async () => {
    const out = await api("/api/v1/markets", { ttl: 30_000, signal }).catch(() => null);
    const mark = Number(out?.markets?.find((m) => m.name === "MON")?.mark);
    if (mark > 0) monPrice = mark;
  };
  const refreshHoldings = async () => {
    const user = owner();
    if (!user) { balance = null; held = null; return; }
    const [mon, tokens, d] = await Promise.all([
      monBalance(user).catch(() => null),
      onMonad ? tokenBalance(address, user).catch(() => null) : null,
      onMonad && decimals == null ? tokenDecimals(address).catch(() => null) : decimals,
    ]);
    if (dead) return;
    balance = mon; held = tokens; if (Number.isInteger(d)) decimals = d;
    paintTicket();
  };

  const requestQuote = ({ now = false } = {}) => {
    clearTimeout(quoteTimer);
    const seq = ++quoteSeq;
    const run = async () => {
      quoteError = null;
      const user = owner();
      const buying = side === "buy";
      const usd = Number(amountInput.value);
      const wants = buying ? canBuy && usd > 0 : canSell && Boolean(sellText());
      if (!user || !wants || !canSign()) { quote = null; quoting = false; paintEstimate(); return null; }
      if (buying && !(monPrice > 0)) await refreshMON();
      const amount = buying ? monText(usd) : sellText();
      if (!amount) { quote = null; quoting = false; paintEstimate(); return null; }
      quoting = true; paintEstimate();
      try {
        const out = onMonad
          ? await api(`/api/swap-quote?view=swap&user=${user}&amount=${amount}&sell=${buying ? "MON" : "TOKEN"}&token=${address}&symbol=${encodeURIComponent(symbol)}`, { signal })
          : await api(`/api/relay-quote?user=${user}&chainIndex=${chainIndex}&tokenAddress=${address}&amount=${amount}`, { signal });
        if (seq !== quoteSeq || dead) return null;
        quote = onMonad
          ? { pay: { amount: out.pay.amount, wei: buying ? BigInt(out.pay.wei) : 0n, raw: buying ? null : BigInt(out.pay.raw) }, receive: { amount: out.receive.amount, minimum: out.receive.minimum }, fee: `${fmtAmount(Number(out.feeMON), 4)} MON gas`, transaction: out.transaction, approval: out.approval ?? null, requestId: null }
          : { pay: { amount: out.pay.amount, wei: units(out.pay.amount, 18), raw: null }, receive: { amount: out.receive.amount, minimum: out.receive.minimum }, fee: `$${out.feeUsd} fee`, transaction: out.transaction, approval: null, requestId: out.requestId };
        quoteAt = Date.now();
      } catch (error) {
        if (seq !== quoteSeq || dead) return null;
        quote = null; quoteError = error?.message || "A live quote is unavailable right now.";
      }
      quoting = false; paintEstimate();
      return quote;
    };
    if (now) return run();
    return new Promise((resolve) => { quoteTimer = setTimeout(() => resolve(run()), 450); });
  };

  const paintTicket = () => {
    const buying = side === "buy";
    q("#tk-prefix").textContent = buying ? "$" : "";
    q("#tk-prefix").hidden = !buying;
    const signer = canSign();
    const sub = buying
      ? `Buy ${symbol} in USD, paid in MON${balance != null && signer ? ` · ${fmtMON(balance)} MON available` : ""}`
      : canSell ? `Sell ${symbol} for MON${held != null && decimals != null && signer ? ` · ${fmtAmount(Number(readable(held, decimals)))} ${symbol} held` : ""}` : `Sell ${symbol} for USD`;
    q("#tk-ticket-sub").textContent = sub;
    q("#tk-chips").innerHTML = buying
      ? [25, 50, 100, 250].map((v) => `<button class="chip" type="button" data-usd="${v}">$${v}</button>`).join("")
      : [25, 50, 75, 100].map((v) => `<button class="chip" type="button" data-pct="${v}" aria-pressed="${pct === v}">${v}%</button>`).join("");
    const go = q("#tk-go");
    const connected = Boolean(connectedWallet());
    const locked = kind() === "passkey" && !isUnlocked();
    const can = buying ? canBuy : canSell;
    go.className = `btn btn-lg btn-block ${!connected ? "btn-primary" : buying ? "btn-rise" : "btn-fall"}`;
    go.hidden = Boolean(trade);
    go.disabled = connected && signer && buying && !canBuy;
    const verb = buying ? "Buy" : "Sell";
    go.textContent = !connected ? "Connect wallet"
      : !signer || !can ? (buying && !canBuy ? `Not on ${chainName} yet` : `${verb} ${symbol} in Desk`)
      : locked ? `Unlock to ${verb.toLowerCase()} ${symbol}`
      : `${verb} ${symbol}`;
    paintEstimate();
    paintProgress();
  };
  const paintEstimate = () => {
    const amount = Number(amountInput.value);
    amountInput.style.width = `${Math.max(1, amountInput.value.length) + 0.4}ch`;
    const est = q("#tk-est");
    const note = q("#tk-note");
    note.textContent = "";
    const buying = side === "buy";
    if (!buying && !amount && pct) {
      est.textContent = quote ? `≈ ${fmtAmount(Number(quote.receive.amount), 4)} MON for ${fmtAmount(Number(quote.pay.amount))} ${symbol} · ${quote.fee}` : quoting ? "Quoting…" : `${pct}% of your ${symbol}`;
      if (quoteError) note.textContent = quoteError;
      return;
    }
    if (!(amount > 0)) { est.textContent = ""; return; }
    if (quote) {
      est.textContent = buying
        ? `≈ ${fmtAmount(Number(quote.receive.amount))} ${symbol} for ${fmtAmount(Number(quote.pay.amount), 4)} MON · ${quote.fee}`
        : `≈ ${fmtAmount(Number(quote.receive.amount), 4)} MON for ${fmtAmount(Number(quote.pay.amount))} ${symbol} · ${quote.fee}`;
      if (buying && balance != null && canSign() && balance < quote.pay.wei + GAS_RESERVE) note.textContent = `That needs ${fmtMON(quote.pay.wei + GAS_RESERVE)} MON with gas; the wallet holds ${fmtMON(balance)} MON.`;
      if (!buying && held != null && quote.pay.raw != null && held < quote.pay.raw) note.textContent = `The wallet holds ${fmtAmount(Number(readable(held, decimals ?? 18)))} ${symbol}.`;
      return;
    }
    if (quoting) { est.textContent = "Quoting…"; return; }
    est.textContent = !(price > 0) ? "" : buying ? `≈ ${fmtAmount(amount / price)} ${symbol} at ${tokenPrice(price)}` : `≈ ${fmtUsd(amount * price)} at ${tokenPrice(price)}`;
    if (quoteError) note.textContent = quoteError;
  };
  const paintProgress = () => {
    const host = q("#tk-progress");
    if (!trade) { host.hidden = true; host.innerHTML = ""; return; }
    const mark = { running: "", done: "✓", stopped: "×", waiting: "" };
    const done = Boolean(trade.outcome);
    host.hidden = false;
    host.innerHTML = `<div class="tk-steps" style="margin-top:14px">${trade.steps.map((step) => `<div class="step ${step.state}"><i>${mark[step.state]}</i><span>${esc(step.label)}</span>${step.href && step.state !== "waiting" ? `<a href="${esc(step.href)}" target="_blank" rel="noopener">View</a>` : ""}</div>`).join("")}</div>`
      + (done ? `<div class="tk-outcome"><b>${esc(trade.outcome.title)}</b><span>${esc(trade.outcome.text)}</span></div><button class="btn btn-block" type="button" id="tk-done" style="margin-top:12px">Done</button>` : "");
    $("#tk-done", host)?.addEventListener("click", () => { trade = null; amountInput.value = ""; pct = null; quote = null; paintTicket(); refreshHoldings(); });
  };
  const step = (key, state, href) => {
    const s = trade?.steps.find((x) => x.key === key);
    if (!s) return;
    s.state = state; if (href) s.href = href;
    paintProgress();
  };
  const finish = (title, text) => { for (const s of trade.steps) if (s.state === "running") s.state = "stopped"; else if (s.state === "waiting") s.state = "stopped"; trade.outcome = { title, text }; paintTicket(); refreshHoldings(); };

  q("#tk-side-seg").addEventListener("click", (event) => {
    const button = event.target.closest("[data-side]");
    if (!button || button.dataset.side === side || trade) return;
    side = button.dataset.side;
    $$("[data-side]", el).forEach((b) => b.setAttribute("aria-selected", String(b === button)));
    amountInput.value = "";
    pct = null;
    quote = null;
    paintTicket();
  });
  q("#tk-chips").addEventListener("click", (event) => {
    const chip = event.target.closest(".chip");
    if (!chip || trade) return;
    if (chip.dataset.usd) amountInput.value = chip.dataset.usd;
    else { pct = Number(chip.dataset.pct); amountInput.value = ""; $$("[data-pct]", el).forEach((c) => c.setAttribute("aria-pressed", String(Number(c.dataset.pct) === pct))); }
    quote = null;
    paintEstimate();
    requestQuote();
  });
  amountInput.addEventListener("input", () => {
    if (side === "sell" && amountInput.value) { pct = null; $$("[data-pct]", el).forEach((c) => c.setAttribute("aria-pressed", "false")); }
    quote = null;
    paintEstimate();
    requestQuote();
  });
  const onWallet = () => { quote = null; paintTicket(); refreshHoldings(); requestQuote(); };
  document.addEventListener("wallet", onWallet);
  stopSession = onSession(() => { if (!dead) { paintTicket(); refreshHoldings(); requestQuote(); } });

  /// Signs and sends one call from whichever wallet is connected and resolves once it is mined.
  const send = async ({ to, data, value }, key) => {
    const wallet = connectedWallet();
    if (wallet.via === "passkey") {
      const s = session();
      if (!s) throw Object.assign(new Error("locked"), { code: "locked" });
      return sendCall({ account: s.wallet.account, to, data, value, onSent: (hash) => step(key, "running", explorerTx(hash)) });
    }
    const provider = window.ethereum;
    if (!provider) throw new Error("No browser wallet found on this device.");
    try { await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x8f" }] }); }
    catch (error) { if (error?.code === 4001) throw error; throw new Error("Switch the wallet to Monad first."); }
    const hash = await provider.request({ method: "eth_sendTransaction", params: [{ from: wallet.address, to, data, value: `0x${value.toString(16)}` }] });
    step(key, "running", explorerTx(hash));
    return waitForReceipt(hash);
  };
  const track = async (requestId) => {
    const deadline = Date.now() + 120_000;
    while (Date.now() < deadline && !dead) {
      const out = await api(`/api/relay-status?requestId=${requestId}`, { signal }).catch(() => null);
      if (["filled", "refunded", "failed"].includes(out?.phase)) return out.phase;
      await new Promise((f) => setTimeout(f, 1500));
    }
    return "timeout";
  };
  const failed = (error) => {
    const text = String(error?.message ?? "");
    if (error?.code === 4001 || error?.code === "locked" || /reject|denied|cancel/i.test(text)) { trade = null; paintTicket(); return; }
    finish("Not done", /reverted/i.test(text) ? "The transaction was rejected on Monad. Only gas was spent." : text || "The transaction could not be sent. Nothing left the wallet.");
  };

  q("#tk-go").addEventListener("click", async () => {
    if (trade) return;
    if (!connectedWallet()) { $("#connect").click(); return; }
    const buying = side === "buy";
    const amount = Number(amountInput.value);
    if (!canSign() || (buying ? !canBuy : !canSell)) {
      if (buying && !canBuy) return;
      const what = buying ? (amount > 0 ? `${fmtUsd(amount)} of ${symbol}` : symbol) : (amount > 0 ? `${fmtAmount(amount)} ${symbol}` : pct ? `${pct}% of your ${symbol}` : symbol);
      handoff({ title: `${buying ? "Buy" : "Sell"} ${symbol} in Desk`, sub: `${buying ? "Buy" : "Sell"} ${what} on ${chainName}. Scan to get Desk.` });
      return;
    }
    if (buying ? !(amount > 0) : !sellText()) { amountInput.focus(); return; }
    if (kind() === "passkey" && !isUnlocked()) { document.dispatchEvent(new CustomEvent("desk:unlock")); return; }
    // Quotes hold for a short while; an older one is refreshed, not filled at a moved rate.
    if (!quote || Date.now() - quoteAt > 20_000) await requestQuote({ now: true });
    if (!quote || dead) return;
    const tx = quote.transaction;
    const wei = buying ? quote.pay.wei : 0n;
    const ok = tx && Number(tx.chainId) === 143 && /^0x[0-9a-fA-F]{40}$/.test(tx.to ?? "") && /^0x[0-9a-fA-F]+$/.test(tx.data ?? "") && /^\d+$/.test(String(tx.value ?? "")) && BigInt(tx.value) === wei;
    if (!ok) { quote = null; quoteError = "This quote did not pass Desk's safety check, so nothing was signed."; paintEstimate(); return; }
    if (buying && balance != null && balance < wei + GAS_RESERVE) { paintEstimate(); return; }
    if (!buying && held != null && held < quote.pay.raw) { paintEstimate(); return; }
    const user = owner();
    const received = `${fmtAmount(Number(quote.receive.amount), buying ? 2 : 4)} ${buying ? symbol : "MON"}`;
    trade = {
      steps: onMonad
        ? [...(buying ? [] : [{ key: "approve", label: `Approve ${symbol} for the swap`, state: "waiting" }]), { key: "swap", label: buying ? `Swap MON for ${symbol} on Monad` : `Swap ${symbol} for MON on Monad`, state: "waiting" }]
        : [{ key: "swap", label: "Send MON on Monad", state: "waiting" }, { key: "fill", label: `Relay delivers ${symbol} on ${chainName}`, state: "waiting", href: `https://relay.link/transaction/${quote.requestId}` }],
      outcome: null,
    };
    paintTicket();
    try {
      if (quote.approval) {
        step("approve", "running");
        const spender = quote.approval.spender;
        const raw = BigInt(quote.approval.amount);
        if ((await allowance(address, user, spender)) < raw) await send({ to: address, data: chainCall("approve", [spender, raw]), value: 0n }, "approve");
        step("approve", "done");
      }
      step("swap", "running");
      await send({ to: tx.to, data: tx.data, value: wei }, "swap");
      step("swap", "done");
    } catch (error) { failed(error); return; }
    if (onMonad) { finish(buying ? `Bought ≈ ${received}` : `Sold for ≈ ${received}`, buying ? `${symbol} is in your wallet. At least ${fmtAmount(Number(quote.receive.minimum))} ${symbol} was guaranteed by the quote.` : `MON is in your wallet. At least ${fmtAmount(Number(quote.receive.minimum), 4)} MON was guaranteed by the quote.`); return; }
    step("fill", "running");
    const phase = await track(quote.requestId);
    if (dead) return;
    if (phase === "filled") { step("fill", "done"); finish(`Bought ≈ ${received}`, `Delivered on ${chainName}. It shows in your wallet shortly.`); }
    else if (phase === "refunded") finish("Refunded", "Relay could not fill this, so the MON came back.");
    else finish("Not filled", phase === "timeout" ? "Still filling. Check Relay for the latest status." : "Relay could not fill this. Any MON not refunded shows on Relay.");
  });
  paintTicket();
  refreshMON();
  refreshHoldings();

  let risk = { status: "loading", data: null };
  api(`/api/token-details?view=risk&chainIndex=${chainIndex}&address=${address}&riskLevel=${encodeURIComponent(row?.riskLevel ?? "")}&communityRecognized=${row?.communityRecognized ?? ""}`, { ttl: 60_000, signal })
    .catch(() => null)
    .then((out) => {
      if (dead) return;
      risk = { status: out ? "ready" : "unavailable", data: out };
      paintRisk();
    });

  // The page becomes the chart: the shell steps out and the browser goes full screen when the
  // user asked with a click or a key. Leaving browser full screen leaves the mode too.
  let focus = false;
  const setFocus = (on, { browser = true } = {}) => {
    focus = on;
    document.body.classList.toggle("focus", on);
    try { localStorage.setItem("desk.web.focus", on ? "on" : "off"); } catch {}
    const button = q("#tk-focus");
    if (button) { button.setAttribute("aria-pressed", String(on)); button.textContent = on ? "Exit full screen" : "Full screen"; }
    if (browser && on && !document.fullscreenElement) document.documentElement.requestFullscreen?.().catch(() => {});
    if (!on && document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
  };
  onFullscreen = () => { if (!document.fullscreenElement && focus) setFocus(false); };
  document.addEventListener("fullscreenchange", onFullscreen);
  onKey = (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const target = event.target;
    if (target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
    if (event.key.toLowerCase() === "f") { setFocus(!focus); event.preventDefault(); return; }
    if (event.key === "Escape" && focus) { setFocus(false); event.preventDefault(); }
  };
  document.addEventListener("keydown", onKey);
  q("#tk-focus").addEventListener("click", () => setFocus(!focus));
  try { if (localStorage.getItem("desk.web.focus") === "on") setFocus(true, { browser: false }); } catch {}

  let bar = "5m";
  let scale = query.scale === "mc" ? "mc" : "price";
  $$("[data-scale]", el).forEach((b) => b.setAttribute("aria-selected", String(b.dataset.scale === scale)));
  let candleSeries = null;
  let volumeSeries = null;
  let candles = [];
  let candlesAt = 0;
  let generation = 0;
  const chartEl = q("#tk-chart");
  const factor = () => (scale === "mc" && supply != null ? supply : 1);
  const priceFormatter = (v) => (scale === "mc" ? `$${fmtCompact(v)}` : price < 0.01 ? `$${fmtSmall(v)}` : `$${v.toLocaleString("en-US", { minimumFractionDigits: precisionFor(price), maximumFractionDigits: precisionFor(price) })}`);
  const toPoint = (c) => ({ time: c.time, open: c.open * factor(), high: c.high * factor(), low: c.low * factor(), close: c.close * factor() });
  const toVolume = (c) => ({ time: c.time, value: c.volUsd, color: volumeColor(c.close >= c.open) });
  // Lightweight Charts labels the axis in UTC, so times are shifted to read as local.
  const tzShift = -new Date().getTimezoneOffset() * 60;
  const barTime = (at) => Math.floor(at / 1000 / BAR_SECONDS[bar]) * BAR_SECONDS[bar] + tzShift;
  const parseCandles = (rows) => (rows ?? []).map((c) => ({ time: Math.floor(Number(c[0]) / 1000) + tzShift, open: Number(c[1]), high: Number(c[2]), low: Number(c[3]), close: Number(c[4]), volUsd: Number(c[6] ?? c[5]) })).filter((c) => Number.isFinite(c.time) && Number.isFinite(c.close)).sort((a, b) => a.time - b.time).filter((c, i, all) => !i || c.time !== all[i - 1].time);

  let legend = null;
  let countdown = null;
  let framed = false;
  const ensureChart = () => {
    if (chart || !window.LightweightCharts) return;
    const LW = window.LightweightCharts;
    chart = LW.createChart(chartEl, chartOptions(LW, { width: chartEl.clientWidth, height: chartEl.clientHeight, localization: { priceFormatter } }));
    candleSeries = chart.addCandlestickSeries(candleOptions({ priceFormat: { type: "custom", minMove: 10 ** -precisionFor(price), formatter: priceFormatter } }));
    volumeSeries = chart.addHistogramSeries({ priceScaleId: "", priceFormat: { type: "volume" }, lastValueVisible: false, priceLineVisible: false });
    volumeSeries.priceScale().applyOptions({ scaleMargins: { top: 0.78, bottom: 0 } });
    legend = chartLegend(chartEl, { title: `${symbol} / USD`, bar, format: (v) => priceFormatter(v).replace(/^\$/, "") });
    countdown = chartCountdown(chartEl, { barSeconds: () => BAR_SECONDS[bar], y: () => { const last = candles[candles.length - 1]; const y = last ? candleSeries.priceToCoordinate(last.close * factor()) : null; return y == null || y < 0 ? null : y; } });
    chart.subscribeCrosshairMove((param) => {
      const hit = param?.seriesData?.get(candleSeries);
      const i = hit ? candles.findIndex((c) => c.time === hit.time) : -1;
      legend.update(i >= 0 ? candles[i] : candles[candles.length - 1], i >= 0 ? candles[i - 1] : candles[candles.length - 2], bar);
    });
    chart.timeScale().subscribeVisibleTimeRangeChange(schedulePlace);
    chart.timeScale().subscribeVisibleLogicalRangeChange(schedulePlace);
    observer = new ResizeObserver(() => { if (chart) { chart.applyOptions({ width: chartEl.clientWidth, height: chartEl.clientHeight }); schedulePlace(); } });
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
    if (!framed) { chart.timeScale().applyOptions({ barSpacing: Math.min(12, Math.max(4, chartEl.clientWidth / (candles.length + 8))) }); chart.timeScale().scrollToRealTime(); framed = true; }
    legend?.update(candles[candles.length - 1], candles[candles.length - 2], bar);
    countdown?.tick();
    chartEl.querySelector(".empty")?.remove();
    if (!candles.length) chartEl.insertAdjacentHTML("beforeend", `<div class="empty">No candles yet.</div>`);
    buildFaces();
  };

  /// The server's candles replace ours; bars the price ticks opened before the server did stay.
  const applyCandles = (next) => {
    const newest = next.length ? next[next.length - 1].time : 0;
    candles = [...next, ...candles.filter((c) => c.time > newest)];
    candlesAt = Date.now();
    candleSeries.setData(candles.map(toPoint));
    volumeSeries.setData(candles.map(toVolume));
    schedulePlace();
  };

  const liveCandle = (p, at) => {
    if (!chart || !candles.length) return;
    const t = barTime(at);
    let last = candles[candles.length - 1];
    if (t > last.time) {
      last = { time: t, open: last.close, high: Math.max(last.close, p), low: Math.min(last.close, p), close: p, volUsd: 0 };
      candles.push(last);
      volumeSeries.update(toVolume(last));
    } else {
      last.close = p;
      last.high = Math.max(last.high, p);
      last.low = Math.min(last.low, p);
    }
    candleSeries.update(toPoint(last));
    legend?.update(last, candles[candles.length - 2], bar);
    countdown?.tick();
    schedulePlace();
  };

  const facesEl = q("#tk-faces");
  const tipEl = q("#tk-tip");
  let faceNodes = [];
  let placeQueued = false;
  let tipKey = null;

  const indexBefore = (t) => {
    let lo = 0, hi = candles.length - 1, out = -1;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (candles[mid].time <= t) { out = mid; lo = mid + 1; } else hi = mid - 1; }
    return out;
  };

  const placeFaces = () => {
    if (!chart || !faceNodes.length) return;
    const ts = chart.timeScale();
    const width = chartEl.clientWidth - (chart.priceScale("right").width() || 0);
    const height = chartEl.clientHeight - (ts.height() || 0);
    const sec = BAR_SECONDS[bar];
    const f = factor();
    for (const n of faceNodes) {
      const i = indexBefore(n.aligned);
      const x = i < 0 ? null : ts.logicalToCoordinate(i + (n.aligned - candles[i].time) / sec);
      const y = candleSeries.priceToCoordinate(n.price * f);
      const hide = x == null || y == null || x < 0 || x > width || y < 0 || y > height;
      n.el.hidden = hide;
      if (!hide) { n.el.style.left = `${x}px`; n.el.style.top = `${y + n.offset}px`; }
    }
    if (tipKey) placeTip();
  };
  function schedulePlace() {
    if (placeQueued) return;
    placeQueued = true;
    requestAnimationFrame(() => { placeQueued = false; placeFaces(); });
  }

  const placeTip = () => {
    const n = faceNodes.find((f) => f.trade && tradeKey(f.trade) === tipKey);
    if (!n || n.el.hidden) { tipEl.hidden = true; return; }
    tipEl.hidden = false;
    const x = parseFloat(n.el.style.left);
    const y = parseFloat(n.el.style.top);
    const tw = tipEl.offsetWidth;
    const th = tipEl.offsetHeight;
    const left = x + 16 + tw > chartEl.clientWidth ? x - 16 - tw : x + 16;
    tipEl.style.left = `${Math.max(4, left)}px`;
    tipEl.style.top = `${Math.max(4, Math.min(chartEl.clientHeight - th - 4, y - th / 2))}px`;
  };
  const showTip = (n) => {
    const t = n.trade;
    const id = knownIdentity(t.userAddress);
    tipKey = tradeKey(t);
    tipEl.innerHTML = `<b>${esc(id?.name ?? short(t.userAddress))}</b> ${t.type === "buy" ? "bought" : "sold"} ${esc(symbol)} · Price ${tokenPrice(num(t.price))} · Value ${fmtUsd(num(t.volume))} · Wallet ${esc(short(t.userAddress))}<small>${ago(Number(t.time))}</small>`;
    placeTip();
  };
  const hideTip = () => { tipKey = null; tipEl.hidden = true; };

  function buildFaces() {
    facesEl.innerHTML = "";
    faceNodes = [];
    if (!facesOn || !chart) { hideTip(); return; }
    const groups = new Map();
    const biggest = [...trades.slice(0, 60)].sort((a, b) => (num(b.volume) ?? 0) - (num(a.volume) ?? 0)).slice(0, FACES_MAX);
    for (const t of biggest) {
      const at = Number(t.time);
      const p = num(t.price);
      if (!Number.isFinite(at) || p == null) continue;
      const aligned = barTime(at);
      const side = t.type === "buy" ? "buy" : "sell";
      const k = `${aligned}:${side}`;
      if (!groups.has(k)) groups.set(k, { aligned, side, list: [] });
      groups.get(k).list.push(t);
    }
    for (const g of groups.values()) {
      g.list.sort((a, b) => Number(b.time) - Number(a.time));
      const anchor = num(g.list[0].price);
      const dir = g.side === "buy" ? -1 : 1;
      g.list.slice(0, STACK_MAX).forEach((t, i) => {
        const node = document.createElement("button");
        node.type = "button";
        node.className = `tk-face ${g.side}`;
        node.innerHTML = face(t.userAddress);
        node.setAttribute("aria-label", `${t.type === "buy" ? "Buy" : "Sell"} by ${short(t.userAddress)}`);
        const entry = { el: node, trade: t, aligned: g.aligned, price: anchor, offset: dir * i * 8 };
        node.addEventListener("mouseenter", () => showTip(entry));
        node.addEventListener("mouseleave", hideTip);
        node.addEventListener("click", () => navigate(`/app/wallet/${t.userAddress}`));
        facesEl.appendChild(node);
        faceNodes.push(entry);
      });
      if (g.list.length > STACK_MAX) {
        const more = document.createElement("span");
        more.className = "tk-more";
        more.textContent = `+${g.list.length - STACK_MAX}`;
        facesEl.appendChild(more);
        faceNodes.push({ el: more, trade: null, aligned: g.aligned, price: anchor, offset: dir * (STACK_MAX * 8 + 6) });
      }
    }
    schedulePlace();
    if (tipKey && !faceNodes.some((n) => n.trade && tradeKey(n.trade) === tipKey)) hideTip();
  }

  q("#tk-faces-toggle").addEventListener("click", (event) => {
    facesOn = !facesOn;
    event.currentTarget.setAttribute("aria-pressed", String(facesOn));
    writeFaces(facesOn);
    buildFaces();
  });

  const asked = new Set();
  const learn = (addresses, then) => {
    const fresh = [...new Set(addresses)].filter((a) => a && !asked.has(a));
    if (!fresh.length) return;
    fresh.forEach((a) => asked.add(a));
    Promise.all(fresh.map((a) => identity(a))).then((ids) => { if (!dead && ids.some(Boolean)) then(); });
  };

  const TAB_IDS = TABS.map(([id]) => id);
  let tab = TAB_IDS.includes(query.tab) ? query.tab : "trades";
  $$("[data-tab]", el).forEach((b) => b.setAttribute("aria-selected", String(b.dataset.tab === tab)));
  let trades = [];
  let seenTrades = new Set();
  let win = "1h";
  let early = { status: "loading", data: null };
  const holders = (details?.holders ?? []).map((h) => ({ address: h.holderWalletAddress, amount: num(h.holdAmount), pct: num(h.holdPercent) }));

  function tradeKey(t) { return t.id ?? `${t.time}:${t.userAddress}:${t.volume}`; }
  let shown = 8;
  const tokenAmount = (t) => {
    const hit = (t.changedTokenInfo ?? []).find((c) => String(c.tokenAddress ?? "").toLowerCase() === address.toLowerCase()) ?? (t.changedTokenInfo ?? []).find((c) => c.tokenSymbol === symbol);
    return num(hit?.amount);
  };

  const TX_EXPLORERS = { "143": "https://monadscan.com/tx/", "501": "https://solscan.io/tx/", "1": "https://etherscan.io/tx/", "8453": "https://basescan.org/tx/", "56": "https://bscscan.com/tx/", "42161": "https://arbiscan.io/tx/", "10": "https://optimistic.etherscan.io/tx/", "137": "https://polygonscan.com/tx/" };
  const quoteLeg = (t) => (t.changedTokenInfo ?? []).find((c) => String(c.tokenAddress ?? "").toLowerCase() !== address.toLowerCase() && c.tokenSymbol !== symbol);
  const txLink = (t) => {
    const base = TX_EXPLORERS[String(chainIndex)];
    const hash = String(t.txHashUrl ?? t.txHash ?? "");
    if (!base || !hash) return "";
    return `<a class="tk-tx" href="${esc(/^https?:/.test(hash) ? hash : base + hash)}" target="_blank" rel="noopener" aria-label="Transaction">${icon("i-ext")}</a>`;
  };
  const tradeRow = (t, fresh = false) => {
    const q = quoteLeg(t);
    return `
        <tr class="${fresh ? "enter" : ""}" data-key="${esc(tradeKey(t))}">
          <td><span class="row" style="gap:8px">${person(t.userAddress)}${t.dexName ? `<span class="via">${esc(t.dexName)}</span>` : ""}</span></td>
          <td class="left"><span class="side-chip ${t.type === "buy" ? "buy" : "sell"}">${t.type === "buy" ? "BUY" : "SELL"}</span></td>
          <td class="num ${t.type === "buy" ? "up" : "down"}">${fmtUsd(num(t.volume))}</td>
          <td class="num">${fmtAmount(tokenAmount(t))}</td>
          <td class="num">${tokenPrice(num(t.price))}</td>
          <td class="num">${q ? `${fmtAmount(num(q.amount))} <span class="muted">${esc(q.tokenSymbol ?? "")}</span>` : "—"}</td>
          <td class="mono muted"><span class="row" style="gap:8px;justify-content:flex-end">${txLink(t)}<span class="tk-ago">${ago(Number(t.time), { suffix: false })}</span></span></td>
        </tr>`;
  };

  const traderRows = () => {
    const by = new Map();
    for (const t of trades) {
      const a = t.userAddress;
      if (!a) continue;
      const r = by.get(a) ?? { address: a, buys: 0, sells: 0, bought: 0, sold: 0, last: 0 };
      const usd = num(t.volume) ?? 0;
      if (t.type === "buy") { r.buys += 1; r.bought += usd; } else { r.sells += 1; r.sold += usd; }
      r.last = Math.max(r.last, Number(t.time) || 0);
      by.set(a, r);
    }
    return [...by.values()].sort((a, b) => (b.bought + b.sold) - (a.bought + a.sold));
  };

  const paintCounts = () => {
    const counts = {
      trades: trades.length || null, holders: holders.length, traders: trades.length ? traderRows().length : null,
      bundlers: early.data?.bundles?.length ?? null, snipers: early.data?.snipers?.length ?? null, insiders: early.data?.insiders?.length ?? null,
    };
    for (const node of $$("[data-count]", el)) { const v = counts[node.dataset.count]; node.textContent = v == null ? "" : fmtCompact(v); }
  };

  const sinceLaunch = (item, d) => {
    const t = ms(item.time);
    const t0 = ms(d.createdAt);
    if (t != null && t0 != null) { const s = Math.max(0, Math.round((t - t0) / 1000)); return s < 90 ? `+${s}s` : `+${Math.round(s / 60)}m`; }
    const b = num(item.block);
    const b0 = num(d.launchBlock);
    return b != null && b0 != null ? `+${b - b0} blocks` : "—";
  };
  const share = (v) => (v > 0 && v < 0.001 ? "<0.1%" : fmtPct(v, { sign: false, digits: 1 }));
  const holdsNow = (v) => (v == null ? "—" : v >= 1e-6 ? `<span class="num">${share(v)}</span>` : `<span class="chip chip-fall">sold</span>`);
  const bought = (amount, s) => `<span class="num">${fmtAmount(amount, 2)}</span> <span class="muted num">${share(s)}</span>`;
  const stack = (wallets) => `<span class="tk-stack">${wallets.slice(0, 5).map((w) => face(w)).join("")}${wallets.length > 5 ? `<span class="more">+${wallets.length - 5}</span>` : ""}</span>`;

  const paintRisk = () => {
    if (risk.status === "loading") return;
    const r = risk.data;
    const level = RISK_LABEL[r?.level] ? r.level : "unchecked";
    q("#tk-risk-chip").innerHTML = `<span class="risk ${level}"><i></i>${RISK_LABEL[level]}</span>`;
    const score = Number.isFinite(r?.score) ? r.score : null;
    const ticks = Array.from({ length: 10 }, (_, i) => `<i class="${score != null && i < Math.round(score) ? "on" : ""}"></i>`).join("");
    const d = early.status === "ready" ? early.data : null;
    const launchCell = (v) => (d ? share(v ?? 0) : early.status === "loading" || early.status === "indexing" ? "…" : "—");
    const pct = (v) => (v == null ? "—" : share(v / 100));
    const tone = (v, warn, bad) => (v == null ? "" : v >= bad ? " fall" : v >= warn ? " amber" : "");
    const launchTone = (v) => (d ? tone(v ?? 0, 0.05, 0.2) : early.status === "loading" || early.status === "indexing" ? " pulse" : "");
    const m = r?.metrics ?? {};
    const liquidity = m.liquidity ?? null;
    const cells = [
      ["Top 10", pct(m.topTen), tone(m.topTen, 30, 50), "Held by the ten largest wallets, pool left out"],
      ["Bundler", launchCell(d?.totals?.bundles), launchTone(d?.totals?.bundles), "Bought by grouped wallets in the launch blocks"],
      ["Sniper", launchCell(d?.totals?.snipers), launchTone(d?.totals?.snipers), "Bought in the first blocks after launch"],
      ["Insider", launchCell(d?.totals?.insiders), launchTone(d?.totals?.insiders), "Held by the creator and wallets the creator funded"],
      ["Dev", pct(m.creator), tone(m.creator, 10, 25), "Held by the creator wallet now"],
      ["Liquidity", liquidity == null ? "—" : `$${fmtCompact(liquidity)}`, liquidity == null ? "" : liquidity < 10_000 ? " fall" : liquidity < 50_000 ? " amber" : "", "In the pool"],
    ];
    const badges = (r?.badges ?? []).map((b) => `<span class="tk-badge ${b.ok ? "ok" : "warn"}"><i>${b.ok ? "✓" : "!"}</i>${esc(b.text)}</span>`).join("");
    const reasons = r?.reasons ?? [];
    const facts = r?.facts ?? [];
    q("#tk-risk-body").innerHTML = `
      <div class="tk-score ${level}"><div class="n">${score == null ? "—" : score.toFixed(1)}<small>/ 10</small></div><div class="tk-ticks" aria-hidden="true">${ticks}</div></div>
      ${badges ? `<div class="tk-badges">${badges}</div>` : ""}
      <div class="tk-riskgrid">${cells.map(([k, v, cls, title]) => `<div title="${esc(title)}"><span>${k}</span><b class="${cls.trim()}">${v}</b></div>`).join("")}</div>
      <div class="tk-risklines">${r
        ? (reasons.length ? reasons.map((x) => `<div class="line ${esc(x.severity ?? "info")}"><i></i><span>${esc(x.text)}</span></div>`).join("") : `<div class="line"><i></i><span>Nothing stood out.</span></div>`)
          + facts.map((f) => `<div class="line muted"><i></i><span>${esc(f.text)}</span></div>`).join("")
        : `<div class="line muted"><i></i><span>No checks ran for this token.</span></div>`}</div>
      ${r ? `<div class="checked">Checked${r.checkedAt ? ` ${ago(r.checkedAt)}` : ""} · OKX, nad.fun, on-chain</div>` : ""}`;
  };

  const earlyLine = () => {
    const s = early.status;
    const text = s === "unsupported" ? "Read on Monad only for now."
      : s === "indexing" || s === "loading" ? "Reading the launch from the chain…"
      : s === "stale" ? "The launch is still being read. Try again in a minute."
      : "The launch could not be read right now.";
    return `<div class="tk-line${s === "indexing" || s === "loading" ? " pulse" : ""}">${text}</div>`;
  };

  const paintEarly = (host) => {
    if (early.status !== "ready") { host.innerHTML = earlyLine(); return; }
    const d = early.data;
    const [label, totalKey] = EARLY_LABEL[tab];
    const total = num(d.totals?.[totalKey]);
    const head = `<div class="tk-tabhead"><span class="chip">${label} hold ${total == null ? "—" : share(total)}</span>${d.createdAt ? `<span>Launched ${ago(ms(d.createdAt))}</span>` : ""}${d.creator ? `<span class="row" style="gap:6px">by ${person(d.creator, undefined, { size: 16, via: false })}</span>` : ""}</div>`;
    const table = (heads, rows) => `<table class="table table-compact"><thead><tr>${heads}</tr></thead><tbody>${rows}</tbody></table>`;
    let body;
    if (tab === "snipers") {
      const rows = d.snipers ?? [];
      body = rows.length
        ? table(`<th class="rank">#</th><th class="left">Wallet</th><th>After launch</th><th>Bought</th><th>Holds now</th>`, rows.map((s, i) => `<tr><td class="rank">${i + 1}</td><td class="left">${person(s.address)}</td><td class="num">${sinceLaunch(s, d)}</td><td>${bought(s.amount, s.share)}</td><td>${holdsNow(s.holdsNow)}</td></tr>`).join(""))
        : `<div class="tk-line">No snipers in the first blocks.</div>`;
    } else if (tab === "bundlers") {
      const rows = d.bundles ?? [];
      body = rows.length
        ? table(`<th>Block</th><th class="left">Time</th><th class="left">Wallets</th><th>Bought</th>`, rows.map((b) => `<tr><td class="mono">${esc(b.block ?? "—")}</td><td class="left mono muted">${b.time != null ? ago(ms(b.time), { suffix: false }) : "—"}</td><td class="left">${stack(b.wallets ?? [])}<span class="muted" style="margin-left:8px">${(b.wallets ?? []).length}</span></td><td>${bought(b.amount, b.share)}</td></tr>`).join(""))
        : `<div class="tk-line">No bundles at launch.</div>`;
      learn(rows.flatMap((b) => b.wallets ?? []), () => { if (tab === "bundlers") paintTable(); });
    } else {
      const rows = d.insiders ?? [];
      body = rows.length
        ? table(`<th>Wallet</th><th class="left">Via</th><th>Received</th><th>Holds now</th>`, rows.map((r) => `<tr><td>${person(r.address)}</td><td class="left"><span class="chip${r.via === "creator" ? " chip-brand" : ""}">${r.via === "creator" ? "creator" : "from creator"}</span></td><td>${bought(r.amount, r.share)}</td><td>${holdsNow(r.holdsNow)}</td></tr>`).join(""))
        : `<div class="tk-line">No insiders found.</div>`;
    }
    host.innerHTML = head + body;
  };

  const paintTable = ({ fresh = new Set() } = {}) => {
    const host = q("#tk-table");
    if (tab === "trades") {
      host.innerHTML = trades.length
        ? `<table class="table table-compact"><thead><tr><th>Wallet</th><th class="left">Type</th><th>USD</th><th>${esc(symbol)}</th><th>Price</th><th>Quote</th><th>Txn · Time</th></tr></thead><tbody>${trades.slice(0, shown).map((t) => tradeRow(t, fresh.has(tradeKey(t)))).join("")}</tbody></table>`
          + (trades.length > shown ? `<div class="card-foot"><span>${Math.min(shown, trades.length)} of ${trades.length} trades</span><button class="btn btn-ghost btn-xs" type="button" data-more>Show more</button></div>` : `<div class="card-foot"><span>${trades.length} trades on the tape</span></div>`)
        : `<div class="empty">No trades yet.</div>`;
      host.querySelector("[data-more]")?.addEventListener("click", () => { shown += 20; paintTable(); });
    } else if (tab === "holders") {
      if (!holders.length) { host.innerHTML = `<div class="empty">No holders listed.</div>`; return; }
      const top = Math.max(...holders.map((h) => h.pct ?? 0), 0) || 1;
      host.innerHTML = `<table class="table table-compact"><thead><tr><th class="rank">#</th><th class="left">Wallet</th><th>Amount</th><th>Share</th></tr></thead><tbody>${holders.map((h, i) => `
        <tr>
          <td class="rank">${i + 1}</td>
          <td class="left">${person(h.address)}</td>
          <td class="num">${fmtAmount(h.amount)}</td>
          <td><span class="tk-share num">${fmtPct(h.pct == null ? null : h.pct / 100, { sign: false })}<i><b style="width:${Math.min(100, Math.max(0, ((h.pct ?? 0) / top) * 100))}%"></b></i></span></td>
        </tr>`).join("")}</tbody></table>`;
    } else if (tab === "traders") {
      const rows = traderRows();
      host.innerHTML = rows.length
        ? `<table class="table table-compact"><thead><tr><th>Wallet</th><th>Buys</th><th>Sells</th><th>Bought</th><th>Sold</th><th>Net</th><th>Last</th></tr></thead><tbody>${rows.map((r) => `
        <tr>
          <td>${person(r.address)}</td>
          <td class="num">${r.buys}</td>
          <td class="num">${r.sells}</td>
          <td class="num">${fmtUsd(r.bought, { compact: true })}</td>
          <td class="num">${fmtUsd(r.sold, { compact: true })}</td>
          <td class="num ${dirClass(r.bought - r.sold)}">${fmtUsd(r.bought - r.sold, { sign: true, compact: true })}</td>
          <td class="mono muted">${ago(r.last, { suffix: false })}</td>
        </tr>`).join("")}</tbody></table><div class="tk-foot">From the last ${trades.length} trades on the tape</div>`
        : `<div class="empty">No trades yet.</div>`;
    } else {
      paintEarly(host);
    }
    hydratePeople(host);
  };

  const prependTrades = (fresh) => {
    const tbody = q("#tk-table tbody");
    if (!tbody) return false;
    const head = [];
    for (const t of trades) { if (!fresh.has(tradeKey(t))) break; head.push(t); }
    if (head.length !== fresh.size) return false;
    tbody.insertAdjacentHTML("afterbegin", head.map((t) => tradeRow(t, true)).join(""));
    while (tbody.rows.length > Math.min(shown, trades.length)) tbody.lastElementChild.remove();
    hydratePeople(tbody);
    return true;
  };
  const refreshAgo = () => $$(".tk-ago", q("#tk-table")).forEach((td, i) => { if (trades[i]) td.textContent = ago(Number(trades[i].time), { suffix: false }); });
  const agoTimer = setInterval(refreshAgo, 1000);
  const hasTable = () => !!q("#tk-table table");

  const applyTrades = (incoming) => {
    const fresh = new Set(seenTrades.size ? incoming.map(tradeKey).filter((k) => !seenTrades.has(k)) : []);
    trades = incoming;
    seenTrades = new Set(incoming.map(tradeKey));
    paintCounts();
    if (tab === "trades") {
      if (!hasTable()) paintTable({ fresh });
      else if (fresh.size && !prependTrades(fresh)) paintTable({ fresh });
      refreshAgo();
    } else if (tab === "traders" && (fresh.size || !hasTable())) paintTable();
    paintActivity();
    buildFaces();
    learn(trades.slice(0, FACES_MAX).map((t) => t.userAddress), buildFaces);
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
      + `<div class="faint" style="font-size:11px">From the last ${trades.length || 100} trades</div>`;
  };

  const loadEarly = async (attempt = 0) => {
    if (String(chainIndex) !== "143") early = { status: "unsupported", data: null };
    else {
      const out = await api(`/api/token-details?view=early&chainIndex=${chainIndex}&address=${address}`, { signal }).catch(() => null);
      if (dead) return;
      const status = ["ready", "indexing", "unavailable", "unsupported"].includes(out?.status) ? out.status : "unavailable";
      early = { status, data: status === "ready" ? out : null };
      if (status === "indexing") {
        if (attempt < EARLY_RETRIES) earlyTimer = setTimeout(() => loadEarly(attempt + 1), 8000);
        else early.status = "stale";
      }
    }
    paintCounts();
    paintRisk();
    if (EARLY_TABS.includes(tab)) paintTable();
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
    candlesAt = 0;
    const mine = ++generation;
    chartEl.insertAdjacentHTML("beforeend", `<div class="empty pulse">Loading…</div>`);
    refresh(mine, true).catch(() => { if (mine === generation && !dead) { candles = []; paintChart(); } });
  });

  const refresh = async (mine, full) => {
    const out = await api(`/api/market-snapshot?chainIndex=${chainIndex}&address=${address}&period=${bar}&limit=100`, { signal });
    if (dead || mine !== generation) return;
    const next = parseCandles(out?.candles);
    if (full || !candles.length) { candles = next; candlesAt = Date.now(); paintChart(); }
    else if (chart && Date.now() - candlesAt >= 14_000) applyCandles(next);
    applyTrades(out?.trades ?? []);
  };

  const tickPrices = async () => {
    const out = await api(`/api/token-details?view=prices&tokens=${key}`, { signal });
    const tick = (out?.prices ?? []).find((p) => String(p.contract ?? "").toLowerCase() === address.toLowerCase()) ?? out?.prices?.[0];
    if (dead || !tick || !(tick.price > 0)) return;
    const was = price;
    price = tick.price;
    flash(q("#tk-price"), tokenPrice(price), was == null ? 0 : Math.sign(price - was));
    if (tick.change24h != null) { const c = q("#tk-change"); c.textContent = fmtPct(tick.change24h / 100); c.className = dirClass(tick.change24h); }
    if (tick.marketCap != null) q("#tk-mcap").textContent = fmtUsd(tick.marketCap, { compact: true });
    if (tick.liquidity != null) q("#tk-liq").textContent = fmtUsd(tick.liquidity, { compact: true });
    if (tick.volume24H != null) q("#tk-vol").textContent = fmtUsd(tick.volume24H, { compact: true });
    if (tick.holders > 0) q("#tk-holders").textContent = fmtCompact(tick.holders);
    liveCandle(price, ms(tick.time) ?? ms(out?.observedAt) ?? Date.now());
    paintEstimate();
  };

  if (tab === "holders" || EARLY_TABS.includes(tab)) paintTable();
  paintCounts();
  loadEarly();
  stopSnapshot = poll(() => refresh(generation, false), 5_000);
  stopPrices = poll(tickPrices, 4_000);

  function cleanup() {
    clearInterval(agoTimer);
    countdown?.remove();
    document.removeEventListener("wallet", onWallet);
    if (stopSession) stopSession();
    clearTimeout(quoteTimer);
    if (onKey) document.removeEventListener("keydown", onKey);
    if (onFullscreen) document.removeEventListener("fullscreenchange", onFullscreen);
    document.body.classList.remove("focus");
    if (document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
    dead = true;
    aborter.abort();
    if (stopSnapshot) stopSnapshot();
    if (stopPrices) stopPrices();
    clearTimeout(earlyTimer);
    if (observer) observer.disconnect();
    if (chart) { chart.remove(); chart = null; }
  }
  return cleanup;
}
