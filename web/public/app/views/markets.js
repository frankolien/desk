import { $, $$, esc, api, poll, fmtUsd, fmtPrice, fmtPct, fmtAmount, short, ago, dirClass, logo, sparkline, navigate, MARKET_LOGOS } from "../app.js";

const STYLE = `<style>
.mk { display: grid; grid-template-columns: minmax(0, 1fr) 300px; gap: 20px; align-items: start; }
@media (max-width: 1100px) { .mk { grid-template-columns: minmax(0, 1fr); } }
.mk-head { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; margin-bottom: 16px; }
.mk-head .mk-right { margin-left: auto; }
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
</style>`;

const TABS = [["perps", "Perps"], ["trending", "Trending"], ["movers", "Movers"], ["monad", "Monad"]];
const SKELETON = `<div class="skel-row"><div class="skel"></div><div class="skel"></div><div class="skel"></div><div class="skel"></div></div>`.repeat(6);

/// Runs jobs `limit` at a time so a page of sparklines does not burst the API.
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

function risk(t) {
  const flag = String(t.riskLevel ?? "").toLowerCase();
  const checked = t.riskLevel != null || t.liquidity != null || t.communityRecognized != null;
  let weight = 0;
  if (flag === "high" || Number(flag) >= 3) weight += 6;
  else if (flag === "medium" || Number(flag) === 2) weight += 3;
  if (t.liquidity != null) weight += t.liquidity < 10_000 ? 6 : t.liquidity < 50_000 ? 3 : 0;
  if (t.communityRecognized === false) weight += 1;
  const level = !checked ? "unchecked" : weight >= 6 ? "high" : weight >= 3 ? "caution" : "low";
  const label = { low: "Low risk", caution: "Caution", high: "High risk", unchecked: "Not checked" }[level];
  return `<span class="risk ${level}"><i></i>${label}</span>`;
}

const interval = (sec) => (sec >= 3600 ? `${Math.round(sec / 3600)}h` : `${Math.round(sec / 60)}m`);

function perpRow(m, i) {
  return `<tr class="link" data-href="/app/trade/${esc(m.name)}">
    <td class="rank">${i + 1}</td>
    <td class="left"><div class="token">${logo(MARKET_LOGOS[m.name], m.name, 32)}
      <div class="name"><b>${esc(m.name)} <small>${esc(m.name)}-PERP</small></b><i class="chip-brand mk-lev">up to ${esc(m.maxLeverage)}×</i></div></div></td>
    <td class="num" data-mk-mark="${esc(m.name)}">${fmtPrice(m.mark, m.priceDecimals)}</td>
    <td data-spark="${esc(m.name)}">${sparkline([])}</td>
    <td class="num ${dirClass(m.change)}" data-mk-change="${esc(m.name)}">${fmtPct(m.change)}</td>
    <td class="num">${fmtUsd(m.volume24h, { compact: true })}</td>
    <td class="num">${fmtUsd(m.openInterest, { compact: true })}</td>
    <td class="num"><span class="${m.fundingRate > 0 ? "up" : m.fundingRate < 0 ? "down" : ""}">${fmtPct(m.fundingRate, { digits: 4 })}</span><small class="muted"> / ${interval(m.fundingIntervalSec)}</small></td>
    <td class="num">${fmtUsd(m.tvl, { compact: true })}</td>
    <td class="mk-trade"><a class="btn btn-primary btn-xs" href="/app/trade/${esc(m.name)}" data-link>Trade</a></td>
  </tr>`;
}

function tokenRow(t, i) {
  const change = t.change == null ? null : t.change / 100;
  return `<tr class="link" data-href="/app/token/${esc(t.chainIndex)}/${esc(t.contract)}">
    <td class="rank">${i + 1}</td>
    <td class="left"><div class="token">${logo(t.logoURL, t.symbol, 32)}
      <div class="name"><b>${esc(t.symbol)} <small>${esc(t.name)}</small></b><span>${esc(t.chainName)} · ${esc(short(t.contract))}</span></div></div></td>
    <td class="num">${fmtUsd(t.price)}</td>
    <td data-spark="${esc(t.id)}">${sparkline([])}</td>
    <td class="num">${fmtUsd(t.marketCap, { compact: true })}</td>
    <td class="num">${fmtUsd(t.liquidity, { compact: true })}</td>
    <td class="num">${fmtUsd(t.volume24H, { compact: true })}</td>
    <td class="num ${dirClass(change)}">${fmtPct(change)}</td>
    <td class="num">${fmtAmount(t.holders, 0)}</td>
    <td>${risk(t)}</td>
    <td class="mk-trade"><a class="btn btn-primary btn-xs" href="/app/token/${esc(t.chainIndex)}/${esc(t.contract)}" data-link>Trade</a></td>
  </tr>`;
}

const PERP_HEAD = `<tr><th>#</th><th class="left">Market</th><th>Mark</th><th>Live</th><th>24h</th><th>Volume</th><th>Open int.</th><th>Funding</th><th>TVL</th><th class="mk-trade"></th></tr>`;
const TOKEN_HEAD = `<tr><th>#</th><th class="left">Token</th><th>Price</th><th>Live</th><th>MCap</th><th>Liquidity</th><th>Volume</th><th>24h</th><th>Holders</th><th>Risk</th><th class="mk-trade"></th></tr>`;

export default async function mount(el, params) {
  let dead = false;
  let tab = TABS.some(([id]) => id === params.query?.tab) ? params.query.tab : "perps";
  let perps = [];
  let tokens = [];
  let tokensAt = null;
  let perpsAt = null;
  const sparks = new Map();
  const run = queue(3);

  el.innerHTML = `${STYLE}
  <div class="mk-head">
    <h1>Markets</h1>
    <div class="seg" id="mk-tabs" role="tablist">${TABS.map(([id, label]) => `<button role="tab" data-tab="${id}" aria-selected="${id === tab}">${label}</button>`).join("")}</div>
    <div class="seg seg-sm mk-right"><button aria-selected="true">24h</button></div>
  </div>
  <div class="mk">
    <div class="card">
      <div id="mk-body">${SKELETON}</div>
      <div class="card-foot"><span id="mk-foot">Loading</span></div>
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
  const foot = $("#mk-foot", el);

  $("#mk-tabs", el).addEventListener("click", (event) => {
    const button = event.target.closest("[data-tab]");
    if (!button || button.dataset.tab === tab) return;
    tab = button.dataset.tab;
    for (const b of $$("[data-tab]", el)) b.setAttribute("aria-selected", String(b.dataset.tab === tab));
    history.replaceState({}, "", tab === "perps" ? "/app/markets" : `/app/markets?tab=${tab}`);
    paint();
  });

  body.addEventListener("click", (event) => {
    if (event.target.closest("a, button")) return;
    const row = event.target.closest("tr[data-href]");
    if (row) navigate(row.dataset.href);
  });

  const table = (head, rows) => `<div class="table-wrap"><table class="table"><thead>${head}</thead><tbody>${rows}</tbody></table></div>`;

  function visibleTokens() {
    if (tab === "movers") return [...tokens].sort((a, b) => Math.abs(b.change ?? 0) - Math.abs(a.change ?? 0));
    if (tab === "monad") return tokens.filter((t) => String(t.chainIndex) === "143");
    return tokens;
  }

  function paintFoot() {
    if (tab === "perps") foot.textContent = perpsAt ? `Showing ${perps.length} markets · Perpl · updated ${ago(perpsAt)}` : "Loading";
    else foot.textContent = tokensAt ? `Showing ${visibleTokens().length} tokens · OKX · updated ${ago(tokensAt)}` : "Loading";
  }

  function paint() {
    if (dead) return;
    if (tab === "perps") {
      if (perps === null) body.innerHTML = `<div class="empty">Markets could not be read right now.</div>`;
      else if (!perpsAt) body.innerHTML = SKELETON;
      else body.innerHTML = table(PERP_HEAD, perps.map(perpRow).join(""));
    } else {
      const rows = visibleTokens();
      if (tokens === null) body.innerHTML = `<div class="empty">Trending could not be read right now.</div>`;
      else if (!tokensAt) body.innerHTML = SKELETON;
      else if (!rows.length) body.innerHTML = `<div class="empty">Nothing trending on Monad in this window.</div>`;
      else body.innerHTML = table(TOKEN_HEAD, rows.map(tokenRow).join(""));
    }
    paintFoot();
    for (const cell of $$("[data-spark]", body)) {
      const key = cell.dataset.spark;
      if (sparks.has(key)) { cell.innerHTML = sparkline(sparks.get(key)); continue; }
      run(() => loadSpark(key)).then((closes) => {
        if (dead || !closes) return;
        sparks.set(key, closes);
        const live = body.querySelector(`[data-spark="${CSS.escape(key)}"]`);
        if (live) live.innerHTML = sparkline(closes);
      });
    }
  }

  async function loadSpark(key) {
    if (dead) return null;
    if (key.includes(":")) {
      const [chainIndex, address] = key.split(":");
      const out = await api(`/api/market-snapshot?chainIndex=${encodeURIComponent(chainIndex)}&address=${encodeURIComponent(address)}&period=5m`, { ttl: 60_000 }).catch(() => null);
      return (out?.candles ?? []).map((row) => Number(row[4])).reverse().slice(-40);
    }
    const out = await api(`/api/v1/markets/${encodeURIComponent(key)}/candles?bar=15m`, { ttl: 60_000 }).catch(() => null);
    return (out?.candles ?? []).map((c) => c.close).slice(-40);
  }

  function updatePerps(rows) {
    const previous = new Map(perps.map((m) => [m.name, m.mark]));
    perps = [...rows].sort((a, b) => (b.volume24h ?? 0) - (a.volume24h ?? 0));
    perpsAt = Date.now();
    if (tab !== "perps") return;
    if (!body.querySelector("[data-mk-mark]")) { paint(); return; }
    for (const m of perps) {
      const cell = body.querySelector(`[data-mk-mark="${CSS.escape(m.name)}"]`);
      if (!cell) continue;
      const was = previous.get(m.name);
      cell.textContent = fmtPrice(m.mark, m.priceDecimals);
      if (was != null && was !== m.mark) { cell.classList.remove("flash-up", "flash-down"); void cell.offsetWidth; cell.classList.add(m.mark > was ? "flash-up" : "flash-down"); }
      const change = body.querySelector(`[data-mk-change="${CSS.escape(m.name)}"]`);
      if (change) { change.textContent = fmtPct(m.change); change.className = `num ${dirClass(m.change)}`; }
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

  const stopTokens = poll(async () => {
    try {
      const out = await api("/api/token-discovery", { ttl: 30_000 });
      tokens = out.tokens ?? [];
      tokensAt = out.observedAt ?? Date.now();
      if (tab !== "perps") paint();
    } catch {
      if (!tokensAt) { tokens = null; if (tab !== "perps") paint(); }
    }
  }, 30_000);

  const stopFoot = poll(paintFoot, 10_000);

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
  }, 30_000);

  paint();
  return () => { dead = true; stopPerps(); stopTokens(); stopFoot(); stopRail(); };
}
