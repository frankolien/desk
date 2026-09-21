import { $, $$, MARKET_LOGOS, ago, api, dirClass, esc, fmtAmount, fmtCompact, fmtPct, fmtPrice, fmtUsd, handoff, head, hydratePeople, identity, knownIdentity, logo, markets, navigate, person, poll, short } from "../app.js";

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
.td-live { display: inline-flex; align-items: center; gap: 8px; margin-left: 14px; vertical-align: middle; }
.td-live .spark { width: 84px; height: 26px; overflow: visible; }
.td-live .halo { transform-box: fill-box; transform-origin: center; animation: tdHalo 1.6s ease-out infinite; }
@keyframes tdHalo { from { transform: scale(1); opacity: .5; } to { transform: scale(2.2); opacity: 0; } }
.td-faces { position: absolute; inset: 0; pointer-events: none; z-index: 3; overflow: hidden; }
.td-face { position: absolute; width: 22px; height: 22px; margin: -11px 0 0 -11px; border-radius: 50%; overflow: hidden; pointer-events: auto; cursor: pointer; box-shadow: 0 0 0 2px var(--ring), 0 0 0 3px #000; background: var(--chip); transition: transform .12s var(--ease); }
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
    market: null, rows: [], bar: "15m", side: "long", margin: 0, leverage: 3, tab: "crowd",
    chart: null, series: null, volume: null, markLine: null, crowd: null, top: null, watched: watched(), lastBar: null,
    ring: [], lastCandle: null, faces: [], showFaces: localStorage.getItem("desk.web.chartfaces") !== "off",
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

  stops.push(poll(loadCandles, 15_000));
  stops.push(poll(loadCrowd, 30_000));
  loadTop();

  return () => { stops.forEach((stop) => stop()); state.chart?.remove(); };

  // ── Painting ─────────────────────────────────────────

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
            </div>
          </div>
          <div class="td-chart"><div class="lw" id="td-lw"></div><div class="td-faces" id="td-faces" ${state.showFaces ? "" : "hidden"}></div></div>
        </div>
        <div class="card">
          <div class="tabs td-tabs" id="td-tabs">
            <button aria-selected="true" data-tab="crowd">Crowd</button>
            <button data-tab="top">Top traders</button>
            ${SPOT[m.name] ? `<button data-tab="trades">Trades</button>` : ""}
          </div>
          <div id="td-tabpane"></div>
        </div>
      </section>
      <aside class="stack" style="gap:16px">
        <div class="card card-pad td-ticket stack" id="td-ticket"></div>
        <div class="card card-pad td-crowd" id="td-crowdcard"></div>
        <div class="card card-pad" id="td-market"></div>
      </aside>`;
    paintList();
    paintHead();
    paintTicket();
    paintMarketCard();
    paintCrowdCard();
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
      state.tab = b.dataset.tab;
      $$("[data-tab]", root).forEach((x) => x.setAttribute("aria-selected", String(x === b)));
      paintTab();
    });
    $("#td-pick", root).addEventListener("click", () => $("#search-open").click());
    $("#td-facetoggle", root).addEventListener("click", (event) => {
      state.showFaces = !state.showFaces;
      localStorage.setItem("desk.web.chartfaces", state.showFaces ? "on" : "off");
      event.currentTarget.setAttribute("aria-pressed", String(state.showFaces));
      $("#td-faces", root).hidden = !state.showFaces;
    });
  }

  function paintList() {
    const host = $("#td-list", root); if (!host) return;
    host.innerHTML = `<div class="card-head" style="padding:12px 14px"><h3>Perps</h3><span class="eyebrow">AUSD</span></div><div style="padding:6px">${state.rows.map((m) => `
      <a class="row-m" href="/app/trade/${esc(m.name)}" data-link aria-current="${m.name === state.market.name}">
        ${logo(MARKET_LOGOS[m.name], m.name, 24)}
        <div class="n"><b>${esc(m.name)}</b><span>UP TO ${m.maxLeverage}×</span></div>
        <div class="p"><b class="num">${fmtPrice(m.mark, m.priceDecimals)}</b><small class="num ${dirClass(m.change)}">${fmtPct(m.change)}</small></div>
      </a>`).join("")}</div>`;
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
    });
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

  // ── Ticket ───────────────────────────────────────────

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
      <div class="cell td-summary" id="td-quote"></div>
      <div class="td-sentence" id="td-sentence"></div>
      <button class="btn btn-lg btn-block ${state.side === "long" ? "btn-rise" : "btn-fall"}" id="td-go"></button>
      <div class="note" style="text-align:center;font-size:11px">Signs with Face ID in the app. Nothing on the web can move money.</div>`;
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
      if (event.target.closest("#td-go")) {
        if (!(state.margin > 0)) { $("#td-amount", ticket).focus(); return; }
        handoff({ title: `${cap(state.side)} ${m.name} in Desk`, sub: `${sentence()}. Scan to open the order in the app and sign it with Face ID.` });
      }
    });
    $("#td-amount", ticket).addEventListener("input", (event) => { state.margin = Number(String(event.target.value).replace(/[^0-9.]/g, "")) || 0; paintQuote(); });
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

  function sentence() {
    const m = state.market;
    const q = quote(); if (!q) return "";
    const parts = [`${cap(state.side)} ${m.name} ${state.leverage}×`, `${fmtAmount(state.margin, 2)} AUSD margin`, `~${fmtAmount(q.notional, 2)} AUSD size`];
    if (state.leverage > 1) parts.push(`liq ${fmtPrice(q.liquidation, m.priceDecimals)} (${fmtPct(q.distance, { sign: false, digits: 1 })} away)`);
    return parts.join(" · ");
  }

  function paintQuote() {
    const m = state.market;
    const q = quote();
    const box = $("#td-quote", root); const line = $("#td-sentence", root); const go = $("#td-go", root);
    if (!box) return;
    go.textContent = `${cap(state.side)} ${m.name} in Desk`;
    if (!q) {
      box.innerHTML = `<div><span>Size</span><b>—</b></div><div><span>Entry</span><b class="num">${fmtPrice(m.mark, m.priceDecimals)}</b></div><div><span>Liquidation</span><b>—</b></div><div><span>Fee</span><b class="muted">${(m.takerFee / 1e4).toFixed(3)}% taker</b></div>`;
      line.textContent = "";
      go.disabled = true;
      return;
    }
    go.disabled = false;
    box.innerHTML = `
      <div><span>Size</span><b class="num">${fmtAmount(q.notional, 2)} AUSD <span class="muted">· ${fmtAmount(q.size, m.sizeDecimals)} ${esc(m.name)}</span></b></div>
      <div><span>Entry</span><b class="num">${fmtPrice(m.mark, m.priceDecimals)}</b></div>
      <div><span>Liquidation</span><b class="num ${state.side === "long" ? "down" : "up"}">${fmtPrice(q.liquidation, m.priceDecimals)} <span class="muted">· ${fmtPct(q.distance, { sign: false, digits: 1 })} away</span></b></div>
      <div><span>Fee</span><b class="num">${fmtAmount(q.fee, 2)} AUSD <span class="muted">· ${(m.takerFee / 1e4).toFixed(3)}%</span></b></div>
      <div><span>Total</span><b class="num">${fmtAmount(q.total, 2)} AUSD</b></div>`;
    line.textContent = sentence();
  }

  // ── Cards on the right ───────────────────────────────

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

  // ── Tabs under the chart ─────────────────────────────

  function paintTab() {
    const pane = $("#td-tabpane", root); if (!pane) return;
    const m = state.market;
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
          <td><button class="btn btn-line btn-xs" data-follow="${esc(p.address)}">Follow</button></td>
        </tr>`).join("")}</tbody></table></div>
        <div class="card-foot"><span>Ranked by unrealised PnL on this market</span><span>${rows.length} of ${state.top.length} top traders</span></div>`;
      pane.querySelectorAll("[data-follow]").forEach((b) => b.addEventListener("click", () => handoff({ title: "Follow in Desk", sub: "Following copies every move in the same block, with Face ID on each order." })));
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

  // ── Chart ────────────────────────────────────────────

  function buildChart() {
    const host = $("#td-lw", root);
    if (!window.LightweightCharts || !host) return;
    const chart = LightweightCharts.createChart(host, {
      layout: { background: { type: "solid", color: "transparent" }, textColor: "#8a8a92", fontFamily: "Manrope, ui-sans-serif, system-ui", fontSize: 11 },
      grid: { vertLines: { color: "rgba(255,255,255,0.04)" }, horzLines: { color: "rgba(255,255,255,0.04)" } },
      rightPriceScale: { borderColor: "rgba(255,255,255,0.08)", scaleMargins: { top: 0.08, bottom: 0.22 } },
      timeScale: { borderColor: "rgba(255,255,255,0.08)", timeVisible: true, secondsVisible: false, rightOffset: 4 },
      crosshair: { mode: 0, vertLine: { color: "rgba(255,255,255,0.2)", labelBackgroundColor: "#222" }, horzLine: { color: "rgba(255,255,255,0.2)", labelBackgroundColor: "#222" } },
      handleScroll: true, handleScale: true,
    });
    const series = chart.addCandlestickSeries({ upColor: "#2fd67b", downColor: "#ff5c5c", borderVisible: false, wickUpColor: "#2fd67b", wickDownColor: "#ff5c5c", priceFormat: { type: "price", precision: state.market.priceDecimals, minMove: 10 ** -state.market.priceDecimals } });
    const volume = chart.addHistogramSeries({ priceFormat: { type: "volume" }, priceScaleId: "", color: "rgba(255,255,255,0.12)" });
    volume.priceScale().applyOptions({ scaleMargins: { top: 0.84, bottom: 0 } });
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
      state.volume.setData(rows.map((c) => ({ time: c.time, value: c.volume, color: c.close >= c.open ? "rgba(47,214,123,0.28)" : "rgba(255,92,92,0.28)" })));
      state.chart.timeScale().scrollToRealTime();
      state.lastBar = state.bar;
      if (!state.ring.length) state.ring = rows.slice(-30).map((c) => c.close);
      paintSpark();
    } else {
      for (const c of rows.slice(-3)) {
        state.series.update({ time: c.time, open: c.open, high: c.high, low: c.low, close: c.close });
        state.volume.update({ time: c.time, value: c.volume, color: c.close >= c.open ? "rgba(47,214,123,0.28)" : "rgba(255,92,92,0.28)" });
      }
    }
    state.lastCandle = { ...rows[rows.length - 1] };
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
    try { state.series.update({ time: c.time, open: c.open, high: c.high, low: c.low, close: c.close }); } catch { /* older than the series' last bar */ }
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

  // ── Faces on the chart: where the top traders got in ────

  function buildFaces() {
    const m = state.market;
    const h = head();
    if (!state.top || !h) { state.faces = []; return; }
    state.faces = state.top.flatMap((t) => t.positions.filter((p) => p.market === m.name).map((p) => ({
      address: t.address, side: p.side, leverage: p.leverage, entry: Number(p.entry), value: p.value, pnl: p.pnl, pnlPercent: p.pnlPercent,
      time: Math.floor((h.time - (h.block - p.entryBlock) * h.blockMs) / 1000),
    }))).filter((f) => Number.isFinite(f.time) && f.entry > 0).slice(0, 40);
    const layer = $("#td-faces", root); if (!layer) return;
    layer.innerHTML = state.faces.map((f, i) => {
      const id = knownIdentity(f.address);
      const face = id?.avatar ? `<img src="${esc(id.avatar)}" alt="" referrerpolicy="no-referrer" onerror="this.remove()">` : "";
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
      if (n >= 4) { el.style.display = "none"; continue; }
      el.style.display = "";
      el.style.left = `${x.toFixed(1)}px`;
      el.style.top = `${(y + (f.side === "long" ? -1 : 1) * (14 + n * 9)).toFixed(1)}px`;
    }
  }
}

// ── Small helpers ──────────────────────────────────────

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
