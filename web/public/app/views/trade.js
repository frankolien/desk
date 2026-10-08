import { $, $$, MARKET_LOGOS, ago, api, dirClass, esc, fmtAmount, fmtCompact, fmtPct, fmtPrice, fmtUsd, handoff, head, hydratePeople, connectedWallet, chartOptions, candleOptions, volumeColor, chartLegend, chartCountdown, identity, knownIdentity, logo, markets, navigate, person, poll, short, toast } from "../app.js";
import { isFollowing, toggleFollow } from "../follows.js";
import { estimateFill, watchBook } from "../book.js";
import { isUnlocked, onSession, session } from "../session.js";
import { PerplError, accountFor, context as perplContext, describePositions, ensureKey, exchangeOf, marketOf, placeOrder, positions as perplPositions, storedKey, wallet as perplWallet } from "../perpl.js";
import { ausdBalance, deposit as chainDeposit, explorerTx, hasAccount, openDesk } from "../chain.js";

const BOOK_LEVELS = 9;

const BAR_SECONDS = { "1m": 60, "5m": 300, "15m": 900, "1H": 3600, "4H": 14400, "1D": 86400 };

const BARS = ["1m", "5m", "15m", "1H", "4H", "1D"];
const SPOT = { BTC: true, ETH: true, SOL: true, PUMP: true };
const QUICK = [25, 50, 100, 250];

const CSS = `
.td-grid { display: grid; grid-template-columns: 216px minmax(0, 1fr) 340px; gap: 16px; align-items: start; }
.td-list { position: sticky; top: calc(var(--topbar) + 14px); }
.td-list .row-m { display: flex; align-items: center; gap: 10px; padding: 9px 12px; border-radius: 10px; cursor: pointer; transition: background .12s var(--ease); }
.td-list .row-m:hover { background: var(--chip); }
.td-list .row-m[aria-current="true"] { background: #1a1a1a; }
.td-list .row-m .n { display: grid; gap: 1px; min-width: 0; flex: 1; }
.td-list .row-m .n b { font-size: 13px; }
.td-list .row-m .n span { font-size: 10px; color: var(--faint); font-weight: 600; letter-spacing: .02em; }
.td-list .row-m .p { text-align: right; display: grid; gap: 1px; }
.td-list .row-m .p b { font-size: 12px; font-weight: 600; }
.td-list .row-m .p small { font-size: 10px; font-weight: 700; }
.td-head { display: flex; align-items: center; gap: 18px; padding: 14px 18px; flex-wrap: wrap; }
.td-head .who { display: flex; align-items: center; gap: 12px; min-width: 200px; }
.td-head .who h1 { font-size: 20px; display: flex; align-items: center; gap: 8px; }
.td-head .who .sub { font-size: 12px; margin-top: 2px; display: flex; gap: 8px; align-items: center; }
.td-head .stats { display: flex; gap: 26px; flex: 1; flex-wrap: wrap; }
.td-head .stat .num { font-size: 15px; }
.td-head .stat.mark .num { font-size: 22px; letter-spacing: -.02em; }
.td-head .stat.mark small { font-size: 12px; font-weight: 700; margin-left: 6px; }
.td-chart-bar { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 10px 12px; border-bottom: 1px solid var(--line); }
.td-chart { height: 440px; position: relative; }
/* Full screen is the chart alone: the market strip, the bar controls and the candles edge to edge,
   over everything else. F toggles, Esc leaves. The ResizeObserver on the chart host does the rest. */
body.focus { overflow: hidden; }
body.focus .td-grid > section { position: fixed; inset: 0; z-index: 40; display: flex; flex-direction: column; gap: 0 !important; background: var(--bg); }
body.focus .td-grid > section > .card { border-radius: 0; border-left: 0; border-right: 0; }
body.focus .td-grid > section > .card:first-child { border-top: 0; }
body.focus .td-grid > section > .card:nth-child(2) { flex: 1; display: flex; flex-direction: column; min-height: 0; border-bottom: 0; }
body.focus .td-grid > section > .card:nth-child(n+3), body.focus .td-list, body.focus .td-grid > aside { display: none; }
body.focus .td-head { padding: 8px 16px; }
body.focus .td-head .stat.mark .num { font-size: 20px; }
body.focus .td-chart { flex: 1; height: auto; min-height: 0; }
body.focus #td-focus { background: var(--chip-hover); }
.td-chart .lw { position: absolute; inset: 0; }
.td-tabs { padding: 0 16px; }
.td-ticket .sides { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; padding: 4px; background: var(--card-2); border-radius: 12px; }
.td-ticket .sides button { height: 40px; border-radius: 9px; font-size: 14px; font-weight: 800; color: var(--muted); transition: background .15s var(--ease), color .15s var(--ease); }
.td-ticket .sides button:hover { color: var(--text); }
.td-ticket .sides button[aria-selected="true"].long { background: var(--rise); color: #04160b; }
.td-ticket .sides button[aria-selected="true"].short { background: var(--fall); color: #1c0606; }
.td-ticket .label { display: flex; justify-content: space-between; align-items: baseline; font-size: 12px; color: var(--muted); font-weight: 600; margin-bottom: 6px; }
.td-ticket .label b { color: var(--text); font-size: 13px; }
.td-ticket .quick { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; margin-top: 8px; }
.td-ticket .quick .chip { justify-content: center; height: 30px; }
.td-ticket .lev { display: grid; grid-template-columns: repeat(5, 1fr); gap: 6px; margin-top: 10px; }
.td-ticket .lev .chip { justify-content: center; height: 28px; font-size: 12px; }
.td-summary { display: grid; gap: 7px; font-size: 12.5px; }
.td-summary div { display: flex; justify-content: space-between; gap: 10px; }
.td-summary span { color: var(--muted); }
.td-summary b { font-weight: 600; }
.td-sentence { font-size: 12.5px; font-weight: 600; line-height: 1.45; color: var(--text-2); }
.td-crowd .bar { margin: 8px 0 6px; }
.td-kv { display: grid; gap: 8px; font-size: 12.5px; }
.td-kv div { display: flex; justify-content: space-between; }
.td-kv span { color: var(--muted); }
.td-bigpos { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-top: 10px; }
.td-mobile-pick { display: none; }
.td-list-h { font-size: 10px; font-weight: 800; letter-spacing: .06em; text-transform: uppercase; color: var(--faint); padding: 8px 12px 4px; }
.td-yours { margin-top: 8px; }
.td-yours .chip { height: 26px; font-size: 11px; font-weight: 700; cursor: pointer; }
.td-tpsl { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 6px; }
.td-tpsl .field { min-width: 0; }
.td-tpsl .field input { font-size: 13px; width: 100%; }
.td-news-item { display: grid; gap: 3px; padding: 10px 0; border-top: 1px solid var(--line); color: inherit; text-decoration: none; }
.td-news-item:first-of-type { border-top: 0; padding-top: 4px; }
.td-news-item b { font-size: 13px; line-height: 1.35; font-weight: 600; }
.td-news-item:hover b { color: var(--brand); }
.td-news-item span { font-size: 11px; color: var(--muted); font-weight: 600; }
.td-keys { display: flex; gap: 6px; justify-content: center; flex-wrap: wrap; }
.td-status { font-size: 12.5px; font-weight: 600; line-height: 1.45; color: var(--text-2); display: flex; gap: 8px; align-items: flex-start; }
.td-status.err { color: var(--fall); } .td-status.ok { color: var(--rise); }
.td-status .spin { width: 12px; height: 12px; border-radius: 50%; border: 2px solid var(--line-strong); border-top-color: var(--text); animation: tdSpin .8s linear infinite; flex: none; margin-top: 3px; }
@keyframes tdSpin { to { transform: rotate(360deg); } }
.td-desk .row-kv { display: flex; justify-content: space-between; font-size: 12.5px; padding: 6px 0; border-bottom: 1px solid var(--line); }
.td-desk .row-kv:last-of-type { border-bottom: 0; }
.td-desk .row-kv span { color: var(--muted); }
.td-steps { display: grid; gap: 6px; margin-top: 10px; font-size: 12px; }
.td-steps div { display: flex; align-items: center; gap: 8px; color: var(--muted); }
.td-steps .dot { width: 7px; height: 7px; box-shadow: none; background: var(--faint); }
.td-steps .done .dot { background: var(--rise); } .td-steps .done { color: var(--text); }
.td-steps .sending .dot { background: var(--amber, #e0a52a); } .td-steps .sending { color: var(--text); }
.td-steps a { color: var(--brand); text-decoration: none; font-weight: 700; }
.td-keys kbd { font: 700 10px/1 var(--mono, ui-monospace, monospace); padding: 3px 5px; border-radius: 5px; background: var(--chip); color: var(--muted); border: 1px solid var(--line); }
.td-live { display: inline-flex; align-items: center; gap: 8px; margin-left: 14px; vertical-align: middle; }
.td-live .spark { width: 84px; height: 26px; overflow: visible; }
.td-live .halo { transform-box: fill-box; transform-origin: center; animation: tdHalo 1.6s ease-out infinite; }
@keyframes tdHalo { from { transform: scale(1); opacity: .5; } to { transform: scale(2.2); opacity: 0; } }
.td-faces { position: absolute; inset: 0; pointer-events: none; z-index: 3; overflow: hidden; }
.td-face { position: absolute; width: 20px; height: 20px; margin: -10px 0 0 -10px; border-radius: 50%; overflow: hidden; pointer-events: auto; cursor: pointer; box-shadow: 0 0 0 2px var(--ring), 0 0 0 3px #000; background: var(--chip); transition: transform .12s var(--ease); }
.td-face:hover { transform: scale(1.25); z-index: 2; }
.td-face img { width: 100%; height: 100%; object-fit: cover; }
.td-face span { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; font-size: 8px; font-weight: 800; color: #fff; }
.td-face.long { --ring: var(--rise); } .td-face.short { --ring: var(--fall); }
.td-tip { position: absolute; z-index: 5; pointer-events: none; padding: 10px 12px; min-width: 200px; font-size: 12px; line-height: 1.45; background: #141414; border: 1px solid var(--line-strong); border-radius: 12px; box-shadow: 0 12px 30px rgba(0,0,0,.5); }
.td-tip b { display: block; font-size: 13px; }
.td-tip .muted { display: block; }
@media (max-width: 1320px) { .td-grid { grid-template-columns: minmax(0, 1fr) 320px; } .td-list { display: none; } .td-mobile-pick { display: flex; } }
@media (max-width: 1000px) { .td-grid { grid-template-columns: 1fr; } .td-chart { height: 340px; } }
@media (max-width: 720px) { .td-head { gap: 12px; } .td-head .who { min-width: 0; width: 100%; } .td-head .stats { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 14px; } .td-head .stat.mark { grid-column: 1 / -1; } .td-head .stat .num { font-size: 14px; } }
`;

export default async function mount(el, params) {
  el.innerHTML = `<style>${CSS}</style><div class="td-grid" id="td"></div>`;
  const root = $("#td", el);
  const stops = [];
  const state = {
    market: null, rows: [], bar: "15m", side: "long", margin: 0, leverage: 3, tab: "crowd", focus: false,
    chart: null, series: null, volume: null, markLine: null, crowd: null, top: null, watched: watched(), lastBar: null,
    ring: [], lastCandle: null, candles: [], legend: null, countdown: null, faces: [], showFaces: localStorage.getItem("desk.web.chartfaces") !== "off",
    positions: null, positionsFor: null, news: null, tp: 0, sl: 0,
    book: null, bookStop: null, bookFallback: null,
    acct: null, acctBusy: false, trading: null, desk: { open: false, amount: "", busy: false, steps: [], error: null, hash: null },
  };

  let rows = markets();
  if (!rows.length) {
    root.innerHTML = skeleton();
    try { rows = (await api("/api/v1/markets")).markets ?? []; } catch { root.innerHTML = `<div class="empty">Perpl could not be read right now.</div>`; return () => {}; }
  }
  if (!rows.length) { root.innerHTML = `<div class="empty">No open markets on Perpl right now.</div>`; return () => {}; }
  state.rows = rows;
  state.market = rows.find((m) => m.name === (params.market ?? "")) ?? rows.find((m) => m.name === "BTC") ?? rows[0];
  if (params.market && params.market !== state.market.name) navigate(`/app/trade/${state.market.name}`, { replace: true });

  paint();

  const onMarkets = (event) => {
    state.rows = event.detail;
    const fresh = state.rows.find((m) => m.name === state.market.name);
    if (fresh) { const was = state.market.mark; state.market = fresh; refreshMark(was); }
    paintList();
  };
  document.addEventListener("markets", onMarkets);
  stops.push(() => document.removeEventListener("markets", onMarkets));
  const onMarks = (event) => {
    const mark = event.detail.marks?.[state.market.name];
    if (mark == null) return;
    const was = state.market.mark;
    state.market = { ...state.market, mark, change: state.market.prev > 0 ? (mark - state.market.prev) / state.market.prev : state.market.change };
    state.ring.push(mark); if (state.ring.length > 60) state.ring.shift();
    refreshMark(was);
    paintSpark();
    tickCandle(mark, event.detail.at);
    placeFaces();
  };
  document.addEventListener("marks", onMarks);
  stops.push(() => document.removeEventListener("marks", onMarks));
  const onWallet = () => { state.positions = null; state.positionsFor = null; paintQuote(); paintYours(); loadPositions(); if (state.tab === "positions") paintTab(); };
  document.addEventListener("wallet", onWallet);
  stops.push(() => document.removeEventListener("wallet", onWallet));

  // Keys work anywhere on the page except inside a field: L and S pick the side, 1–9 the leverage.
  const onKey = (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const target = event.target;
    if (target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
    const key = event.key.toLowerCase();
    if (key === "l" || key === "s") { setSide(key === "l" ? "long" : "short"); event.preventDefault(); return; }
    if (/^[1-9]$/.test(key)) { setLeverage(Number(key)); event.preventDefault(); return; }
    if (key === "0") { setLeverage(10); event.preventDefault(); return; }
    if (key === "p") { setTab("positions"); event.preventDefault(); return; }
    if (key === "f") { setFocus(!state.focus); event.preventDefault(); return; }
    if (event.key === "Escape" && state.focus) { setFocus(false); event.preventDefault(); }
  };
  document.addEventListener("keydown", onKey);
  stops.push(() => document.removeEventListener("keydown", onKey));

  stops.push(poll(loadCandles, 15_000));
  stops.push(poll(loadCrowd, 30_000));
  stops.push(poll(loadPositions, 10_000));
  stops.push(poll(loadNews, 300_000));
  loadTop();
  startBook();
  startAccount();

  // The whole page becomes the terminal: the shell steps out and the browser goes full screen when
  // the user asked with a click or a key; a persisted preference restores the layout without the
  // browser part, which needs a gesture. Leaving browser full screen leaves the mode too.
  function setFocus(on, { browser = true } = {}) {
    state.focus = on;
    document.body.classList.toggle("focus", on);
    try { localStorage.setItem("desk.web.focus", on ? "on" : "off"); } catch {}
    const button = $("#td-focus", root);
    if (button) { button.setAttribute("aria-pressed", String(on)); button.textContent = on ? "Exit full screen" : "Full screen"; }
    if (browser && on && !document.fullscreenElement) document.documentElement.requestFullscreen?.().catch(() => {});
    if (!on && document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
  }
  const onFullscreen = () => { if (!document.fullscreenElement && state.focus) setFocus(false); };
  document.addEventListener("fullscreenchange", onFullscreen);
  stops.push(() => document.removeEventListener("fullscreenchange", onFullscreen));
  stops.push(() => { if (state.focus) setFocus(false); document.body.classList.remove("focus"); });
  try { if (localStorage.getItem("desk.web.focus") === "on") setFocus(true, { browser: false }); } catch {}

  return () => { stops.forEach((stop) => stop()); state.bookStop?.(); state.bookFallback?.(); state.chart?.remove(); };

  function paint() {
    const m = state.market;
    root.innerHTML = `
      <aside class="card td-list" id="td-list"></aside>
      <section class="stack" style="gap:16px">
        <div class="card td-head" id="td-head"></div>
        <div class="card">
          <div class="td-chart-bar">
            <div class="row" style="gap:8px">
              <button class="btn btn-ghost btn-xs td-mobile-pick" id="td-pick">${esc(m.name)} <svg width="12" height="12"><use href="#i-chevron"/></svg></button>
              <div class="seg seg-sm seg-line" id="td-bars">${BARS.map((b) => `<button aria-selected="${b === state.bar}" data-bar="${b}">${b}</button>`).join("")}</div>
            </div>
            <div class="row" style="gap:6px">
              <span class="chip chip-brand" style="height:24px;font-size:11px"><i class="dot" style="width:5px;height:5px;background:var(--brand);box-shadow:none"></i>Perpl mark</span>
              <span class="chip" style="height:24px;font-size:11px">OKX tape</span>
              <button class="chip" style="height:24px;font-size:11px" id="td-facetoggle" aria-pressed="${state.showFaces}">Top traders</button>
              <button class="chip" style="height:24px;font-size:11px" id="td-focus" aria-pressed="${state.focus}" title="Full screen · F">${state.focus ? "Exit full screen" : "Full screen"}</button>
            </div>
          </div>
          <div class="td-chart"><div class="lw" id="td-lw"></div><div class="td-faces" id="td-faces" ${state.showFaces ? "" : "hidden"}></div></div>
        </div>
        <div class="card">
          <div class="tabs td-tabs" id="td-tabs">
            <button data-tab="positions">Positions</button>
            <button aria-selected="true" data-tab="crowd">Crowd</button>
            <button data-tab="top">Top traders</button>
            ${SPOT[m.name] ? `<button data-tab="trades">Trades</button>` : ""}
          </div>
          <div id="td-tabpane"></div>
        </div>
      </section>
      <aside class="stack" style="gap:16px">
        <div class="card card-pad td-ticket stack" id="td-ticket"></div>
        <div class="card card-pad td-desk" id="td-desk" hidden></div>
        <div class="card card-pad" id="td-book"></div>
        <div class="card card-pad td-crowd" id="td-crowdcard"></div>
        <div class="card card-pad" id="td-market"></div>
        <div class="card card-pad" id="td-news"></div>
      </aside>`;
    paintList();
    paintHead();
    paintTicket();
    paintMarketCard();
    paintCrowdCard();
    paintNews();
    paintTab();
    buildChart();

    $("#td-bars", root).addEventListener("click", (event) => {
      const b = event.target.closest("[data-bar]"); if (!b) return;
      state.bar = b.dataset.bar;
      $$("[data-bar]", root).forEach((x) => x.setAttribute("aria-selected", String(x === b)));
      loadCandles(true);
    });
    $("#td-tabs", root).addEventListener("click", (event) => {
      const b = event.target.closest("[data-tab]"); if (!b) return;
      setTab(b.dataset.tab);
    });
    $("#td-pick", root).addEventListener("click", () => $("#search-open").click());
    $("#td-focus", root).addEventListener("click", () => setFocus(!state.focus));
    $("#td-facetoggle", root).addEventListener("click", (event) => {
      state.showFaces = !state.showFaces;
      localStorage.setItem("desk.web.chartfaces", state.showFaces ? "on" : "off");
      event.currentTarget.setAttribute("aria-pressed", String(state.showFaces));
      $("#td-faces", root).hidden = !state.showFaces;
    });
  }

  function paintList() {
    const host = $("#td-list", root); if (!host) return;
    const row = (m) => `
      <a class="row-m" href="/app/trade/${esc(m.name)}" data-link aria-current="${m.name === state.market.name}">
        ${logo(MARKET_LOGOS[m.name], m.name, 24)}
        <div class="n"><b>${esc(m.name)}</b><span>UP TO ${m.maxLeverage}×</span></div>
        <div class="p"><b class="num">${fmtPrice(m.mark, m.priceDecimals)}</b><small class="num ${dirClass(m.change)}">${fmtPct(m.change)}</small></div>
      </a>`;
    const watching = state.rows.filter((m) => state.watched.has(m.name));
    const rest = state.rows.filter((m) => !state.watched.has(m.name));
    host.innerHTML = `<div class="card-head" style="padding:12px 14px"><h3>Perps</h3><span class="eyebrow">AUSD</span></div><div style="padding:6px">${
      watching.length ? `<div class="td-list-h">Watching</div>${watching.map(row).join("")}<div class="td-list-h">All perps</div>` : ""
    }${rest.map(row).join("")}</div>`;
  }

  function paintHead() {
    const m = state.market;
    const funding = m.fundingRate == null ? "—" : `${fmtPct(m.fundingRate, { digits: 4 })}`;
    $("#td-head", root).innerHTML = `
      <div class="who">
        ${logo(MARKET_LOGOS[m.name], m.name, 44)}
        <div>
          <h1>${esc(m.name)} <span class="chip chip-brand" style="height:22px;font-size:11px">PERP · ${m.maxLeverage}×</span></h1>
          <div class="sub muted"><span>Perpl · Monad</span><span>·</span><span>settles in AUSD</span></div>
          <div class="td-yours" id="td-yours" hidden></div>
        </div>
      </div>
      <div class="stats">
        <div class="stat mark"><span class="eyebrow">Mark <span class="muted" style="font-weight:600">· live</span></span><span class="num" id="td-mark">${fmtPrice(m.mark, m.priceDecimals)}<small class="${dirClass(m.change)}" id="td-change">${fmtPct(m.change)}</small><span class="td-live"><svg class="spark" viewBox="0 0 84 26" id="td-spark"></svg></span></span></div>
        <div class="stat"><span class="eyebrow">24h volume</span><span class="num" id="td-vol">${fmtUsd(m.volume24h, { compact: true })}</span></div>
        <div class="stat"><span class="eyebrow">Open interest</span><span class="num" id="td-oi">${fmtUsd(m.openInterest, { compact: true })}</span></div>
        <div class="stat"><span class="eyebrow">Funding</span><span class="num ${m.fundingRate > 0 ? "up" : m.fundingRate < 0 ? "down" : ""}" id="td-funding">${funding}<small class="muted" style="font-weight:600"> / ${interval(m.fundingIntervalSec)}</small></span></div>
        <div class="stat"><span class="eyebrow">TVL</span><span class="num">${fmtUsd(m.tvl, { compact: true })}</span></div>
      </div>
      <button class="icon-btn" id="td-star" aria-pressed="${state.watched.has(m.name)}" title="Watch" style="color:${state.watched.has(m.name) ? "var(--amber)" : ""}"><svg><use href="#i-star"/></svg></button>`;
    $("#td-star", root).addEventListener("click", (event) => {
      const button = event.currentTarget;
      if (state.watched.has(m.name)) state.watched.delete(m.name); else state.watched.add(m.name);
      localStorage.setItem("desk.web.perps", JSON.stringify([...state.watched]));
      button.setAttribute("aria-pressed", String(state.watched.has(m.name)));
      button.style.color = state.watched.has(m.name) ? "var(--amber)" : "";
      paintList();
    });
    paintYours();
  }

  /// The connected wallet's own position on this market, as one line under the title.
  function paintYours() {
    const host = $("#td-yours", root); if (!host) return;
    const mine = myPosition();
    if (!mine) { host.hidden = true; host.innerHTML = ""; return; }
    const pnl = Number(mine.pnl);
    host.hidden = false;
    host.innerHTML = `<button class="chip" id="td-yours-chip"><span class="side-chip ${mine.side}">${mine.side} ${mine.leverage ?? "—"}×</span>&nbsp;your position · <b class="num ${dirClass(pnl)}">${fmtUsd(pnl, { sign: true })}</b>&nbsp;<span class="muted">(${fmtPct((mine.pnlPercent ?? 0) / 100)})</span></button>`;
    $("#td-yours-chip", host).addEventListener("click", () => setTab("positions"));
  }

  function myPosition() {
    if (unlockedPasskey() && state.acct?.positions) {
      const live = state.acct.positions.find((p) => p.market === state.market.name);
      if (!live) return null;
      const mark = state.market.mark;
      const pnl = (mark - live.entry) * live.size * (live.side === "long" ? 1 : -1);
      return { side: live.side, leverage: live.leverage, pnl, pnlPercent: live.collateral ? (pnl / live.collateral) * 100 : null };
    }
    return state.positions?.find((p) => p.market === state.market.name) ?? null;
  }

  function setTab(name) {
    state.tab = name;
    $$("[data-tab]", root).forEach((x) => x.setAttribute("aria-selected", String(x.dataset.tab === name)));
    paintTab();
  }

  function setSide(side) {
    const button = $(`[data-side="${side}"]`, root);
    if (button && state.side !== side) button.click();
  }

  function refreshMark(was) {
    const m = state.market;
    const mark = $("#td-mark", root); if (!mark) return;
    mark.firstChild.textContent = fmtPrice(m.mark, m.priceDecimals);
    if (was != null && was !== m.mark) { mark.classList.remove("flash-up", "flash-down"); void mark.offsetWidth; mark.classList.add(m.mark > was ? "flash-up" : "flash-down"); }
    const change = $("#td-change", root); change.textContent = fmtPct(m.change); change.className = dirClass(m.change);
    $("#td-vol", root).textContent = fmtUsd(m.volume24h, { compact: true });
    $("#td-oi", root).textContent = fmtUsd(m.openInterest, { compact: true });
    if (state.markLine) state.markLine.applyOptions({ price: m.mark });
    $$(".row-m", root).forEach((row) => {
      const name = row.getAttribute("href").split("/").pop();
      const fresh = state.rows.find((x) => x.name === name); if (!fresh) return;
      row.querySelector(".p b").textContent = fmtPrice(fresh.mark, fresh.priceDecimals);
      const small = row.querySelector(".p small"); small.textContent = fmtPct(fresh.change); small.className = `num ${dirClass(fresh.change)}`;
    });
    paintQuote();
  }

  function paintTicket() {
    const m = state.market;
    state.leverage = Math.min(state.leverage, m.maxLeverage);
    $("#td-ticket", root).innerHTML = `
      <div class="sides" role="tablist">
        <button class="long" role="tab" aria-selected="${state.side === "long"}" data-side="long">Long</button>
        <button class="short" role="tab" aria-selected="${state.side === "short"}" data-side="short">Short</button>
      </div>
      <div>
        <div class="label"><span>Margin</span><span>AUSD</span></div>
        <label class="field"><input id="td-amount" inputmode="decimal" placeholder="0" value="${state.margin || ""}" autocomplete="off"><span class="unit">AUSD</span></label>
        <div class="quick">${QUICK.map((q) => `<button class="chip" data-quick="${q}">$${q}</button>`).join("")}</div>
      </div>
      <div>
        <div class="label"><span>Leverage</span><b class="num" id="td-levtext">${state.leverage}×</b></div>
        <input class="range" id="td-lev" type="range" min="1" max="${m.maxLeverage}" step="1" value="${state.leverage}" style="--fill:${fill(state.leverage, m.maxLeverage)}">
        <div class="lev">${levChips(m.maxLeverage).map((l) => `<button class="chip" data-lev="${l}" aria-pressed="${l === state.leverage}">${l}×</button>`).join("")}</div>
      </div>
      <div>
        <div class="label"><span>Take profit / Stop loss</span><span>optional · price</span></div>
        <div class="td-tpsl">
          <label class="field"><input id="td-tp" inputmode="decimal" placeholder="TP" value="${state.tp || ""}" autocomplete="off"></label>
          <label class="field"><input id="td-sl" inputmode="decimal" placeholder="SL" value="${state.sl || ""}" autocomplete="off"></label>
        </div>
      </div>
      <div class="cell td-summary" id="td-quote"></div>
      <div class="td-sentence" id="td-sentence"></div>
      <button class="btn btn-lg btn-block ${state.side === "long" ? "btn-rise" : "btn-fall"}" id="td-go"></button>
      <div class="td-status" id="td-status" hidden></div>
      <div class="note" style="text-align:center;font-size:11px" id="td-note">Signs with Face ID in the app. Nothing on the web can move money.</div>
      <div class="td-keys"><kbd>L</kbd><kbd>S</kbd><span class="note" style="font-size:10px">side</span><kbd>1</kbd>–<kbd>9</kbd><span class="note" style="font-size:10px">leverage</span><kbd>P</kbd><span class="note" style="font-size:10px">positions</span><kbd>F</kbd><span class="note" style="font-size:10px">full screen</span></div>`;
    const ticket = $("#td-ticket", root);
    ticket.addEventListener("click", (event) => {
      const side = event.target.closest("[data-side]");
      if (side) {
        state.side = side.dataset.side;
        $$("[data-side]", ticket).forEach((b) => b.setAttribute("aria-selected", String(b === side)));
        $("#td-go", ticket).className = `btn btn-lg btn-block ${state.side === "long" ? "btn-rise" : "btn-fall"}`;
        paintQuote(); return;
      }
      const quick = event.target.closest("[data-quick]");
      if (quick) { state.margin = Number(quick.dataset.quick); $("#td-amount", ticket).value = state.margin; paintQuote(); return; }
      const lev = event.target.closest("[data-lev]");
      if (lev) { setLeverage(Number(lev.dataset.lev)); return; }
      if (event.target.closest("#td-go")) onGo();
    });
    $("#td-amount", ticket).addEventListener("input", (event) => { state.margin = Number(String(event.target.value).replace(/[^0-9.]/g, "")) || 0; paintQuote(); });
    $("#td-tp", ticket).addEventListener("input", (event) => { state.tp = Number(String(event.target.value).replace(/[^0-9.]/g, "")) || 0; paintQuote(); });
    $("#td-sl", ticket).addEventListener("input", (event) => { state.sl = Number(String(event.target.value).replace(/[^0-9.]/g, "")) || 0; paintQuote(); });
    $("#td-lev", ticket).addEventListener("input", (event) => setLeverage(Number(event.target.value)));
    paintQuote();
  }

  function setLeverage(value) {
    const m = state.market;
    state.leverage = Math.max(1, Math.min(m.maxLeverage, value));
    const range = $("#td-lev", root); range.value = state.leverage; range.style.setProperty("--fill", fill(state.leverage, m.maxLeverage));
    $("#td-levtext", root).textContent = `${state.leverage}×`;
    $$("[data-lev]", root).forEach((b) => b.setAttribute("aria-pressed", String(Number(b.dataset.lev) === state.leverage)));
    paintQuote();
  }

  function quote() {
    const m = state.market;
    const margin = state.margin;
    if (!(margin > 0) || !(m.mark > 0)) return null;
    const notional = margin * state.leverage;
    const fee = notional * m.takerFee / 1e6;
    const size = notional / m.mark;
    const backing = margin - fee;
    const mm = m.maintenanceMargin > 0 ? 100 / m.maintenanceMargin : 0;
    const liquidation = state.side === "long" ? m.mark - backing / size + m.mark * mm : m.mark + backing / size - m.mark * mm;
    const distance = Math.abs(liquidation - m.mark) / m.mark;
    return { notional, fee, size, liquidation: Math.max(0, liquidation), distance, total: margin + fee };
  }

  /// What a take profit or stop at `price` would return on the margin, or why it cannot: a
  /// long's stop sits below the mark and above liquidation, a take profit above the mark.
  function exit(kind, price, q) {
    const m = state.market;
    if (!(price > 0) || !q) return null;
    const long = state.side === "long";
    const above = price > m.mark;
    if (kind === "tp" && above === !long) return { error: long ? "Take profit sits above the entry" : "Take profit sits below the entry" };
    if (kind === "sl" && above === long) return { error: long ? "Stop sits below the entry" : "Stop sits above the entry" };
    if (kind === "sl" && (long ? price <= q.liquidation : price >= q.liquidation)) return { error: "Stop sits past liquidation" };
    const pnl = (long ? price - m.mark : m.mark - price) * q.size - q.fee;
    return { pnl, onMargin: pnl / state.margin, move: Math.abs(price - m.mark) / m.mark };
  }

  function sentence() {
    const m = state.market;
    const q = quote(); if (!q) return "";
    const parts = [`${cap(state.side)} ${m.name} ${state.leverage}×`, `${fmtAmount(state.margin, 2)} AUSD margin`, `~${fmtAmount(q.notional, 2)} AUSD size`];
    if (state.leverage > 1) parts.push(`liq ${fmtPrice(q.liquidation, m.priceDecimals)} (${fmtPct(q.distance, { sign: false, digits: 1 })} away)`);
    const tp = exit("tp", state.tp, q); if (tp && !tp.error) parts.push(`TP ${fmtPrice(state.tp, m.priceDecimals)} (${fmtPct(tp.onMargin)})`);
    const sl = exit("sl", state.sl, q); if (sl && !sl.error) parts.push(`SL ${fmtPrice(state.sl, m.priceDecimals)} (${fmtPct(sl.onMargin)})`);
    return parts.join(" · ");
  }

  function paintQuote() {
    const m = state.market;
    const q = quote();
    const box = $("#td-quote", root); const line = $("#td-sentence", root); const go = $("#td-go", root);
    if (!box) return;
    const mode = tradeMode();
    go.className = `btn btn-lg btn-block ${mode.tone === "side" ? (state.side === "long" ? "btn-rise" : "btn-fall") : mode.tone === "primary" ? "btn-primary" : "btn-line"}`;
    go.textContent = mode.label;
    go.disabled = Boolean(mode.disabled) || (mode.needsSize && !q);
    const note = $("#td-note", root); if (note) note.textContent = mode.note;
    if (!q) {
      box.innerHTML = `<div><span>Size</span><b>—</b></div><div><span>Entry</span><b class="num">${fmtPrice(m.mark, m.priceDecimals)}</b></div><div><span>Liquidation</span><b>—</b></div><div><span>Fee</span><b class="muted">${(m.takerFee / 1e4).toFixed(3)}% taker</b></div>`;
      line.textContent = "";
      return;
    }
    box.innerHTML = `
      <div><span>Size</span><b class="num">${fmtAmount(q.notional, 2)} AUSD <span class="muted">· ${fmtAmount(q.size, m.sizeDecimals)} ${esc(m.name)}</span></b></div>
      <div><span>Entry</span><b class="num">${fmtPrice(m.mark, m.priceDecimals)}</b></div>
      ${fillRow(q)}
      <div><span>Liquidation</span><b class="num ${state.side === "long" ? "down" : "up"}">${fmtPrice(q.liquidation, m.priceDecimals)} <span class="muted">· ${fmtPct(q.distance, { sign: false, digits: 1 })} away</span></b></div>
      <div><span>Fee</span><b class="num">${fmtAmount(q.fee, 2)} AUSD <span class="muted">· ${(m.takerFee / 1e4).toFixed(3)}%</span></b></div>
      <div><span>Total</span><b class="num">${fmtAmount(q.total, 2)} AUSD</b></div>
      ${exitRow("Take profit", exit("tp", state.tp, q))}
      ${exitRow("Stop loss", exit("sl", state.sl, q))}`;
    line.textContent = sentence();
  }

  /// Where the book would fill this size right now: the ticket's own number, not the mark.
  function fillRow(q) {
    if (!state.book) return "";
    const fill = estimateFill(state.book, state.side, q.size);
    if (!fill) return `<div><span>Est. fill</span><b class="muted">Book too thin for this size</b></div>`;
    const m = state.market;
    const slip = (fill.price - m.mark) / m.mark * (state.side === "long" ? 1 : -1);
    return `<div><span>Est. fill</span><b class="num">${fmtPrice(fill.price, m.priceDecimals)} <span class="${slip > 0.0005 ? "down" : "muted"}">· ${fmtPct(slip, { sign: true, digits: 2 })}${fill.partial ? " · partial" : ""}</span></b></div>`;
  }

  function startBook() {
    const m = state.market;
    if (m.id == null) return;
    paintBook();
    // The API's two-second snapshot is the path that always works; Perpl's socket refuses
    // browser origins it does not know, so it is tried as an upgrade and takes over if it
    // ever answers.
    let live = false;
    state.bookFallback = poll(async () => {
      if (live) return;
      try {
        const snapshot = await api(`/api/v1/markets/${m.name}/book?levels=${BOOK_LEVELS}`, { ttl: 1_500 });
        if (live) return;
        state.book = { bids: snapshot.bids ?? [], asks: snapshot.asks ?? [], at: snapshot.at, live: false, polled: true };
      } catch {
        state.book = state.book ?? { bids: [], asks: [], at: 0, live: false, polled: true, failed: true };
        if (state.book.failed === undefined) state.book = { ...state.book, failed: true };
      }
      paintBook(); paintQuote();
    }, 2_000);
    state.bookStop = watchBook(m.id, { price: m.priceDecimals, size: m.sizeDecimals }, (book) => {
      if (!book.live || (!book.bids.length && !book.asks.length)) return;
      live = true;
      state.bookFallback?.(); state.bookFallback = null;
      state.book = book;
      paintBook(); paintQuote();
    });
  }

  function paintBook() {
    const host = $("#td-book", root); if (!host) return;
    const m = state.market;
    const book = state.book;
    const stateChip = book?.live
      ? `<span class="book-state"><i class="dot" style="background:var(--rise)"></i>live</span>`
      : book?.bids?.length ? `<span class="book-state"><i class="dot" style="background:var(--amber, #e0a52a)"></i>every 2 s</span>`
      : book?.failed ? `<span class="book-state">unavailable</span>` : `<span class="book-state">loading…</span>`;
    if (!book || (!book.bids.length && !book.asks.length)) {
      host.innerHTML = `<div class="row-between"><h3>Book</h3>${stateChip}</div>${book?.failed
        ? `<div class="note" style="margin-top:8px">Perpl's book could not be read right now.</div>`
        : `<div class="skel" style="margin-top:12px"></div><div class="skel" style="margin-top:8px;width:70%"></div><div class="skel" style="margin-top:8px;width:85%"></div>`}`;
      return;
    }
    const asks = book.asks.slice(0, BOOK_LEVELS);
    const bids = book.bids.slice(0, BOOK_LEVELS);
    const cumulative = (rows) => { let sum = 0; return rows.map((r) => ({ ...r, total: (sum += r.size) })); };
    const askRows = cumulative(asks); const bidRows = cumulative(bids);
    const max = Math.max(askRows.at(-1)?.total ?? 0, bidRows.at(-1)?.total ?? 0) || 1;
    const row = (r, side) => `<div class="book-row ${side}"><span>${fmtPrice(r.price, m.priceDecimals)}</span><span>${fmtAmount(r.size, Math.min(m.sizeDecimals, 4))}</span><span>${fmtAmount(r.total, Math.min(m.sizeDecimals, 4))}</span><i style="width:${((r.total / max) * 100).toFixed(1)}%"></i></div>`;
    const bestAsk = asks[0]?.price, bestBid = bids[0]?.price;
    const spread = bestAsk != null && bestBid != null ? bestAsk - bestBid : null;
    const mid = spread != null ? (bestAsk + bestBid) / 2 : null;
    host.innerHTML = `<div class="row-between"><h3>Book</h3>${stateChip}</div>
      <div class="book-head" style="margin-top:10px"><span>Price</span><span>Size ${esc(m.name)}</span><span>Total</span></div>
      <div class="book-table">${[...askRows].reverse().map((r) => row(r, "ask")).join("")}</div>
      <div class="book-mid"><span class="num">${mid == null ? "—" : fmtPrice(mid, m.priceDecimals)} <span class="muted" style="font-weight:600">mid</span></span><span class="num">${spread == null ? "" : `spread ${fmtPrice(spread, m.priceDecimals)} · ${fmtPct(spread / mid, { sign: false, digits: 3 })}`}</span></div>
      <div class="book-table">${bidRows.map((r) => row(r, "bid")).join("")}</div>`;
  }

  function exitRow(label, result) {
    if (!result) return "";
    if (result.error) return `<div><span>${label}</span><b class="muted">${esc(result.error)}</b></div>`;
    return `<div><span>${label}</span><b class="num ${dirClass(result.pnl)}">${fmtUsd(result.pnl, { sign: true })} <span class="muted">· ${fmtPct(result.onMargin)} on margin · ${fmtPct(result.move, { sign: false, digits: 1 })} move</span></b></div>`;
  }

  /// Headlines that mention this market, newest first.
  function paintNews() {
    const host = $("#td-news", root); if (!host) return;
    const m = state.market;
    if (!state.news) { host.innerHTML = `<h3>News</h3><div class="skel" style="margin-top:12px"></div><div class="skel" style="margin-top:8px;width:70%"></div>`; return; }
    const items = state.news.slice(0, 5);
    if (!items.length) { host.innerHTML = `<h3>News</h3><div class="note" style="margin-top:8px">Nothing about ${esc(m.name)} in the last few hours.</div>`; return; }
    host.innerHTML = `<div class="row-between"><h3>News</h3><span class="eyebrow">${esc(m.name)}</span></div><div style="margin-top:6px">${items.map((n) => `
      <a class="td-news-item" href="${esc(n.url)}" target="_blank" rel="noopener noreferrer"><b>${esc(n.title)}</b><span>${esc(n.source)} · ${ago(Number(n.publishedAt))}</span></a>`).join("")}</div>`;
  }

  async function loadNews() {
    try { state.news = (await api(`/api/market-snapshot?view=news&symbols=${encodeURIComponent(state.market.name)}`, { ttl: 120_000 })).items ?? []; }
    catch { state.news = state.news ?? []; }
    paintNews();
  }

  /// The connected or watched wallet's open positions on Perpl, read off the exchange contract.
  async function loadPositions() {
    const wallet = connectedWallet();
    if (!wallet || !/^0x[0-9a-fA-F]{40}$/.test(wallet.address)) { state.positions = null; state.positionsFor = null; paintYours(); return; }
    try {
      const out = await api(`/api/traders?view=trader&address=${encodeURIComponent(wallet.address)}`, { ttl: 8_000 });
      const found = out.traders?.[0];
      state.positions = found?.unreadable ? state.positions ?? [] : (found?.positions ?? []);
      state.positionsFor = wallet.address;
    } catch { state.positions = state.positions ?? []; }
    paintYours();
    if (state.tab === "positions") paintTab();
  }

  // --- trading from this tab

  // Hoisted: paint() runs before this point in mount() and the ticket asks straight away.
  function unlockedPasskey() { return connectedWallet()?.via === "passkey" && isUnlocked(); }

  /// What the big button does right now, in one place.
  function tradeMode() {
    const m = state.market;
    const wallet = connectedWallet();
    if (!wallet) return { label: "Connect wallet", tone: "primary", note: "Sign in with your passkey to trade here, or watch an address." };
    if (wallet.via !== "passkey") return { label: `${cap(state.side)} ${m.name} in Desk`, tone: "side", needsSize: true, note: "A watched or browser wallet cannot sign here. The order is placed in the app." };
    if (!isUnlocked()) return { label: "Unlock to trade", tone: "primary", note: "Your keys left this tab. Unlock with your passkey to sign orders." };
    if (state.trading?.busy) return { label: state.trading.label ?? "Working…", tone: "side", disabled: true, note: "Signed by the key derived from your passkey, in this tab." };
    if (!state.acct) return { label: state.acctBusy ? "Reading your desk…" : "Set up trading here", tone: "primary", disabled: state.acctBusy, note: state.acctBusy ? "Asking Perpl about your account." : "One step: this browser's key is registered with Perpl, signed by your wallet. Nothing is deposited." };
    if (state.acct.error) return { label: "Try again", tone: "primary", note: "Perpl didn't answer. The reason is above; try again in a moment." };
    if (!state.acct.account) return { label: "Open your desk", tone: "primary", note: "Three transactions from your wallet: approve, create the account with a deposit, allow order forwarding." };
    return { label: `${cap(state.side)} ${m.name}`, tone: "side", needsSize: true, note: "Signed by the key derived from your passkey, in this tab. Market order, immediate or cancel." };
  }

  function status(text, kind = "", { spin = false } = {}) {
    const el = $("#td-status", root); if (!el) return;
    el.hidden = !text;
    el.className = `td-status ${kind}`;
    el.innerHTML = text ? `${spin ? `<i class="spin"></i>` : ""}<span>${text}</span>` : "";
  }

  function startAccount() {
    stops.push(onSession(() => { state.acct = null; state.trading = null; paintQuote(); paintDesk(); if (state.tab === "positions") paintTab(); if (unlockedPasskey()) refreshAccount({ enrol: false }); }));
    const onWalletChange = () => { state.acct = null; paintDesk(); if (unlockedPasskey()) refreshAccount({ enrol: false }); };
    document.addEventListener("wallet", onWalletChange);
    stops.push(() => document.removeEventListener("wallet", onWalletChange));
    if (unlockedPasskey()) refreshAccount({ enrol: false });
    stops.push(poll(async () => { if (unlockedPasskey() && state.acct?.account && !state.trading?.busy) await refreshAccount({ enrol: false, quiet: true }); }, 10_000));
  }

  /// Reads the desk behind the unlocked passkey: the exchange, the account on this market's
  /// instance and its open positions. Without a stored key nothing is read unless `enrol`.
  async function refreshAccount({ enrol = false, quiet = false } = {}) {
    if (!unlockedPasskey()) return;
    const address = session().address;
    if (!storedKey(address) && !enrol) { state.acct = null; paintQuote(); paintDesk(); return; }
    if (!quiet) { state.acctBusy = true; paintQuote(); }
    try {
      const ctx = await perplContext();
      const exchange = exchangeOf(ctx);
      const market = marketOf(ctx, state.market.name);
      let walletAusd = null;
      try { walletAusd = await ausdBalance(exchange.token, address); } catch {}
      // Perpl enrols a key only for a wallet with an account, so the chain is asked first; a
      // wallet without one gets the opening form, which enrols after the account exists.
      if (!storedKey(address) && !(await hasAccount(exchange.exchange, address))) {
        state.acct = { ctx, exchange, market, creds: null, snapshot: null, account: null, positions: [], walletAusd, at: Date.now(), error: null };
        state.desk.open = true;
        if (!quiet) status("");
        return;
      }
      const creds = await ensureKey({ onEnrolling: (index) => status(`Registering this browser's key with Perpl${index ? ` (key ${index + 1})` : ""}…`, "", { spin: true }) });
      const snapshot = await perplWallet(creds);
      const account = accountFor(snapshot, market.instanceId);
      const positions = account ? describePositions(await perplPositions(creds), ctx) : [];
      state.acct = { ctx, exchange, market, creds, snapshot, account, positions, walletAusd, at: Date.now(), error: null };
      if (!quiet) status("");
    } catch (error) {
      if (!quiet) { state.acct = { error: error instanceof PerplError ? error.message : `Setting up stopped: ${error.shortMessage ?? error.message}`, account: null, positions: null }; status(state.acct.error, "err"); }
    } finally {
      state.acctBusy = false;
      paintQuote(); paintYours(); paintDesk();
      if (state.tab === "positions") paintTab();
    }
  }

  async function onGo() {
    const mode = tradeMode();
    const wallet = connectedWallet();
    if (!wallet) { $("#connect").click(); return; }
    if (wallet.via !== "passkey") {
      if (!(state.margin > 0)) { $("#td-amount", root).focus(); return; }
      handoff({ title: `${cap(state.side)} ${state.market.name} in Desk`, sub: `${sentence()}. Scan to get Desk and place it there.` });
      return;
    }
    if (!isUnlocked()) { document.dispatchEvent(new CustomEvent("desk:unlock")); return; }
    if (!state.acct || state.acct.error) { await refreshAccount({ enrol: true }); return; }
    if (!state.acct.account) { state.desk.open = true; paintDesk(); $("#td-desk", root)?.scrollIntoView({ behavior: "smooth", block: "center" }); return; }
    if (mode.needsSize && !(state.margin > 0)) { $("#td-amount", root).focus(); return; }
    await placeFromTicket();
  }

  /// The order the ticket describes, signed here and forwarded, then the positions watched
  /// until the fill shows. Perpl fills an immediate-or-cancel order at once or not at all.
  async function placeFromTicket() {
    const q = quote(); if (!q) return;
    const { market, account, creds } = state.acct;
    const sizeRaw = BigInt(Math.floor(q.size * 10 ** market.sizeDecimals));
    if (sizeRaw <= 0n) { status("That size rounds to nothing at this market's lot size.", "err"); return; }
    const leverageHundredths = Math.round(state.leverage * 100);
    if (leverageHundredths > market.maxLeverageHundredths) { status(`This market allows ${market.maxLeverageHundredths / 100}× at most.`, "err"); return; }
    const slippageBps = Math.min(50, market.maxSlippageBps);
    const before = state.acct.positions.find((p) => p.marketId === market.id);
    state.trading = { busy: true, label: "Signing…" }; paintQuote();
    status("Signing the order with your trading key…", "", { spin: true });
    try {
      await placeOrder(creds, { account, market, kind: "open", side: state.side, sizeRaw, leverageHundredths, slippageBps });
      state.trading.label = "Forwarded…"; paintQuote();
      status("Forwarded to Perpl. Watching your positions…", "", { spin: true });
      const filled = await waitForChange((rows) => {
        const now = rows.find((p) => p.marketId === market.id);
        return now && (!before || now.sizeRaw !== before.sizeRaw || now.side !== before.side) ? now : null;
      });
      if (filled) {
        status(`Filled. ${cap(filled.side)} ${fmtAmount(filled.size, market.sizeDecimals)} ${market.symbol} at ${fmtPrice(filled.entry, market.priceDecimals)}.`, "ok");
        toast({ title: `${cap(filled.side)} ${market.symbol} filled`, sub: `${fmtAmount(filled.size, market.sizeDecimals)} ${market.symbol} at ${fmtPrice(filled.entry, market.priceDecimals)} · ${state.leverage}×` });
        state.margin = 0; const amount = $("#td-amount", root); if (amount) amount.value = "";
      } else {
        status("Perpl accepted the order but no fill has shown yet. Within the slippage bound it fills at once or not at all; check Positions in a moment.", "");
      }
      loadPositions();
    } catch (error) {
      status(error instanceof PerplError ? error.message : `The order did not go through: ${error.message}`, "err");
    } finally {
      state.trading = null; paintQuote();
    }
  }

  /// Polls Perpl's positions for up to twelve seconds until `pick` returns a row.
  async function waitForChange(pick) {
    const { ctx, creds } = state.acct;
    for (let i = 0; i < 12; i++) {
      await new Promise((r) => setTimeout(r, 1_000));
      try {
        const rows = describePositions(await perplPositions(creds), ctx);
        state.acct.positions = rows;
        if (state.tab === "positions") paintTab();
        paintYours();
        const hit = pick(rows);
        if (hit !== null && hit !== undefined && hit !== false) return hit;
      } catch {}
    }
    return null;
  }

  async function closeLive(position) {
    if (!unlockedPasskey() || !state.acct?.account || state.trading?.busy) return;
    const { market: current, account, creds, ctx } = state.acct;
    const market = marketOf(ctx, position.market);
    const slippageBps = Math.min(50, market.maxSlippageBps);
    state.trading = { busy: true, label: "Closing…" }; paintQuote();
    status(`Closing ${position.side} ${position.market}…`, "", { spin: true });
    try {
      await placeOrder(creds, { account, market, kind: "close", side: position.side, sizeRaw: position.sizeRaw, slippageBps });
      const gone = await waitForChange((rows) => { const now = rows.find((p) => p.id === position.id); return !now || now.sizeRaw < position.sizeRaw ? true : null; });
      status(gone ? `${cap(position.side)} ${position.market} closed.` : "Perpl accepted the close but the position still shows. Check again in a moment.", gone ? "ok" : "");
      if (gone) toast({ title: `${position.market} closed`, sub: `${fmtAmount(position.size, market.sizeDecimals)} ${position.market}` });
      loadPositions();
    } catch (error) {
      status(error instanceof PerplError ? error.message : `The close did not go through: ${error.message}`, "err");
    } finally {
      state.trading = null; paintQuote();
      void current;
    }
  }

  function paintLivePositions(pane) {
    const rows = [...state.acct.positions].sort((a, b) => (b.market === state.market.name) - (a.market === state.market.name));
    if (!rows.length) { pane.innerHTML = `<div class="empty">Your desk has no open positions on Perpl.</div>`; return; }
    const markOf = (name) => state.rows.find((r) => r.name === name)?.mark ?? null;
    pane.innerHTML = `<div class="table-wrap"><table class="table table-compact"><thead><tr><th class="left">Market</th><th class="left">Side</th><th>Size</th><th>Entry</th><th>Mark</th><th>Collateral</th><th>PnL</th><th></th></tr></thead><tbody>
      ${rows.map((p) => { const mark = markOf(p.market); const pnl = mark == null ? null : (mark - p.entry) * p.size * (p.side === "long" ? 1 : -1); return `<tr ${p.market === state.market.name ? 'style="background:rgba(131,110,249,.06)"' : ""}>
        <td><div class="token">${logo(MARKET_LOGOS[p.market], p.market, 24)}<div class="name"><b>${esc(p.market)}</b></div></div></td>
        <td class="left"><span class="side-chip ${p.side}">${p.side} ${p.leverage}×</span></td>
        <td class="num">${fmtAmount(p.size, p.sizeDecimals)} ${esc(p.market)}</td>
        <td class="num">${fmtPrice(p.entry, p.priceDecimals)}</td>
        <td class="num">${mark == null ? "—" : fmtPrice(mark, p.priceDecimals)}</td>
        <td class="num">${fmtUsd(p.collateral)}</td>
        <td class="num ${pnl == null ? "muted" : dirClass(pnl)}">${pnl == null ? "—" : fmtUsd(pnl, { sign: true })}${pnl != null && p.collateral ? `<div style="font-size:11px">${fmtPct(pnl / p.collateral)}</div>` : ""}</td>
        <td><button class="btn btn-line btn-xs" data-close="${esc(p.id)}" ${state.trading?.busy ? "disabled" : ""}>Close</button></td>
      </tr>`; }).join("")}</tbody></table></div>
      <div class="card-foot"><span>Your desk on Perpl, read with your own key · closes sign here</span><span>${rows.length} open</span></div>`;
    pane.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => { const p = state.acct.positions.find((x) => x.id === b.dataset.close); if (p) closeLive(p); }));
  }

  /// The desk card: balance and Add funds once a desk exists; the opening steps before it.
  function paintDesk() {
    const host = $("#td-desk", root); if (!host) return;
    if (!unlockedPasskey() || !state.acct || state.acct.error) { host.hidden = true; host.innerHTML = ""; return; }
    const { account, exchange, walletAusd } = state.acct;
    const d = state.desk;
    const dec = exchange.tokenDecimals;
    const fmtRaw = (raw) => (raw == null ? "—" : fmtAmount(Number(raw) / 10 ** dec, 2));
    const steps = (names) => `<div class="td-steps">${names.map(([key, label]) => { const step = d.steps.find((s) => s.key === key); return `<div class="${step?.state ?? ""}"><i class="dot"></i><span>${label}</span>${step?.hash ? `<a href="${explorerTx(step.hash)}" target="_blank" rel="noopener">receipt</a>` : ""}</div>`; }).join("")}</div>`;
    host.hidden = false;
    if (!account) {
      const minimum = Number(exchange.minAccountOpenRaw) / 10 ** dec;
      host.innerHTML = `<div class="row-between"><h3>Open your desk</h3><span class="eyebrow">${fmtRaw(walletAusd)} AUSD in wallet</span></div>
        <p class="note" style="margin:8px 0 10px">Your wallet funds a Perpl account in three transactions you sign here: approve, create the account with a deposit (at least ${fmtAmount(minimum, 2)} AUSD), allow order forwarding. Gas is paid in MON.</p>
        <label class="field"><input id="td-desk-amount" inputmode="decimal" placeholder="${fmtAmount(minimum, 2)}" value="${esc(d.amount)}" autocomplete="off"><span class="unit">AUSD</span></label>
        <button class="btn btn-primary btn-block" id="td-desk-open" style="margin-top:10px" ${d.busy ? "disabled" : ""}>${d.busy ? "Opening…" : "Open desk"}</button>
        ${d.steps.length ? steps([["approve", "Approve AUSD for the exchange"], ["create", "Create the account and deposit"], ["forwarding", "Allow order forwarding"], ["enrol", "Register this browser's key"]]) : ""}
        ${d.error ? `<div class="td-status err" style="margin-top:8px"><span>${esc(d.error)}</span></div>` : ""}`;
      $("#td-desk-amount", host).addEventListener("input", (e) => { d.amount = e.target.value; });
      $("#td-desk-open", host).addEventListener("click", openDeskFlow);
      return;
    }
    host.innerHTML = `<div class="row-between"><h3>Your desk</h3><span class="eyebrow">Perpl #${account.id}</span></div>
      <div class="row-kv"><span>In trading</span><b class="num">${fmtRaw(account.balanceRaw)} AUSD</b></div>
      <div class="row-kv"><span>In wallet</span><b class="num">${fmtRaw(walletAusd)} AUSD</b></div>
      <div class="row-kv"><span>Order forwarding</span><b>${account.forwarding ? "on" : "off"}</b></div>
      <div class="row" style="gap:6px;margin-top:10px"><label class="field" style="flex:1"><input id="td-desk-amount" inputmode="decimal" placeholder="Amount" value="${esc(d.amount)}" autocomplete="off"><span class="unit">AUSD</span></label><button class="btn btn-line" id="td-desk-deposit" ${d.busy ? "disabled" : ""}>${d.busy ? "Adding…" : "Add funds"}</button></div>
      ${d.steps.length ? steps([["approve", "Approve AUSD for the exchange"], ["deposit", "Deposit"]]) : ""}
      ${d.error ? `<div class="td-status err" style="margin-top:8px"><span>${esc(d.error)}</span></div>` : ""}
      <div class="note" style="margin-top:8px">Withdrawals are made in the app for now.</div>`;
    $("#td-desk-amount", host).addEventListener("input", (e) => { d.amount = e.target.value; });
    $("#td-desk-deposit", host).addEventListener("click", depositFlow);
  }

  function parseAusd(text, decimals) { const value = Number(String(text).replace(/[^0-9.]/g, "")); return value > 0 ? BigInt(Math.round(value * 10 ** decimals)) : 0n; }
  function stepReport() { return (key, stateName, hash) => { const d = state.desk; const found = d.steps.find((s) => s.key === key); if (found) { found.state = stateName; if (hash) found.hash = hash; } else d.steps.push({ key, state: stateName, hash }); paintDesk(); }; }

  async function openDeskFlow() {
    const d = state.desk; const { exchange } = state.acct; const s = session(); if (!s) return;
    const depositRaw = parseAusd(d.amount, exchange.tokenDecimals);
    if (depositRaw < exchange.minAccountOpenRaw) { d.error = `The deposit must be at least ${fmtAmount(Number(exchange.minAccountOpenRaw) / 10 ** exchange.tokenDecimals, 2)} AUSD.`; paintDesk(); return; }
    d.busy = true; d.error = null; d.steps = []; paintDesk();
    try {
      await openDesk({ account: s.wallet.account, exchange: exchange.exchange, token: exchange.token, depositRaw, report: stepReport() });
      stepReport()("enrol", "sending");
      await ensureKey();
      stepReport()("enrol", "done");
      toast({ title: "Your desk is open", sub: `${fmtAmount(Number(depositRaw) / 10 ** exchange.tokenDecimals, 2)} AUSD in trading` });
      await refreshAccount({ enrol: true });
    } catch (error) {
      d.error = error instanceof PerplError ? error.message : error.shortMessage ?? error.message;
    } finally {
      d.busy = false; paintDesk();
    }
  }

  async function depositFlow() {
    const d = state.desk; const { exchange } = state.acct; const s = session(); if (!s) return;
    const amountRaw = parseAusd(d.amount, exchange.tokenDecimals);
    if (amountRaw <= 0n) { d.error = "Enter an amount."; paintDesk(); return; }
    if (amountRaw < exchange.minDepositRaw) { d.error = `Perpl's minimum deposit is ${fmtAmount(Number(exchange.minDepositRaw) / 10 ** exchange.tokenDecimals, 2)} AUSD.`; paintDesk(); return; }
    d.busy = true; d.error = null; d.steps = []; paintDesk();
    try {
      const hash = await chainDeposit({ account: s.wallet.account, exchange: exchange.exchange, token: exchange.token, amountRaw, report: stepReport() });
      toast({ title: "Deposit sent", sub: `${fmtAmount(Number(amountRaw) / 10 ** exchange.tokenDecimals, 2)} AUSD · ${hash.slice(0, 10)}…` });
      d.amount = "";
      await refreshAccount({ enrol: false, quiet: true });
    } catch (error) {
      d.error = error.shortMessage ?? error.message;
    } finally {
      d.busy = false; paintDesk();
    }
  }

  function paintMarketCard() {
    const m = state.market;
    $("#td-market", root).innerHTML = `<h3 style="margin-bottom:12px">Market</h3><div class="td-kv">
      <div><span>Max leverage</span><b class="num">${m.maxLeverage}×</b></div>
      <div><span>Maintenance margin</span><b class="num">${m.maintenanceMargin ? (10000 / m.maintenanceMargin).toFixed(1) : "—"}%</b></div>
      <div><span>Taker fee</span><b class="num">${(m.takerFee / 1e4).toFixed(3)}%</b></div>
      <div><span>Maker fee</span><b class="num">${(m.makerFee / 1e4).toFixed(3)}%</b></div>
      <div><span>Funding interval</span><b class="num">${interval(m.fundingIntervalSec)}</b></div>
      <div><span>Tick</span><b class="num">${(10 ** -m.priceDecimals).toFixed(m.priceDecimals)}</b></div>
      <div><span>Lot</span><b class="num">${(10 ** -m.sizeDecimals).toFixed(m.sizeDecimals)} ${esc(m.name)}</b></div>
    </div>`;
  }

  function paintCrowdCard() {
    const host = $("#td-crowdcard", root); if (!host) return;
    const row = state.crowd?.find((r) => r.market === state.market.name);
    if (!state.crowd) { host.innerHTML = `<h3>Crowd</h3><div class="skel" style="margin-top:12px"></div><div class="skel" style="margin-top:8px;width:60%"></div>`; return; }
    if (!row) { host.innerHTML = `<h3>Crowd</h3><div class="note" style="margin-top:8px">No open positions on ${esc(state.market.name)} yet.</div>`; return; }
    const longShare = traderShare(row);
    host.innerHTML = `<div class="row-between"><h3>Crowd</h3><span class="eyebrow">${row.traders} trader${row.traders === 1 ? "" : "s"}</span></div>
      <div class="bar"><i style="width:${(longShare * 100).toFixed(1)}%"></i></div>
      <div class="row-between" style="font-size:12px;font-weight:700"><span class="up">Long ${fmtPct(longShare, { sign: false, digits: 0 })} · ${row.longTraders}</span><span class="down">${row.shortTraders} · Short ${fmtPct(1 - longShare, { sign: false, digits: 0 })}</span></div>
      <div class="row-between" style="font-size:11px;margin-top:6px" class="muted"><span class="muted">${fmtUsd(row.longValue, { compact: true })} long</span><span class="muted">${fmtUsd(row.shortValue, { compact: true })} short</span></div>
      ${row.biggest?.address ? `<div class="td-bigpos">${person(row.biggest.address, undefined, { size: 20 })}<span class="side-chip ${row.biggest.side}">${row.biggest.side} ${row.biggest.leverage}×</span><b class="num" style="font-size:12px">${fmtUsd(row.biggest.value, { compact: true })}</b></div>` : ""}`;
    hydratePeople(host);
  }

  async function loadCrowd() {
    try { state.crowd = (await api("/api/traders?view=crowd", { ttl: 20_000 })).markets ?? []; }
    catch { state.crowd = state.crowd ?? []; }
    paintCrowdCard();
    if (state.tab === "crowd") paintTab();
  }

  async function loadTop() {
    try { state.top = (await api("/api/traders?view=top", { ttl: 30_000 })).traders ?? []; }
    catch { state.top = []; }
    if (state.tab === "top") paintTab();
    buildFaces();
  }

  function paintTab() {
    const pane = $("#td-tabpane", root); if (!pane) return;
    const m = state.market;
    if (state.tab === "positions") {
      const wallet = connectedWallet();
      if (wallet?.via === "passkey" && isUnlocked() && state.acct?.positions) { paintLivePositions(pane); return; }
      if (!wallet) {
        pane.innerHTML = `<div class="empty">Connect a wallet, or watch an address, and its open positions on Perpl show here, with the chart still on screen.<br><button class="btn btn-line btn-xs" id="td-pos-connect" style="margin-top:12px">Connect</button></div>`;
        $("#td-pos-connect", pane)?.addEventListener("click", () => $("#connect").click());
        return;
      }
      if (!state.positions || state.positionsFor !== wallet.address) { pane.innerHTML = skeletonRows(3); loadPositions(); return; }
      const rows = [...state.positions].sort((a, b) => (b.market === m.name) - (a.market === m.name) || Number(b.value) - Number(a.value));
      if (!rows.length) { pane.innerHTML = `<div class="empty">${esc(short(wallet.address))} has no open positions on Perpl.</div>`; return; }
      const decimals = (name) => state.rows.find((r) => r.name === name) ?? { priceDecimals: 2, sizeDecimals: 4 };
      pane.innerHTML = `<div class="table-wrap"><table class="table table-compact"><thead><tr><th class="left">Market</th><th class="left">Side</th><th>Size</th><th>Entry</th><th>Mark</th><th>Value</th><th>PnL</th><th></th></tr></thead><tbody>
        ${rows.map((p) => { const d = decimals(p.market); const pnl = Number(p.pnl); return `<tr class="link" data-market="${esc(p.market)}" ${p.market === m.name ? 'style="background:rgba(131,110,249,.06)"' : ""}>
          <td><div class="token">${logo(MARKET_LOGOS[p.market], p.market, 24)}<div class="name"><b>${esc(p.market)}</b></div></div></td>
          <td class="left"><span class="side-chip ${p.side}">${p.side} ${p.leverage ?? "—"}×</span></td>
          <td class="num">${fmtAmount(Number(p.size), d.sizeDecimals)} ${esc(p.market)}</td>
          <td class="num">${fmtPrice(Number(p.entry), d.priceDecimals)}</td>
          <td class="num">${fmtPrice(Number(p.mark), d.priceDecimals)}</td>
          <td class="num">${fmtUsd(p.value, { compact: true })}</td>
          <td class="num ${dirClass(pnl)}">${fmtUsd(pnl, { sign: true })}<div style="font-size:11px">${p.pnlPercent == null ? "" : fmtPct(p.pnlPercent / 100)}</div></td>
          <td><button class="btn btn-line btn-xs" data-manage="${esc(p.market)}">Manage in Desk</button></td>
        </tr>`; }).join("")}</tbody></table></div>
        <div class="card-foot"><span>${esc(short(wallet.address))} · read off the exchange contract every 10 s</span><span>${rows.length} open</span></div>`;
      pane.querySelectorAll("tr[data-market]").forEach((tr) => tr.addEventListener("click", (event) => { if (!event.target.closest("button")) navigate(`/app/trade/${tr.dataset.market}`); }));
      pane.querySelectorAll("[data-manage]").forEach((b) => b.addEventListener("click", () => handoff({ title: `Manage ${b.dataset.manage} in Desk`, sub: "Closing, stops and take profits are signed with Face ID in the app. Scan to open Desk." })));
      return;
    }
    if (state.tab === "crowd") {
      if (!state.crowd) { pane.innerHTML = skeletonRows(3); return; }
      const rows = [...state.crowd].sort((a, b) => (b.market === m.name) - (a.market === m.name) || (Number(b.longValue) + Number(b.shortValue)) - (Number(a.longValue) + Number(a.shortValue)));
      if (!rows.length) { pane.innerHTML = `<div class="empty">No open positions on Perpl right now.</div>`; return; }
      pane.innerHTML = `<div class="table-wrap"><table class="table table-compact"><thead><tr><th class="left">Market</th><th class="left" style="width:150px">Lean</th><th>Long</th><th>Short</th><th>Traders</th><th class="left">Biggest position</th></tr></thead><tbody>
        ${rows.map((r) => { const share = traderShare(r); return `<tr class="link" data-market="${esc(r.market)}" ${r.market === m.name ? 'style="background:rgba(131,110,249,.06)"' : ""}>
          <td><div class="token">${logo(MARKET_LOGOS[r.market], r.market, 24)}<div class="name"><b>${esc(r.market)}</b></div></div></td>
          <td class="left"><div class="bar bar-thin" style="width:130px"><i style="width:${(share * 100).toFixed(1)}%"></i></div><div style="font-size:11px;margin-top:4px" class="num"><span class="up">${fmtPct(share, { sign: false, digits: 0 })}</span> <span class="faint">/</span> <span class="down">${fmtPct(1 - share, { sign: false, digits: 0 })}</span></div></td>
          <td class="num up">${fmtUsd(r.longValue, { compact: true })}<div class="muted" style="font-size:11px">${r.longTraders}</div></td>
          <td class="num down">${fmtUsd(r.shortValue, { compact: true })}<div class="muted" style="font-size:11px">${r.shortTraders}</div></td>
          <td class="num">${r.traders}</td>
          <td class="left">${r.biggest?.address ? `<div class="row" style="gap:8px">${person(r.biggest.address, undefined, { size: 20 })}<span class="side-chip ${r.biggest.side}">${r.biggest.side} ${r.biggest.leverage}×</span><span class="num muted">${fmtUsd(r.biggest.value, { compact: true })}</span></div>` : "—"}</td>
        </tr>`; }).join("")}</tbody></table></div>
        <div class="card-foot"><span>Every open position on every market, read off the exchange contract</span><span>${state.crowd.length} markets</span></div>`;
      pane.querySelectorAll("tr[data-market]").forEach((tr) => tr.addEventListener("click", (event) => { if (!event.target.closest("a")) navigate(`/app/trade/${tr.dataset.market}`); }));
      hydratePeople(pane);
      return;
    }
    if (state.tab === "top") {
      if (!state.top) { pane.innerHTML = skeletonRows(5); return; }
      const rows = state.top.flatMap((t) => t.positions.filter((p) => p.market === m.name).map((p) => ({ ...p, address: t.address, accountId: t.accountId })))
        .sort((a, b) => Number(b.pnl) - Number(a.pnl)).slice(0, 12);
      if (!rows.length) { pane.innerHTML = `<div class="empty">None of the top traders is in ${esc(m.name)} right now.</div>`; return; }
      pane.innerHTML = `<div class="table-wrap"><table class="table table-compact"><thead><tr><th class="left">Trader</th><th class="left">Side</th><th>Size</th><th>Entry</th><th>Mark</th><th>Value</th><th>PnL</th><th></th></tr></thead><tbody>
        ${rows.map((p) => `<tr>
          <td>${person(p.address, undefined, { size: 24 })}</td>
          <td class="left"><span class="side-chip ${p.side}">${p.side} ${p.leverage}×</span></td>
          <td class="num">${fmtAmount(Number(p.size), m.sizeDecimals)} ${esc(m.name)}</td>
          <td class="num">${fmtPrice(Number(p.entry), m.priceDecimals)}</td>
          <td class="num">${fmtPrice(Number(p.mark), m.priceDecimals)}</td>
          <td class="num">${fmtUsd(p.value, { compact: true })}</td>
          <td class="num ${dirClass(Number(p.pnl))}">${fmtUsd(p.pnl, { sign: true })}<div style="font-size:11px">${fmtPct(p.pnlPercent / 100)}</div></td>
          <td><button class="btn btn-line btn-xs" data-follow="${esc(p.address)}" aria-pressed="${isFollowing(p.address)}">${isFollowing(p.address) ? "Following" : "Follow"}</button></td>
        </tr>`).join("")}</tbody></table></div>
        <div class="card-foot"><span>Ranked by unrealised PnL on this market</span><span>${rows.length} of ${state.top.length} top traders</span></div>`;
      pane.querySelectorAll("[data-follow]").forEach((b) => b.addEventListener("click", () => {
        toggleFollow(b.dataset.follow);
        b.textContent = isFollowing(b.dataset.follow) ? "Following" : "Follow";
        b.setAttribute("aria-pressed", String(isFollowing(b.dataset.follow)));
      }));
      hydratePeople(pane);
      return;
    }
    if (state.tab === "trades") {
      pane.innerHTML = skeletonRows(6);
      api(`/api/market-snapshot?symbol=${m.name}&period=1m`, { ttl: 10_000 }).then((out) => {
        if (state.tab !== "trades") return;
        const trades = (out.trades ?? []).slice(0, 40);
        if (!trades.length) { pane.innerHTML = `<div class="empty">No recent trades on the tape.</div>`; return; }
        pane.innerHTML = `<div class="table-wrap"><table class="table table-compact"><thead><tr><th class="left">Wallet</th><th class="left">Type</th><th>USD</th><th>${esc(m.name)}</th><th>Price</th><th class="left">Venue</th><th>Time</th></tr></thead><tbody>
          ${trades.map((t, i) => { const amount = (t.changedTokenInfo ?? []).find((c) => String(c.tokenSymbol ?? "").toUpperCase().includes(m.name))?.amount; return `<tr class="enter" style="--nova-live-transaction-entry-delay:${i * 20}ms">
            <td>${person(t.userAddress, undefined, { size: 20 })}</td>
            <td class="left"><span class="side-chip ${t.type}">${esc(t.type)}</span></td>
            <td class="num">${fmtUsd(t.volume)}</td>
            <td class="num">${amount ? fmtAmount(Number(amount)) : "—"}</td>
            <td class="num">${fmtUsd(t.price)}</td>
            <td class="left muted">${esc(t.dexName ?? "")}</td>
            <td class="num muted">${ago(Number(t.time), { suffix: false })}</td>
          </tr>`; }).join("")}</tbody></table></div>
          <div class="card-foot"><span>Spot ${esc(m.name)} on OKX's DEX tape · the perp settles against the same asset</span><span>last ${trades.length}</span></div>`;
        hydratePeople(pane);
      }).catch(() => { pane.innerHTML = `<div class="empty">The tape could not be read right now.</div>`; });
    }
  }

  function buildChart() {
    const host = $("#td-lw", root);
    if (!window.LightweightCharts || !host) return;
    const LW = LightweightCharts;
    const chart = LW.createChart(host, chartOptions(LW));
    const series = chart.addCandlestickSeries(candleOptions({ priceFormat: { type: "price", precision: state.market.priceDecimals, minMove: 10 ** -state.market.priceDecimals } }));
    const volume = chart.addHistogramSeries({ priceFormat: { type: "volume" }, priceScaleId: "", lastValueVisible: false, priceLineVisible: false });
    volume.priceScale().applyOptions({ scaleMargins: { top: 0.78, bottom: 0 } });
    const fmt = (v) => fmtPrice(v, state.market.priceDecimals);
    state.legend = chartLegend(host.parentElement, { title: `${state.market.name} / AUSD · PERP`, bar: state.bar, format: fmt });
    state.countdown = chartCountdown(host.parentElement, { barSeconds: () => BAR_SECONDS[state.bar] ?? 900, y: () => { const c = state.lastCandle; const y = c ? series.priceToCoordinate(c.close) : null; return y == null || y < 0 ? null : y; } });
    stops.push(() => state.countdown.remove());
    chart.subscribeCrosshairMove((param) => {
      const hit = param?.seriesData?.get(series);
      const i = hit ? state.candles.findIndex((c) => c.time === hit.time) : -1;
      state.legend.update(i >= 0 ? state.candles[i] : state.lastCandle, i >= 0 ? state.candles[i - 1] : state.candles[state.candles.length - 2], state.bar);
    });
    state.markLine = series.createPriceLine({ price: state.market.mark, color: "#836ef9", lineWidth: 1, lineStyle: 2, axisLabelVisible: true, title: "mark" });
    chart.timeScale().subscribeVisibleLogicalRangeChange(() => placeFaces());
    const observer = new ResizeObserver(() => { chart.applyOptions({ width: host.clientWidth, height: host.clientHeight }); placeFaces(); });
    observer.observe(host);
    stops.push(() => observer.disconnect());
    state.chart = chart; state.series = series; state.volume = volume;
  }

  async function loadCandles(reset = false) {
    if (!state.series) return;
    const m = state.market;
    let rows;
    try { rows = (await api(`/api/v1/markets/${m.name}/candles?bar=${state.bar}`, { ttl: 10_000 })).candles ?? []; }
    catch { return; }
    if (!rows.length) return;
    if (reset || state.lastBar !== state.bar) {
      state.series.setData(rows.map((c) => ({ time: c.time, open: c.open, high: c.high, low: c.low, close: c.close })));
      state.volume.setData(rows.map((c) => ({ time: c.time, value: c.volume, color: volumeColor(c.close >= c.open) })));
      state.chart.timeScale().applyOptions({ barSpacing: Math.min(12, Math.max(4, ($("#td-lw", root)?.clientWidth ?? 800) / (rows.length + 8))) });
      state.chart.timeScale().scrollToRealTime();
      state.lastBar = state.bar;
      if (!state.ring.length) state.ring = rows.slice(-30).map((c) => c.close);
      paintSpark();
    } else {
      for (const c of rows.slice(-3)) {
        state.series.update({ time: c.time, open: c.open, high: c.high, low: c.low, close: c.close });
        state.volume.update({ time: c.time, value: c.volume, color: volumeColor(c.close >= c.open) });
      }
    }
    state.candles = rows;
    state.lastCandle = { ...rows[rows.length - 1] };
    state.legend?.update(state.lastCandle, rows[rows.length - 2], state.bar);
    state.countdown?.tick();
    placeFaces();
  }

  // The tape's last candle follows the contract mark between candle polls, so the
  // chart moves every two seconds rather than every minute.
  function tickCandle(mark, at) {
    if (!state.series || !state.lastCandle) return;
    const seconds = BAR_SECONDS[state.bar] ?? 900;
    const slot = Math.floor(at / 1000 / seconds) * seconds;
    let c = state.lastCandle;
    if (slot > c.time) c = { time: slot, open: c.close, high: c.close, low: c.close, close: c.close, volume: 0 };
    c = { ...c, close: mark, high: Math.max(c.high, mark), low: Math.min(c.low, mark) };
    state.lastCandle = c;
    if (state.candles.length && state.candles[state.candles.length - 1].time === c.time) state.candles[state.candles.length - 1] = c; else if (slot > (state.candles[state.candles.length - 1]?.time ?? 0)) state.candles.push(c);
    try { state.series.update({ time: c.time, open: c.open, high: c.high, low: c.low, close: c.close }); } catch { /* older than the series' last bar */ }
    state.legend?.update(c, state.candles[state.candles.length - 2], state.bar);
    state.countdown?.tick();
  }

  function paintSpark() {
    const svg = $("#td-spark", root); if (!svg) return;
    const points = state.ring;
    if (points.length < 2) return;
    const w = 84, h = 26;
    const min = Math.min(...points), max = Math.max(...points), span = max - min || max * 0.0001 || 1;
    const step = (w - 8) / (points.length - 1);
    const coords = points.map((v, i) => [3 + i * step, 3 + (h - 6) * (1 - (v - min) / span)]);
    const d = coords.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
    const color = points[points.length - 1] >= points[0] ? "var(--rise)" : "var(--fall)";
    const [lx, ly] = coords[coords.length - 1];
    svg.innerHTML = `<path class="fill" d="${d} L${lx.toFixed(1)},${h} L3,${h} Z" fill="${color}"/><path d="${d}" stroke="${color}"/><circle class="halo" cx="${lx.toFixed(1)}" cy="${ly.toFixed(1)}" r="4" fill="${color}" opacity=".45"/><circle cx="${lx.toFixed(1)}" cy="${ly.toFixed(1)}" r="2.4" fill="${color}"/>`;
  }

  function buildFaces() {
    const m = state.market;
    const h = head();
    if (!state.top || !h) { state.faces = []; return; }
    state.faces = state.top.flatMap((t) => t.positions.filter((p) => p.market === m.name).map((p) => ({
      address: t.address, side: p.side, leverage: p.leverage, entry: Number(p.entry), value: p.value, pnl: p.pnl, pnlPercent: p.pnlPercent,
      time: Math.floor((h.time - (h.block - p.entryBlock) * h.blockMs) / 1000),
    }))).filter((f) => Number.isFinite(f.time) && f.entry > 0).sort((a, b) => Number(b.value) - Number(a.value)).slice(0, 12);
    const layer = $("#td-faces", root); if (!layer) return;
    layer.innerHTML = state.faces.map((f, i) => {
      const id = knownIdentity(f.address);
      const face = id?.avatar ? `<img src="${esc(id.avatar)}" alt="" referrerpolicy="no-referrer" data-reveal data-fallback>` : "";
      const hue = [...f.address.toLowerCase()].reduce((a, c) => (a * 31 + c.charCodeAt(0)) % 360, 7);
      return `<div class="td-face ${f.side}" data-face="${i}" style="background:linear-gradient(135deg,hsl(${hue} 60% 45%),hsl(${(hue + 40) % 360} 60% 30%));display:none"><span>${esc((id?.name ?? f.address.slice(2, 4)).slice(0, 2).toUpperCase())}</span>${face}</div>`;
    }).join("") + `<div class="td-tip" id="td-tip" hidden></div>`;
    state.faces.forEach((f) => { if (!knownIdentity(f.address)) identity(f.address).then((id) => { if (id?.avatar || id?.name) buildFaces(); }); });
    layer.onmouseover = (event) => {
      const el = event.target.closest("[data-face]"); if (!el) return;
      const f = state.faces[Number(el.dataset.face)]; const id = knownIdentity(f.address);
      const tip = $("#td-tip", layer);
      tip.innerHTML = `<b>${esc(id?.name ?? short(f.address))}</b><span class="muted">${f.side} ${f.leverage}× · entry ${fmtPrice(f.entry, m.priceDecimals)}</span><span class="muted">${fmtUsd(f.value, { compact: true })} · <span class="${dirClass(Number(f.pnl))}">${fmtPct(f.pnlPercent / 100)}</span> · ${ago(f.time * 1000)}</span>`;
      tip.hidden = false;
      const x = parseFloat(el.style.left), y = parseFloat(el.style.top);
      tip.style.left = `${Math.min(x + 16, layer.clientWidth - 220)}px`; tip.style.top = `${Math.max(4, y - 60)}px`;
    };
    layer.onmouseout = (event) => { if (event.target.closest("[data-face]")) $("#td-tip", layer).hidden = true; };
    layer.onclick = (event) => { const el = event.target.closest("[data-face]"); if (el) navigate(`/app/wallet/${state.faces[Number(el.dataset.face)].address}`); };
    placeFaces();
  }

  function placeFaces() {
    const layer = $("#td-faces", root);
    if (!layer || !state.chart || !state.series || !state.faces.length) return;
    const seconds = BAR_SECONDS[state.bar] ?? 900;
    const stacks = new Map();
    for (const el of $$("[data-face]", layer)) {
      const f = state.faces[Number(el.dataset.face)];
      const slot = Math.floor(f.time / seconds) * seconds;
      const x = state.chart.timeScale().timeToCoordinate(slot);
      const y = state.series.priceToCoordinate(f.entry);
      if (x == null || y == null || x < 0) { el.style.display = "none"; continue; }
      const key = `${slot}:${f.side}`;
      const n = stacks.get(key) ?? 0; stacks.set(key, n + 1);
      if (n >= 2) { el.style.display = "none"; continue; }
      el.style.display = "";
      el.style.left = `${x.toFixed(1)}px`;
      el.style.top = `${(y + (f.side === "long" ? -1 : 1) * (14 + n * 9)).toFixed(1)}px`;
    }
  }
}

const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
// Every long on an orderbook has a short against it, so value splits 50/50 by construction; the lean is in who sits on each side.
const traderShare = (r) => (r.longTraders + r.shortTraders > 0 ? r.longTraders / (r.longTraders + r.shortTraders) : 0.5);
const fill = (value, max) => `${max > 1 ? ((value - 1) / (max - 1)) * 100 : 0}%`;
const interval = (seconds) => (seconds == null ? "—" : seconds >= 3600 ? `${Math.round(seconds / 3600)}h` : `${Math.round(seconds / 60)}m`);
function levChips(max) {
  const base = [1, 2, 3, 5, 10, 20, 25, 50].filter((l) => l < max).slice(-4);
  return [...base, max];
}
function watched() {
  try { return new Set(JSON.parse(localStorage.getItem("desk.web.perps") ?? "[]")); } catch { return new Set(); }
}
const skeletonRows = (n) => Array.from({ length: n }, () => `<div class="skel-row"><div class="skel"></div><div class="skel"></div><div class="skel"></div><div class="skel"></div></div>`).join("");
const skeleton = () => `<div></div><div class="card" style="height:600px"></div><div class="card" style="height:600px"></div>`;
void fmtCompact;
