import { $, $$, esc, api, poll, fmtUsd, fmtPrice, fmtPct, fmtAmount, short, dirClass, logo, navigate, MARKET_LOGOS } from "../app.js";

const STYLE = `<style>
.mk { display: grid; grid-template-columns: minmax(0, 1fr) 300px; gap: 20px; align-items: start; }
@media (max-width: 1100px) { .mk { grid-template-columns: minmax(0, 1fr); } }
.mk-head { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; margin-bottom: 14px; }
.mk-lev { display: inline-flex; align-items: center; height: 18px; padding: 0 6px; border-radius: 6px; font-size: 10px; font-weight: 700; font-style: normal; width: max-content; }
.mk .spark { margin-left: auto; }
.mk .table th.mk-trade, .mk .table td.mk-trade { width: 1%; padding-right: 16px; }
.mk-rail { display: grid; gap: 16px; }
.mk-live { display: inline-flex; align-items: center; gap: 7px; font-size: 11px; font-weight: 700; letter-spacing: 0.04em; color: var(--text-2); }
.mk-sig { display: flex; align-items: center; gap: 10px; padding: 10px 16px; border-bottom: 1px solid var(--line); }
.mk-sig:last-child { border-bottom: 0; }
.mk-sig:hover { background: rgba(255, 255, 255, 0.025); }
.mk-sig .body { flex: 1; min-width: 0; display: grid; gap: 2px; }
.mk-sig .body b { font-size: 13px; display: flex; align-items: center; gap: 6px; }
.mk-sig .body small { font-size: 11px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.mk-sig .amt { font-size: 13px; font-weight: 700; }
.mk-crowd { display: grid; gap: 6px; padding: 10px 16px; border-bottom: 1px solid var(--line); }
.mk-crowd:last-child { border-bottom: 0; }
.mk-crowd:hover { background: rgba(255, 255, 255, 0.025); }
.mk-crowd .row-between { font-size: 13px; }
.mk-crowd small { font-size: 11px; color: var(--muted); }
.mk-crowd .bar { background: var(--fall); }

.mk-filter { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 12px; }
.mk-search { width: 360px; max-width: 100%; height: 38px; padding: 0 12px; border-radius: 11px; background: #0d0d0d; border-color: #1f1f1f; }
.mk-search:hover { border-color: #2a2a2a; }
.mk-search svg { width: 18px; height: 18px; color: var(--muted); flex: none; }
.mk-search input { font-size: 14px; }
.mk-view button { display: inline-flex; align-items: center; gap: 6px; }
.mk-view svg { width: 14px; height: 14px; }
.mk-filter-right { margin-left: auto; position: relative; }
.mk-filter-right .btn svg { width: 15px; height: 15px; }
.mk-filter-right .btn i { display: inline-flex; align-items: center; justify-content: center; min-width: 18px; height: 18px; padding: 0 5px; border-radius: 999px; background: var(--text); color: #000; font-size: 10px; font-style: normal; }
.mk-pop { position: absolute; right: 0; top: calc(100% + 8px); z-index: 20; width: 340px; padding: 14px; display: grid; gap: 14px; background: #121212; border-color: var(--line-strong); box-shadow: 0 20px 60px rgba(0, 0, 0, 0.55); animation: sheetIn 0.18s var(--ease); }
.mk-pop .eyebrow { margin-bottom: 7px; }
.mk-opts { display: flex; flex-wrap: wrap; gap: 6px; }
.mk-chips { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-bottom: 14px; }
.mk-chips:empty { display: none; }
.mk-chips .chip button { display: inline-flex; color: var(--muted); font-size: 15px; line-height: 1; margin: 0 -3px 0 1px; }
.mk-chips .chip button:hover { color: var(--text); }
.mk-clear { font-size: 12px; font-weight: 600; color: var(--muted); padding: 0 4px; }
.mk-clear:hover { color: var(--text); }
.mk-src { padding: 10px 16px; font-size: 11px; color: var(--muted); border-top: 1px solid var(--line); }

.mk-spark path { fill: none; stroke-width: 1.5; }
.mk-spark .fill { stroke: none; opacity: 1; }
.mk-spark[data-dir="up"] .line { stroke: var(--rise); }
.mk-spark[data-dir="down"] .line { stroke: var(--fall); }
.mk-spark[data-dir="up"] .fill { fill: url(#mk-gu); }
.mk-spark[data-dir="down"] .fill { fill: url(#mk-gd); }
.mk-spark[data-dir="up"] circle { fill: var(--rise); }
.mk-spark[data-dir="down"] circle { fill: var(--fall); }
.mk-spark:not([data-dir="up"]):not([data-dir="down"]) > * { display: none; }
.mk-spark .pt { r: 2.5; }
.mk-spark .halo { r: 5; opacity: 0.35; transform-box: fill-box; transform-origin: center; animation: mk-pulse 1.6s ease-out infinite; }
@keyframes mk-pulse { from { transform: scale(1); opacity: 0.5; } to { transform: scale(1.8); opacity: 0; } }

.mk-foot { gap: 14px; flex-wrap: wrap; }
.mk-foot .seg button:disabled { opacity: 0.35; cursor: default; }
.mk-lean { display: flex; align-items: center; justify-content: center; gap: 10px; flex: 1; min-width: 240px; font-size: 11px; font-weight: 700; }
.mk-lean .bar { width: 180px; height: 5px; }
.mk-stats { white-space: nowrap; font-weight: 600; }
.mk-stats b { color: var(--text-2); font-weight: 700; }

.mk-bubbles { position: relative; min-height: 520px; overflow: hidden; }
.mk-bubbles svg { display: block; width: 100%; }
.mk-bubble { cursor: pointer; transform-box: fill-box; transform-origin: center; animation: mk-pop 0.3s var(--ease) both; }
.mk-bubble circle { transform-box: fill-box; transform-origin: center; transition: transform 0.15s var(--ease); }
.mk-bubble:hover circle { transform: scale(1.06); }
.mk-bubble text { pointer-events: none; text-anchor: middle; font-family: var(--rounded); font-weight: 800; fill: #fff; letter-spacing: -0.01em; }
.mk-bubble .pct { font-weight: 700; opacity: 0.85; font-variant-numeric: tabular-nums; }
@keyframes mk-pop { from { transform: scale(0); opacity: 0; } }
.mk-tip { position: absolute; z-index: 5; pointer-events: none; padding: 10px 12px; display: grid; gap: 6px; min-width: 210px; background: #141414; border-color: var(--line-strong); box-shadow: 0 12px 40px rgba(0, 0, 0, 0.5); font-size: 12px; }
.mk-tip .row b { font-size: 13px; }
.mk-tip .row small { color: var(--muted); }
.mk-tip .row-between { font-size: 12px; color: var(--muted); }
.mk-tip .row-between .num { color: var(--text); font-weight: 600; }
</style>`;

const DEFS = `<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
  <linearGradient id="mk-gu" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2fd67b" stop-opacity=".38"/><stop offset="1" stop-color="#2fd67b" stop-opacity="0"/></linearGradient>
  <linearGradient id="mk-gd" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff5c5c" stop-opacity=".38"/><stop offset="1" stop-color="#ff5c5c" stop-opacity="0"/></linearGradient>
</defs></svg>`;
const ICON_LIST = `<svg viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" d="M4 7h16M4 12h16M4 17h16"/></svg>`;
const ICON_BUBBLES = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="9" cy="10" r="5.5"/><circle cx="17.5" cy="6.5" r="2.5"/><circle cx="16.5" cy="17" r="3.5"/></svg>`;
const ICON_FILTER = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h9M19 7h1M4 17h3M13 17h7"/><circle cx="16" cy="7" r="2.5"/><circle cx="10" cy="17" r="2.5"/></svg>`;

const TABS = [["perps", "Perps"], ["trending", "Trending"], ["movers", "Movers"], ["monad", "Monad"]];
const SKELETON = `<div class="skel-row"><div class="skel"></div><div class="skel"></div><div class="skel"></div><div class="skel"></div></div>`.repeat(6);
const LIQ = [[0, "Any"], [1e4, "> $10K"], [1e5, "> $100K"], [5e5, "> $500K"], [1e6, "> $1M"]];
const CHAINS = [["", "Any"], ["143", "Monad"], ["501", "Solana"], ["1", "Ethereum"], ["8453", "Base"], ["56", "BNB"]];
const RISKS = [["any", "Any"], ["low", "Low only"], ["nohigh", "Hide high"]];
const PERIODS = ["5m", "1h", "24h"];
const FILTER_KEY = "desk.web.mkfilters";
const RGB = { up: "47,214,123", down: "255,92,92" };
const TICKS = 60;

const perpBuf = new Map();
const spotBuf = new Map();
const seeded = new Set();

function push(map, key, value) {
  if (!Number.isFinite(value)) return;
  const buf = map.get(key) ?? [];
  buf.push(value);
  if (buf.length > TICKS) buf.splice(0, buf.length - TICKS);
  map.set(key, buf);
}
function seed(map, key, closes) {
  map.set(key, [...closes.filter(Number.isFinite), ...(map.get(key) ?? [])].slice(-TICKS));
}

function loadFilters() {
  try {
    const f = JSON.parse(localStorage.getItem(FILTER_KEY) ?? "{}");
    return { liq: LIQ.some(([v]) => v === Number(f.liq)) ? Number(f.liq) : 0, chain: CHAINS.some(([v]) => v === String(f.chain ?? "")) ? String(f.chain ?? "") : "", risk: RISKS.some(([v]) => v === f.risk) ? f.risk : "any" };
  } catch { return { liq: 0, chain: "", risk: "any" }; }
}
function saveFilters(f) {
  try { localStorage.setItem(FILTER_KEY, JSON.stringify(f)); } catch {}
}

/// Runs jobs `limit` at a time so a page of sparkline seeds does not burst the API.
function queue(limit) {
  let active = 0;
  const waiting = [];
  const next = () => {
    if (active >= limit || !waiting.length) return;
    active += 1;
    const { job, resolve } = waiting.shift();
    job().catch(() => null).then((value) => { active -= 1; resolve(value); next(); });
  };
  return (job) => new Promise((resolve) => { waiting.push({ job, resolve }); next(); });
}

function riskLevel(t) {
  const flag = String(t.riskLevel ?? "").toLowerCase();
  const checked = t.riskLevel != null || t.liquidity != null || t.communityRecognized != null;
  let weight = 0;
  if (flag === "high" || Number(flag) >= 3) weight += 6;
  else if (flag === "medium" || Number(flag) === 2) weight += 3;
  if (t.liquidity != null) weight += t.liquidity < 10_000 ? 6 : t.liquidity < 50_000 ? 3 : 0;
  if (t.communityRecognized === false) weight += 1;
  return !checked ? "unchecked" : weight >= 6 ? "high" : weight >= 3 ? "caution" : "low";
}
function risk(t) {
  const level = riskLevel(t);
  const label = { low: "Low risk", caution: "Caution", high: "High risk", unchecked: "Not checked" }[level];
  return `<span class="risk ${level}"><i></i>${label}</span>`;
}

const interval = (sec) => (sec >= 3600 ? `${Math.round(sec / 3600)}h` : `${Math.round(sec / 60)}m`);
const frac = (pct) => (pct == null || !Number.isFinite(Number(pct)) ? null : Number(pct) / 100);
const changeOf = (t, period) => (period === "24h" ? (t.change24h ?? t.change) : (t[`change${period}`] ?? null));
const liveSvg = (key) => `<svg class="spark mk-spark" viewBox="0 0 96 28" data-live="${esc(key)}" aria-hidden="true"><path class="fill"/><path class="line"/><circle class="halo"/><circle class="pt"/></svg>`;

function drawLive(svg, values) {
  const pts = (values ?? []).slice(-TICKS);
  if (!svg || pts.length < 2) { if (svg) svg.dataset.dir = ""; return; }
  const min = Math.min(...pts);
  const max = Math.max(...pts);
  const span = max - min;
  const step = 86 / (pts.length - 1);
  const coords = pts.map((v, i) => [3 + i * step, 3 + 22 * (1 - (span ? (v - min) / span : 0.5))]);
  const d = coords.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const [lx, ly] = coords[coords.length - 1];
  svg.querySelector(".line").setAttribute("d", d);
  svg.querySelector(".fill").setAttribute("d", `${d} L${lx.toFixed(1)},28 L3,28 Z`);
  for (const c of svg.querySelectorAll("circle")) { c.setAttribute("cx", lx.toFixed(1)); c.setAttribute("cy", ly.toFixed(1)); }
  svg.dataset.dir = pts[pts.length - 1] >= pts[0] ? "up" : "down";
}

function setCell(cell, text, delta) {
  if (!cell || cell.textContent === text) return;
  cell.textContent = text;
  if (!delta) return;
  cell.classList.remove("flash-up", "flash-down");
  void cell.offsetWidth;
  cell.classList.add(delta > 0 ? "flash-up" : "flash-down");
}
function setChange(cell, fraction) {
  if (!cell) return;
  cell.textContent = fmtPct(fraction);
  cell.className = `num ${dirClass(fraction)}`;
}

function perpRow(m, i) {
  return `<tr class="link" data-href="/app/trade/${esc(m.name)}" data-id="${esc(m.name)}">
    <td class="rank">${i + 1}</td>
    <td class="left"><div class="token">${logo(MARKET_LOGOS[m.name], m.name, 32)}
      <div class="name"><b>${esc(m.name)} <small>${esc(m.name)}-PERP</small></b><i class="chip-brand mk-lev">up to ${esc(m.maxLeverage)}×</i></div></div></td>
    <td class="num" data-c="mark">${fmtPrice(m.mark, m.priceDecimals)}</td>
    <td>${liveSvg(m.name)}</td>
    <td class="num ${dirClass(m.change)}" data-c="chg">${fmtPct(m.change)}</td>
    <td class="num" data-c="vol">${fmtUsd(m.volume24h, { compact: true })}</td>
    <td class="num" data-c="oi">${fmtUsd(m.openInterest, { compact: true })}</td>
    <td class="num"><span class="${m.fundingRate > 0 ? "up" : m.fundingRate < 0 ? "down" : ""}">${fmtPct(m.fundingRate, { digits: 4 })}</span><small class="muted"> / ${interval(m.fundingIntervalSec)}</small></td>
    <td class="num">${fmtUsd(m.tvl, { compact: true })}</td>
    <td class="mk-trade"><a class="btn btn-primary btn-xs" href="/app/trade/${esc(m.name)}" data-link>Trade</a></td>
  </tr>`;
}

function tokenRow(t, i, period) {
  const change = frac(changeOf(t, period));
  return `<tr class="link" data-href="/app/token/${esc(t.chainIndex)}/${esc(t.contract)}" data-id="${esc(t.id)}">
    <td class="rank">${i + 1}</td>
    <td class="left"><div class="token">${logo(t.logoURL, t.symbol, 32)}
      <div class="name"><b>${esc(t.symbol)} <small>${esc(t.name)}</small></b><span>${esc(t.chainName)} · ${esc(short(t.contract))}</span></div></div></td>
    <td class="num" data-c="price">${fmtUsd(t.price)}</td>
    <td>${liveSvg(t.id)}</td>
    <td class="num" data-c="mcap">${fmtUsd(t.marketCap, { compact: true })}</td>
    <td class="num" data-c="liq">${fmtUsd(t.liquidity, { compact: true })}</td>
    <td class="num" data-c="vol">${fmtUsd(t.volume24H, { compact: true })}</td>
    <td class="num ${dirClass(change)}" data-c="chg">${fmtPct(change)}</td>
    <td class="num" data-c="holders">${fmtAmount(t.holders, 0)}</td>
    <td>${risk(t)}</td>
    <td class="mk-trade"><a class="btn btn-primary btn-xs" href="/app/token/${esc(t.chainIndex)}/${esc(t.contract)}" data-link>Trade</a></td>
  </tr>`;
}

const PERP_HEAD = `<tr><th>#</th><th class="left">Market</th><th>Mark</th><th>Live 10s</th><th data-c="chgh">24h</th><th>Volume</th><th>Open int.</th><th>Funding</th><th>TVL</th><th class="mk-trade"></th></tr>`;
const tokenHead = (period) => `<tr><th>#</th><th class="left">Token</th><th>Price</th><th>Live 10s</th><th>MCap</th><th>Liquidity</th><th>Volume</th><th data-c="chgh">${period}</th><th>Holders</th><th>Risk</th><th class="mk-trade"></th></tr>`;

function bubbleFill(change) {
  const c = Number(change) || 0;
  const a = 0.25 + (0.65 * Math.min(Math.abs(c), 0.3)) / 0.3;
  const rgb = c >= 0 ? RGB.up : RGB.down;
  return [`rgba(${rgb},${a.toFixed(2)})`, `rgba(${rgb},${Math.min(1, a + 0.25).toFixed(2)})`];
}

/// Largest first at the centre, then each next circle walks a spiral out until it touches nothing.
function pack(items, W, H) {
  const nodes = items.filter((n) => n.size > 0).sort((a, b) => b.size - a.size);
  if (!nodes.length) return [];
  const total = nodes.reduce((s, n) => s + n.size, 0);
  const k = Math.sqrt((0.6 * W * H) / (Math.PI * total));
  const aspect = W / H;
  const placed = [];
  for (const n of nodes) {
    n.r = Math.max(6, Math.sqrt(n.size) * k);
    if (!placed.length) { n.x = 0; n.y = 0; placed.push(n); continue; }
    let theta = 0;
    for (;;) {
      theta += 0.1;
      const rho = theta * 1.1;
      const x = rho * Math.cos(theta) * aspect;
      const y = rho * Math.sin(theta);
      if (theta > 6000 || placed.every((p) => Math.hypot(p.x - x, p.y - y) >= p.r + n.r + 3)) { n.x = x; n.y = y; break; }
    }
    placed.push(n);
  }
  const x0 = Math.min(...placed.map((n) => n.x - n.r));
  const x1 = Math.max(...placed.map((n) => n.x + n.r));
  const y0 = Math.min(...placed.map((n) => n.y - n.r));
  const y1 = Math.max(...placed.map((n) => n.y + n.r));
  const s = Math.min(W / (x1 - x0 + 24), H / (y1 - y0 + 24));
  const ox = (W - (x1 - x0) * s) / 2 - x0 * s;
  const oy = (H - (y1 - y0) * s) / 2 - y0 * s;
  for (const n of placed) { n.x = n.x * s + ox; n.y = n.y * s + oy; n.r *= s; }
  return placed;
}

function bubbleG(n, i) {
  const [fill, stroke] = bubbleFill(n.change);
  const fs = Math.max(9, Math.min(n.r * 0.42, (2.4 * n.r) / Math.max(2, n.label.length)));
  const label = n.r >= 18 ? `<text x="${n.x.toFixed(1)}" y="${(n.y - fs * 0.12).toFixed(1)}" font-size="${fs.toFixed(1)}">${esc(n.label)}</text>
    <text class="pct" x="${n.x.toFixed(1)}" y="${(n.y + fs * 0.92).toFixed(1)}" font-size="${(fs * 0.72).toFixed(1)}" data-bpct>${fmtPct(n.change)}</text>` : "";
  return `<g class="mk-bubble" data-bid="${esc(n.key)}" data-href="${esc(n.href)}" style="animation-delay:${Math.min(i * 14, 420)}ms">
    <circle cx="${n.x.toFixed(1)}" cy="${n.y.toFixed(1)}" r="${n.r.toFixed(1)}" fill="${fill}" stroke="${stroke}" stroke-width="1"/>${label}</g>`;
}

export default async function mount(el, params) {
  let dead = false;
  let tab = TABS.some(([id]) => id === params.query?.tab) ? params.query.tab : "perps";
  let view = "list";
  let period = "24h";
  let query = "";
  let remote = null;
  let perps = [];
  let tokens = [];
  let tokensAt = null;
  let perpsAt = null;
  let pricesAt = null;
  let crowdRows = [];
  let paintedKey = "";
  let bubbleData = new Map();
  const filters = loadFilters();
  const run = queue(3);

  el.innerHTML = `${STYLE}${DEFS}
  <div class="mk-head">
    <h1>Markets</h1>
    <div class="seg" id="mk-tabs" role="tablist">${TABS.map(([id, label]) => `<button role="tab" data-tab="${id}" aria-selected="${id === tab}">${label}</button>`).join("")}</div>
  </div>
  <div class="mk-filter">
    <label class="field mk-search"><svg><use href="#i-search"/></svg><input id="mk-q" type="search" placeholder="Search token or mint" autocomplete="off" spellcheck="false"></label>
    <div class="seg mk-view" id="mk-view"><button data-view="list" aria-selected="true">${ICON_LIST}List</button><button data-view="bubbles" aria-selected="false">${ICON_BUBBLES}Bubbles</button></div>
    <div class="mk-filter-right">
      <button class="btn btn-line btn-sm" id="mk-filters" aria-expanded="false">${ICON_FILTER}Filters<i id="mk-fcount" hidden></i></button>
      <div class="card mk-pop" id="mk-pop" hidden></div>
    </div>
  </div>
  <div class="mk-chips" id="mk-chips"></div>
  <div class="mk">
    <div class="card">
      <div id="mk-body">${SKELETON}</div>
      <div class="card-foot mk-foot">
        <div class="seg seg-sm" id="mk-period">${PERIODS.map((p) => `<button data-p="${p}" aria-selected="${p === period}" ${p === "24h" ? "" : "disabled"}>${p}</button>`).join("")}</div>
        <div class="mk-lean" id="mk-lean"></div>
        <div class="mk-stats num" id="mk-stats">Loading</div>
      </div>
    </div>
    <div class="mk-rail">
      <div class="card">
        <div class="card-head"><h3>Signals</h3><span class="mk-live"><i class="dot" id="mk-sig-dot"></i>LIVE</span></div>
        <div id="mk-signals">${SKELETON.slice(0, SKELETON.length / 2)}</div>
      </div>
      <div class="card">
        <div class="card-head"><h3>Crowd</h3><span class="eyebrow">Perpl</span></div>
        <div id="mk-crowd"></div>
      </div>
    </div>
  </div>`;

  const body = $("#mk-body", el);
  const pop = $("#mk-pop", el);
  const filtersBtn = $("#mk-filters", el);
  const input = $("#mk-q", el);
  const rowEl = (id) => body.querySelector(`[data-id="${CSS.escape(id)}"]`);
  const liveEl = (id) => body.querySelector(`[data-live="${CSS.escape(id)}"]`);
  const cell = (row, c) => row?.querySelector(`[data-c="${c}"]`);

  // ── Tabs, view, period ─────────────────────────────────

  $("#mk-tabs", el).addEventListener("click", (event) => {
    const button = event.target.closest("[data-tab]");
    if (!button || button.dataset.tab === tab) return;
    tab = button.dataset.tab;
    for (const b of $$("[data-tab]", el)) b.setAttribute("aria-selected", String(b.dataset.tab === tab));
    history.replaceState({}, "", tab === "perps" ? "/app/markets" : `/app/markets?tab=${tab}`);
    remote = null;
    if (query) lookupRemote(query);
    paintChips();
    paintPeriods();
    paint();
  });

  $("#mk-view", el).addEventListener("click", (event) => {
    const button = event.target.closest("[data-view]");
    if (!button || button.dataset.view === view) return;
    view = button.dataset.view;
    for (const b of $$("[data-view]", el)) b.setAttribute("aria-selected", String(b.dataset.view === view));
    paint();
  });

  $("#mk-period", el).addEventListener("click", (event) => {
    const button = event.target.closest("[data-p]");
    if (!button || button.disabled || button.dataset.p === period) return;
    period = button.dataset.p;
    paintPeriods();
    if (tab === "perps") return;
    if (view === "bubbles") { paint(); return; }
    const head = body.querySelector('[data-c="chgh"]');
    if (head) head.textContent = period;
    for (const t of visibleTokens()) setChange(cell(rowEl(t.id), "chg"), frac(changeOf(t, period)));
  });

  function paintPeriods() {
    for (const b of $$("[data-p]", el)) {
      b.disabled = b.dataset.p !== "24h" && (tab === "perps" || !pricesAt);
      b.setAttribute("aria-selected", String(b.dataset.p === (tab === "perps" ? "24h" : period)));
    }
  }

  // ── Search ─────────────────────────────────────────────

  let localTimer = null;
  let remoteTimer = null;
  let searchSeq = 0;
  input.addEventListener("input", () => {
    clearTimeout(localTimer);
    clearTimeout(remoteTimer);
    const q = input.value.trim();
    localTimer = setTimeout(() => { query = q; remote = null; paint(); }, 120);
    remoteTimer = setTimeout(() => { if (q && tab !== "perps" && !localHits(q).length) lookupRemote(q); }, 400);
  });

  const matches = (t, q) => [t.symbol, t.name, t.contract].some((v) => String(v ?? "").toLowerCase().includes(q));
  const localHits = (q) => (tokens ?? []).filter((t) => matches(t, q.toLowerCase()));

  async function lookupRemote(q) {
    const mine = ++searchSeq;
    remote = { q, rows: [], loading: true };
    paint();
    const out = await api(`/api/token-discovery?q=${encodeURIComponent(q)}`, { ttl: 30_000 }).catch(() => null);
    if (dead || mine !== searchSeq || query !== q) return;
    remote = { q, rows: out?.tokens ?? [], loading: false };
    paint();
  }

  // ── Filters ────────────────────────────────────────────

  filtersBtn.addEventListener("click", () => togglePop(pop.hidden));
  pop.addEventListener("click", (event) => {
    const button = event.target.closest("[data-f]");
    if (!button) return;
    const { f, v } = button.dataset;
    filters[f] = f === "liq" ? Number(v) : v;
    saveFilters(filters);
    paintPop();
    paintChips();
    paint();
  });
  $("#mk-chips", el).addEventListener("click", (event) => {
    const button = event.target.closest("[data-clear]");
    if (!button) return;
    const which = button.dataset.clear;
    if (which === "all" || which === "liq") filters.liq = 0;
    if (which === "all" || which === "chain") filters.chain = "";
    if (which === "all" || which === "risk") filters.risk = "any";
    saveFilters(filters);
    paintPop();
    paintChips();
    paint();
  });
  const onDocClick = (event) => { if (!pop.hidden && !event.target.closest(".mk-filter-right")) togglePop(false); };
  const onKey = (event) => { if (event.key === "Escape" && !pop.hidden) togglePop(false); };
  document.addEventListener("click", onDocClick);
  document.addEventListener("keydown", onKey);

  function togglePop(open) {
    pop.hidden = !open;
    filtersBtn.setAttribute("aria-expanded", String(open));
    if (open) paintPop();
  }

  function paintPop() {
    if (!pop.firstChild) {
      pop.innerHTML = [["liq", "Liquidity", LIQ], ["chain", "Chain", CHAINS], ["risk", "Risk", RISKS]]
        .map(([f, title, opts]) => `<div><div class="eyebrow">${title}</div><div class="mk-opts">${opts.map(([v, label]) => `<button class="chip" data-f="${f}" data-v="${esc(v)}">${esc(label)}</button>`).join("")}</div></div>`)
        .join("");
    }
    for (const b of $$("[data-f]", pop)) b.setAttribute("aria-pressed", String(b.dataset.v === String(filters[b.dataset.f])));
  }

  const activeFilters = () => [
    filters.liq ? ["liq", `Liquidity: ${LIQ.find(([v]) => v === filters.liq)[1]}`] : null,
    filters.chain ? ["chain", `Chain: ${CHAINS.find(([v]) => v === filters.chain)[1]}`] : null,
    filters.risk !== "any" ? ["risk", `Risk: ${RISKS.find(([v]) => v === filters.risk)[1]}`] : null,
  ].filter(Boolean);

  function paintChips() {
    const chips = tab === "perps" ? [] : activeFilters();
    $("#mk-chips", el).innerHTML = chips.length
      ? chips.map(([f, label]) => `<span class="chip" aria-pressed="true">${esc(label)}<button data-clear="${f}" aria-label="Remove">×</button></span>`).join("") + `<button class="mk-clear" data-clear="all">Clear all</button>`
      : "";
    const count = $("#mk-fcount", el);
    count.hidden = !chips.length;
    count.textContent = chips.length;
  }

  function passes(t) {
    if (filters.liq && !((t.liquidity ?? 0) >= filters.liq)) return false;
    if (filters.chain && String(t.chainIndex) !== filters.chain) return false;
    if (filters.risk === "low" && riskLevel(t) !== "low") return false;
    if (filters.risk === "nohigh" && riskLevel(t) === "high") return false;
    return true;
  }

  // ── Rows ───────────────────────────────────────────────

  body.addEventListener("click", (event) => {
    if (event.target.closest("a, button")) return;
    const row = event.target.closest("[data-href]");
    if (row) navigate(row.dataset.href);
  });

  const table = (head, rows) => `<div class="table-wrap"><table class="table"><thead>${head}</thead><tbody>${rows}</tbody></table></div>`;

  function visiblePerps() {
    const q = query.toLowerCase();
    return q ? (perps ?? []).filter((m) => m.name.toLowerCase().includes(q)) : (perps ?? []);
  }

  function visibleTokens() {
    let rows = remote ? remote.rows : (tokens ?? []);
    if (!remote) {
      if (tab === "movers") rows = [...rows].sort((a, b) => Math.abs(changeOf(b, period) ?? 0) - Math.abs(changeOf(a, period) ?? 0));
      if (tab === "monad") rows = rows.filter((t) => String(t.chainIndex) === "143");
      if (query) rows = rows.filter((t) => matches(t, query.toLowerCase()));
    }
    return rows.filter(passes);
  }

  function paint() {
    if (dead) return;
    let rows = [];
    if (tab === "perps") {
      if (perps === null) body.innerHTML = `<div class="empty">Markets could not be read right now.</div>`;
      else if (!perpsAt) body.innerHTML = SKELETON;
      else if (!(rows = visiblePerps()).length) body.innerHTML = `<div class="empty">No market called “${esc(query)}”.</div>`;
      else if (view === "bubbles") paintBubbles(rows);
      else body.innerHTML = table(PERP_HEAD, rows.map(perpRow).join(""));
      paintedKey = rows.map((m) => m.name).join();
    } else {
      if (tokens === null) body.innerHTML = `<div class="empty">Trending could not be read right now.</div>`;
      else if (!tokensAt) body.innerHTML = SKELETON;
      else if (!(rows = visibleTokens()).length) {
        body.innerHTML = `<div class="empty">${remote?.loading ? "Searching OKX…" : query ? "Nothing by that name on any chain." : activeFilters().length ? "Nothing matches these filters." : "Nothing trending on Monad in this window."}</div>`;
      } else if (view === "bubbles") paintBubbles(rows);
      else body.innerHTML = table(tokenHead(period), rows.map((t, i) => tokenRow(t, i, period)).join("")) + (remote ? `<div class="mk-src">Search results · OKX</div>` : "");
      paintedKey = rows.map((t) => t.id).join();
    }
    for (const svg of $$("[data-live]", body)) hydrateLive(svg.dataset.live);
    paintFoot();
  }

  function hydrateLive(key) {
    const buf = key.includes(":") ? spotBuf : perpBuf;
    drawLive(liveEl(key), buf.get(key));
    if (seeded.has(key)) return;
    seeded.add(key);
    run(() => loadSeed(key)).then((closes) => {
      if (dead || !closes?.length) return;
      seed(buf, key, closes);
      drawLive(liveEl(key), buf.get(key));
    });
  }

  async function loadSeed(key) {
    if (dead) return null;
    if (key.includes(":")) {
      const [chainIndex, address] = key.split(":");
      const out = await api(`/api/market-snapshot?chainIndex=${encodeURIComponent(chainIndex)}&address=${encodeURIComponent(address)}&period=1m`, { ttl: 60_000 }).catch(() => null);
      return (out?.candles ?? []).map((row) => Number(row[4])).reverse().slice(-30);
    }
    const out = await api(`/api/v1/markets/${encodeURIComponent(key)}/candles?bar=1m`, { ttl: 60_000 }).catch(() => null);
    return (out?.candles ?? []).map((c) => Number(c.close)).slice(-30);
  }

  // ── Bubbles ────────────────────────────────────────────

  function bubbleItems(rows) {
    if (tab === "perps") return rows.map((m) => ({ key: m.name, href: `/app/trade/${m.name}`, size: m.openInterest || m.volume24h || 0, change: m.change ?? 0, label: m.name, name: `${m.name}-PERP`, logo: MARKET_LOGOS[m.name], price: fmtPrice(m.mark, m.priceDecimals), cap: fmtUsd(m.openInterest, { compact: true }), capLabel: "Open interest", chgLabel: "24h" }));
    return rows.map((t) => ({ key: t.id, href: `/app/token/${t.chainIndex}/${t.contract}`, size: t.marketCap || t.volume24H || 0, change: frac(changeOf(t, period)) ?? 0, label: t.symbol ?? "?", name: t.name ?? "", logo: t.logoURL, price: fmtUsd(t.price), cap: fmtUsd(t.marketCap, { compact: true }), capLabel: "MCap", chgLabel: period }));
  }

  function paintBubbles(rows) {
    const W = body.clientWidth || 900;
    const H = Math.max(520, Math.round(W * 0.52));
    const nodes = pack(bubbleItems(rows), W, H);
    bubbleData = new Map(nodes.map((n) => [n.key, n]));
    body.innerHTML = `<div class="mk-bubbles" style="height:${H}px"><svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${nodes.map(bubbleG).join("")}</svg><div class="card mk-tip" id="mk-tip" hidden></div></div>`;
  }

  function bubbleTick(key, change) {
    const g = body.querySelector(`[data-bid="${CSS.escape(key)}"]`);
    const n = bubbleData.get(key);
    if (!g || !n) return;
    n.change = change ?? 0;
    const [fill, stroke] = bubbleFill(n.change);
    const circle = g.querySelector("circle");
    circle.setAttribute("fill", fill);
    circle.setAttribute("stroke", stroke);
    const pct = g.querySelector("[data-bpct]");
    if (pct) pct.textContent = fmtPct(n.change);
  }

  let hovered = null;
  body.addEventListener("mouseover", (event) => {
    const g = event.target.closest(".mk-bubble");
    if (!g || g === hovered) return;
    hovered = g;
    g.style.animation = "none";
    g.parentNode.appendChild(g);
    const n = bubbleData.get(g.dataset.bid);
    const tip = $("#mk-tip", body);
    if (!n || !tip) return;
    tip.innerHTML = `<div class="row">${logo(n.logo, n.label, 24)}<b>${esc(n.label)}</b><small>· ${esc(n.name)}</small></div>
      <div class="row-between"><span>Price</span><span class="num">${n.price}</span></div>
      <div class="row-between"><span>${n.capLabel}</span><span class="num">${n.cap}</span></div>
      <div class="row-between"><span>${esc(n.chgLabel)}</span><span class="num ${dirClass(n.change)}">${fmtPct(n.change)}</span></div>`;
    tip.hidden = false;
  });
  body.addEventListener("mousemove", (event) => {
    const tip = $("#mk-tip", body);
    const wrap = tip?.parentNode;
    if (!tip || tip.hidden || !wrap) return;
    const rect = wrap.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;
    tip.style.left = `${x + 230 > rect.width ? x - 230 : x + 16}px`;
    tip.style.top = `${y + 120 > rect.height ? y - 110 : y + 16}px`;
  });
  body.addEventListener("mouseout", (event) => {
    if (!hovered || event.relatedTarget?.closest?.(".mk-bubble") === hovered) return;
    hovered = null;
    const tip = $("#mk-tip", body);
    if (tip) tip.hidden = true;
  });

  let resizeTimer = null;
  const onResize = () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { if (view === "bubbles") paint(); }, 150); };
  window.addEventListener("resize", onResize);

  // ── Footer ─────────────────────────────────────────────

  function paintFoot() {
    const lean = $("#mk-lean", el);
    const long = crowdRows.reduce((s, m) => s + (m.longTraders ?? 0), 0);
    const short = crowdRows.reduce((s, m) => s + (m.shortTraders ?? 0), 0);
    if (long + short > 0) {
      const pct = (long / (long + short)) * 100;
      lean.innerHTML = `<span class="up">Long ${pct.toFixed(0)}%</span><div class="bar"><i style="width:${pct.toFixed(1)}%"></i></div><span class="down">Short ${(100 - pct).toFixed(0)}%</span>`;
    }
    const stats = $("#mk-stats", el);
    if (tab === "perps") {
      if (!perpsAt) return;
      const vol = (perps ?? []).reduce((s, m) => s + (m.volume24h ?? 0), 0);
      const traders = crowdRows.reduce((s, m) => s + (m.traders ?? 0), 0);
      stats.innerHTML = `24h Vol <b>${fmtUsd(vol, { compact: true })}</b> · Markets <b>${(perps ?? []).length}</b> · Traders <b>${fmtAmount(traders, 0)}</b>`;
    } else {
      if (!tokensAt) return;
      const rows = visibleTokens();
      const vol = rows.reduce((s, t) => s + (t.volume24H ?? 0), 0);
      stats.innerHTML = `24h Vol <b>${fmtUsd(vol, { compact: true })}</b> · Tokens <b>${rows.length}</b>`;
    }
  }

  // ── Polls ──────────────────────────────────────────────

  function updatePerps(rows) {
    const previous = new Map((perps ?? []).map((m) => [m.name, m.mark]));
    perps = [...rows].sort((a, b) => (b.volume24h ?? 0) - (a.volume24h ?? 0));
    perpsAt = Date.now();
    if (tab !== "perps") return;
    if (!body.querySelector("[data-id]") || perps.some((m) => !rowEl(m.name) && !query)) { paint(); return; }
    for (const m of perps) {
      const row = rowEl(m.name);
      if (!row) continue;
      const was = previous.get(m.name);
      setCell(cell(row, "mark"), fmtPrice(m.mark, m.priceDecimals), was != null ? m.mark - was : 0);
      setChange(cell(row, "chg"), m.change);
      setCell(cell(row, "vol"), fmtUsd(m.volume24h, { compact: true }));
      setCell(cell(row, "oi"), fmtUsd(m.openInterest, { compact: true }));
    }
    paintFoot();
  }

  const stopPerps = poll(async () => {
    try {
      const out = await api("/api/v1/markets", { ttl: 5_000 });
      updatePerps(out.markets ?? []);
    } catch {
      if (!perpsAt) { perps = null; paint(); }
    }
  }, 10_000);

  const stopMarks = poll(async () => {
    if (document.hidden || !perps?.length) return;
    const out = await api("/api/v1/markets/marks");
    if (dead) return;
    const marks = out?.marks ?? {};
    for (const m of perps) {
      const mark = Number(marks[m.name]);
      if (!Number.isFinite(mark)) continue;
      const was = m.mark;
      m.mark = mark;
      if (m.prev > 0) m.change = (mark - m.prev) / m.prev;
      push(perpBuf, m.name, mark);
      if (tab !== "perps") continue;
      const row = rowEl(m.name);
      setCell(cell(row, "mark"), fmtPrice(mark, m.priceDecimals), mark - was);
      setChange(cell(row, "chg"), m.change);
      drawLive(liveEl(m.name), perpBuf.get(m.name));
      bubbleTick(m.name, m.change);
    }
  }, 2_000);

  const stopTokens = poll(async () => {
    try {
      const out = await api("/api/token-discovery", { ttl: 30_000 });
      const known = new Map((tokens ?? []).map((t) => [t.id, t]));
      tokens = (out.tokens ?? []).map((t) => {
        const old = known.get(t.id);
        return old ? { ...t, change5m: old.change5m, change1h: old.change1h, change24h: old.change24h, price: old.price ?? t.price } : t;
      });
      tokensAt = out.observedAt ?? Date.now();
      if (tab !== "perps" && (!remote || remote.loading) && visibleTokens().map((t) => t.id).join() !== paintedKey) paint();
    } catch {
      if (!tokensAt) { tokens = null; if (tab !== "perps") paint(); }
    }
  }, 30_000);

  const stopPrices = poll(async () => {
    if (document.hidden || tab === "perps" || !tokensAt) return;
    const rows = visibleTokens().slice(0, 40);
    if (!rows.length) return;
    const chunks = [rows.slice(0, 20), rows.slice(20)].filter((c) => c.length);
    const outs = await Promise.all(chunks.map((c) => api(`/api/token-details?view=prices&tokens=${c.map((t) => `${t.chainIndex}:${t.contract}`).join(",")}`).catch(() => null)));
    if (dead) return;
    const byId = new Map(rows.map((t) => [t.id.toLowerCase(), t]));
    let any = false;
    for (const p of outs.flatMap((out) => out?.prices ?? [])) {
      const t = byId.get(`${p.chainIndex}:${p.contract}`.toLowerCase());
      if (!t) continue;
      any = true;
      const was = t.price;
      Object.assign(t, {
        price: p.price ?? t.price, change5m: p.change5m ?? t.change5m, change1h: p.change1h ?? t.change1h, change24h: p.change24h ?? t.change24h, change: p.change24h ?? t.change,
        marketCap: p.marketCap ?? t.marketCap, volume24H: p.volume24H ?? t.volume24H, liquidity: p.liquidity ?? t.liquidity, holders: p.holders ?? t.holders,
      });
      push(spotBuf, t.id, Number(t.price));
      const row = rowEl(t.id);
      if (row) {
        setCell(cell(row, "price"), fmtUsd(t.price), was != null ? t.price - was : 0);
        setCell(cell(row, "mcap"), fmtUsd(t.marketCap, { compact: true }));
        setCell(cell(row, "vol"), fmtUsd(t.volume24H, { compact: true }));
        setCell(cell(row, "liq"), fmtUsd(t.liquidity, { compact: true }));
        setCell(cell(row, "holders"), fmtAmount(t.holders, 0));
        setChange(cell(row, "chg"), frac(changeOf(t, period)));
      }
      drawLive(liveEl(t.id), spotBuf.get(t.id));
      bubbleTick(t.id, frac(changeOf(t, period)));
    }
    if (any && !pricesAt) { pricesAt = Date.now(); paintPeriods(); }
    if (any) paintFoot();
  }, 4_000);

  function paintSignals(out) {
    const host = $("#mk-signals", el);
    const rows = out?.signals ?? [];
    if (!rows.length) { host.innerHTML = `<div class="empty">No smart-money signals in the last ${esc(out?.window ?? "6h")}.</div>`; return; }
    host.innerHTML = rows.map((s, i) => `<a class="mk-sig enter" style="animation-delay:${i * 40}ms" href="/app/token/${esc(s.chainIndex ?? "143")}/${esc(s.token ?? "")}" data-link>
      ${logo(null, s.symbol, 28)}
      <div class="body"><b>${esc(s.symbol ?? "?")}${s.strong ? `<i class="chip-brand mk-lev">strong</i>` : ""}</b><small>${esc(s.summary ?? "")}</small></div>
      ${s.netUsd != null ? `<span class="amt num ${dirClass(s.netUsd)}">${fmtUsd(s.netUsd, { compact: true, sign: true })}</span>` : ""}
    </a>`).join("");
  }

  function paintCrowd(out) {
    const host = $("#mk-crowd", el);
    const rows = out?.markets ?? [];
    crowdRows = rows;
    if (!rows.length) { host.innerHTML = `<div class="empty">No open positions on Perpl right now.</div>`; return; }
    host.innerHTML = rows.map((m) => `<a class="mk-crowd" href="/app/trade/${esc(m.market)}" data-link>
      <div class="row-between"><span class="row" style="gap:8px">${logo(MARKET_LOGOS[m.market], m.market, 20)}<b>${esc(m.market)}</b></span><span class="num muted">${esc(m.traders ?? 0)} traders</span></div>
      <div class="bar bar-thin"><i style="width:${((m.longTraders + m.shortTraders) > 0 ? (m.longTraders / (m.longTraders + m.shortTraders)) * 100 : 50).toFixed(1)}%"></i></div>
      <small>${esc(m.longTraders ?? 0)} long · ${esc(m.shortTraders ?? 0)} short${m.biggest ? ` · biggest ${esc(m.biggest.side)} ${fmtUsd(m.biggest.value, { compact: true })}` : ""}</small>
    </a>`).join("");
  }

  const stopRail = poll(async () => {
    const [signals, crowd] = await Promise.all([
      api("/api/traders?view=signals&window=6h", { ttl: 15_000 }).catch(() => null),
      api("/api/traders?view=crowd", { ttl: 30_000 }).catch(() => null),
    ]);
    if (dead) return;
    $("#mk-sig-dot", el).className = signals ? "dot" : "dot amber";
    if (signals) paintSignals(signals); else if ($("#mk-signals .skel-row", el)) $("#mk-signals", el).innerHTML = `<div class="empty">Signals could not be read right now.</div>`;
    if (crowd) paintCrowd(crowd); else if (!$("#mk-crowd", el).innerHTML) $("#mk-crowd", el).innerHTML = `<div class="empty">Crowd could not be read right now.</div>`;
    paintFoot();
  }, 30_000);

  paintChips();
  paintPeriods();
  paint();
  return () => {
    dead = true;
    stopPerps(); stopMarks(); stopTokens(); stopPrices(); stopRail();
    clearTimeout(localTimer); clearTimeout(remoteTimer); clearTimeout(resizeTimer);
    document.removeEventListener("click", onDocClick);
    document.removeEventListener("keydown", onKey);
    window.removeEventListener("resize", onResize);
  };
}
