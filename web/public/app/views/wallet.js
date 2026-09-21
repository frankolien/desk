import { $, $$, esc, api, fmtUsd, fmtPct, fmtAmount, short, ago, dirClass, logo, nativeLogo, person, hydratePeople, handoff, navigate } from "../app.js";

const CSS = `<style>
.wl { max-width: 760px; margin: 0 auto; display: grid; gap: 26px; }
.wl-head { display: flex; align-items: flex-start; gap: 16px; flex-wrap: wrap; }
.wl-head .logo-68 { font-size: 24px; }
.wl-who { flex: 1; min-width: 240px; display: grid; gap: 7px; }
.wl-name { font-size: 22px; font-weight: 800; letter-spacing: -0.02em; line-height: 1.15; }
.wl-status { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 13px; color: var(--muted); }
.wl-status .via { font-size: 10px; font-weight: 600; color: var(--muted); padding: 2px 5px; border-radius: 4px; background: var(--chip); }
.wl-status .chip { height: 24px; padding: 0 9px; font-size: 11px; }
.wl-addr { display: inline-flex; align-items: center; gap: 4px; font-family: var(--mono); font-size: 12px; color: var(--text-2); }
.wl-addr button, .wl-addr a { display: inline-flex; width: 24px; height: 24px; align-items: center; justify-content: center; border-radius: 6px; color: var(--muted); }
.wl-addr button:hover, .wl-addr a:hover { background: var(--chip); color: var(--text); }
.wl-addr svg { width: 14px; height: 14px; }
.wl-pnl { display: grid; gap: 8px; }
.wl-big { font-family: var(--rounded); font-size: 40px; font-weight: 700; letter-spacing: -0.03em; line-height: 1.05; font-variant-numeric: tabular-nums; }
.wl-big small { font-size: 0.72em; font-weight: 400; opacity: 0.75; }
.wl-chart { height: 180px; margin: 6px 0 4px; }
.wl-chart.blank { height: 60px; }
.wl-cells { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
.wl-cells .num { font-size: 20px; font-weight: 700; }
.wl-chains { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px; }
.wl-chain { display: inline-flex; align-items: center; gap: 5px; height: 22px; padding: 0 7px 0 3px; border-radius: 999px; background: var(--chip); font-size: 11px; font-weight: 600; color: var(--text-2); }
.wl-list { display: grid; }
.wl-row { display: grid; grid-template-columns: 36px minmax(0, 1fr) auto; align-items: center; gap: 12px; padding: 11px 4px; border-bottom: 1px solid var(--line); color: inherit; }
.wl-row:last-child { border-bottom: 0; }
a.wl-row:hover { background: rgba(255, 255, 255, 0.025); }
.wl-row .name { display: grid; gap: 1px; min-width: 0; }
.wl-row .name b { font-size: 14px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wl-row .name span { font-size: 12px; color: var(--muted); }
.wl-row .right { display: grid; gap: 1px; text-align: right; }
.wl-row .right b { font-size: 14px; font-weight: 700; }
.wl-row .right span { font-size: 12px; }
.wl-side { display: grid; place-items: center; }
.wl-foot { padding: 12px 4px 0; font-size: 12px; color: var(--faint); }
.wl-reading { padding: 18px 4px; font-size: 13px; color: var(--muted); }
.wl-open { display: flex; gap: 8px; align-items: center; }
.wl-open .field { flex: 1; }
.wl-recent { display: grid; gap: 4px; }
.wl-recent .person { padding: 6px 4px; border-radius: 8px; }
.wl-recent .person:hover { background: var(--chip); }
@media (max-width: 720px) { .wl-big { font-size: 34px; } .wl-open { flex-wrap: wrap; } .wl-open .field { flex-basis: 100%; } }
</style>`;

const EVM = /^0x[0-9a-fA-F]{40}$/;
const SOL = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const SOURCE_LABEL = { nad: ".nad", nadfun: "nad.fun", ens: "ENS", farcaster: "Farcaster" };
const DAY = 86_400_000;
const WINDOWS = [["7d", "7D", 7 * DAY], ["30d", "30D", 30 * DAY], ["all", "ALL", Infinity]];
const RECENT_KEY = "desk.web.wallet";

const hue = (text) => [...String(text)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);
const cssColor = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const rgba = (hex, a) => `rgba(${parseInt(hex.slice(1, 3), 16)}, ${parseInt(hex.slice(3, 5), 16)}, ${parseInt(hex.slice(5, 7), 16)}, ${a})`;

const recent = () => { try { return JSON.parse(localStorage.getItem(RECENT_KEY) ?? "[]").filter((a) => typeof a === "string"); } catch { return []; } };
const remember = (address) => { try { localStorage.setItem(RECENT_KEY, JSON.stringify([address, ...recent().filter((a) => a.toLowerCase() !== address.toLowerCase())].slice(0, 5))); } catch { /* private window */ } };

export default async function mount(el, params) {
  if (!params.address) return mountPicker(el);
  const address = params.address;
  const isEvm = EVM.test(address);
  el.innerHTML = `${CSS}<div class="wl">
    <div class="wl-head"><div class="skel" style="width:68px;height:68px;border-radius:50%"></div><div class="wl-who"><div class="skel" style="width:180px;height:22px"></div><div class="skel" style="width:260px"></div></div></div>
    <div><div class="skel" style="width:120px;height:40px"></div></div>
    <div class="wl-list">${`<div class="skel-row"><div class="skel"></div><div class="skel"></div><div class="skel"></div><div class="skel"></div></div>`.repeat(5)}</div>
  </div>`;

  let data;
  try {
    data = await api(`/api/activity?view=wallet&address=${encodeURIComponent(address)}`, { ttl: 30_000 });
  } catch {
    el.innerHTML = `${CSS}<div class="wl"><div class="empty">This wallet could not be read right now.</div></div>`;
    return;
  }
  if (!el.isConnected) return;
  remember(address);

  const id = data.identity ?? null;
  const name = id?.name ?? short(address);
  const ledger = data.ledger ?? { status: "unavailable" };
  const ready = ledger.status === "ready";
  const indexing = ledger.status === "indexing";
  const logos = data.logos ?? {};
  const holdings = [...(data.holdings ?? [])].sort((a, b) => (b.value ?? 0) - (a.value ?? 0));
  const ledgerTokens = new Map((ledger.tokens ?? []).map((t) => [String(t.token).toLowerCase(), t]));
  const trades = [...(ledger.trades ?? [])].sort((a, b) => b.time - a.time);
  const explorer = isEvm ? `https://monadscan.com/address/${address}` : `https://solscan.io/account/${address}`;
  const tokenLogo = (chainIndex, contract) => logos[`${chainIndex}:${contract ?? ""}`] ?? (contract ? "" : nativeLogo(chainIndex));

  const face = id?.avatar
    ? `<span class="logo logo-68"><img src="${esc(id.avatar)}" alt="" referrerpolicy="no-referrer" onerror="this.remove()"></span>`
    : `<span class="logo logo-68" style="background:linear-gradient(135deg,hsl(${hue(address)} 60% 45%),hsl(${(hue(address) + 40) % 360} 60% 30%))"></span>`;
  const status = [
    id?.name && id?.source ? `<span class="via">${esc(SOURCE_LABEL[id.source] ?? id.source)}</span>` : "",
    id?.perplAccount ? `<span class="chip chip-brand">Perpl #${esc(id.perplAccount)}</span>` : "",
    ...(data.labels ?? []).filter((l) => l.code !== "perpl").map((l) => `<span class="chip">${esc(l.text)}</span>`),
    `<span class="wl-addr">${esc(short(address))}
      <button type="button" data-copy aria-label="Copy address"><svg><use href="#i-copy"/></svg></button>
      <a href="${esc(explorer)}" target="_blank" rel="noopener" aria-label="Open in explorer"><svg><use href="#i-ext"/></svg></a></span>`,
  ].join("");

  const chains = [...(data.chains ?? [])].sort((a, b) => (b.value ?? 0) - (a.value ?? 0)).slice(0, 4);
  const chainChips = chains.length ? `<div class="wl-chains">${chains.map((c) => `<span class="wl-chain">${logo(nativeLogo(c.chainIndex), c.chain, 16)}${fmtUsd(c.value, { compact: true })}</span>`).join("")}</div>` : "";
  const unreal = ready ? ledger.unrealized : null;
  const tab0 = ["positions", "closed", "activity"].includes(params.query?.tab) ? params.query.tab : "positions";
  let window_ = WINDOWS.some(([k]) => k === params.query?.window) ? params.query.window : "7d";

  el.innerHTML = `${CSS}<div class="wl enter">
    <div class="wl-head">
      ${face}
      <div class="wl-who"><div class="wl-name">${esc(name)}</div><div class="wl-status">${status}</div></div>
      ${isEvm ? `<button class="btn btn-line" type="button" data-follow>Follow in Desk</button>` : ""}
    </div>
    <div class="wl-pnl">
      <div class="row-between"><span class="eyebrow">PNL</span>
        <div class="seg seg-sm" role="tablist" data-windows>${WINDOWS.map(([k, label]) => `<button type="button" role="tab" data-window="${k}" aria-selected="${k === window_}">${label}</button>`).join("")}</div></div>
      <div data-pnl></div>
      <div class="wl-cells">
        <div class="cell stat"><span class="eyebrow">Portfolio value</span><span class="num">${fmtUsd(data.portfolio, { compact: true })}</span>${chainChips}</div>
        <div class="cell stat"><span class="eyebrow">Unrealized</span><span class="num ${dirClass(unreal)}">${indexing ? "…" : fmtUsd(unreal, { sign: true })}</span></div>
      </div>
    </div>
    <div>
      <div class="tabs" role="tablist" data-tabs>
        ${["positions", "closed", "activity"].map((t) => `<button type="button" role="tab" data-tab="${t}" aria-selected="${t === tab0}">${t[0].toUpperCase()}${t.slice(1)}</button>`).join("")}
      </div>
      <div class="wl-list" data-list></div>
      <div class="wl-foot" data-foot></div>
    </div>
  </div>`;

  $("[data-copy]", el).addEventListener("click", async (event) => {
    const button = event.currentTarget;
    try { await navigator.clipboard.writeText(address); } catch { return; }
    button.innerHTML = `<svg><use href="#i-check"/></svg>`;
    setTimeout(() => { button.innerHTML = `<svg><use href="#i-copy"/></svg>`; }, 1200);
  });
  $("[data-follow]", el)?.addEventListener("click", () => handoff({ title: `Follow ${name} in Desk`, sub: "Tracking pushes every buy and sell to your phone; following copies them." }));

  const reading = `<div class="wl-reading pulse">Reading this wallet's Monad history…</div>`;

  // ── PnL ──
  let chart = null;
  const pnlHost = $("[data-pnl]", el);
  function paintPnl() {
    if (chart) { chart.remove(); chart = null; }
    if (indexing) { pnlHost.innerHTML = reading; return; }
    const [, label, span] = WINDOWS.find(([k]) => k === window_);
    const stats = !ready ? null : window_ === "7d" ? ledger.last7d : window_ === "30d" ? ledger.last30d : { realized: ledger.realized, trades: trades.length, winRate: ledger.winRate };
    const realized = stats?.realized ?? null;
    const sub = [label, "Realized", stats?.trades != null ? `${stats.trades} ${stats.trades === 1 ? "trade" : "trades"}` : null, stats?.winRate != null ? `win rate ${Math.round(stats.winRate * 100)}%` : null].filter(Boolean).join(" · ");
    const big = fmtUsd(realized, { sign: true }).replace(/(\.\d{2})$/, "<small>$1</small>");
    const points = series(span);
    pnlHost.innerHTML = `<div class="wl-big ${realized == null ? "muted" : dirClass(realized)}">${big}</div><div class="sub">${esc(sub)}</div><div class="wl-chart${points.length < 2 ? " blank" : ""}" data-chart></div>`;
    if (points.length >= 2 && window.LightweightCharts) drawChart($("[data-chart]", pnlHost), points);
  }
  function series(span) {
    if (!ready) return [];
    const start = span === Infinity ? Math.min(...trades.map((t) => t.time)) - 3600_000 : Date.now() - span;
    const sells = trades.filter((t) => t.side === "sell" && t.gain != null && t.time > start).sort((a, b) => a.time - b.time);
    if (!sells.length) return [];
    // Cumulative realized PnL holds between sells; ~120 evenly spaced samples carry the line edge to edge.
    const now = Date.now();
    const step = Math.max((now - start) / 120, 60_000);
    const stamps = new Set([start, now, ...sells.map((t) => t.time)]);
    for (let t = start + step; t < now; t += step) stamps.add(Math.round(t));
    let sum = 0;
    let i = 0;
    const points = [];
    for (const stamp of [...stamps].sort((a, b) => a - b)) {
      while (i < sells.length && sells[i].time <= stamp) sum += Number(sells[i++].gain) || 0;
      const time = Math.floor(stamp / 1000);
      if (points.length && points[points.length - 1].time === time) points[points.length - 1].value = sum;
      else points.push({ time, value: sum });
    }
    return points;
  }
  function drawChart(host, points) {
    const values = points.map((p) => p.value);
    const low = Math.min(0, ...values);
    const high = Math.max(0, ...values);
    const pad = Math.max((high - low) * 0.12, 1);
    const color = cssColor(points[points.length - 1].value >= 0 ? "--rise" : "--fall");
    chart = LightweightCharts.createChart(host, {
      autoSize: true,
      layout: { background: { type: "solid", color: "transparent" }, textColor: cssColor("--faint"), fontFamily: getComputedStyle(document.body).fontFamily, attributionLogo: false },
      grid: { vertLines: { visible: false }, horzLines: { visible: false } },
      rightPriceScale: { visible: false },
      leftPriceScale: { visible: false },
      timeScale: { visible: false, fixLeftEdge: true, fixRightEdge: true },
      crosshair: { vertLine: { visible: false, labelVisible: false }, horzLine: { visible: false, labelVisible: false } },
      handleScroll: false,
      handleScale: false,
    });
    const area = chart.addAreaSeries({
      lineColor: color, topColor: rgba(color, 0.25), bottomColor: rgba(color, 0), lineWidth: 2,
      priceLineVisible: false, lastValueVisible: false, crosshairMarkerRadius: 3,
      autoscaleInfoProvider: () => ({ priceRange: { minValue: low - pad, maxValue: high + pad } }),
    });
    area.setData(points);
    chart.timeScale().fitContent();
  }
  $("[data-windows]", el).addEventListener("click", (event) => {
    const button = event.target.closest("[data-window]");
    if (!button) return;
    window_ = button.dataset.window;
    $$("[data-window]", el).forEach((b) => b.setAttribute("aria-selected", String(b === button)));
    paintPnl();
  });
  paintPnl();

  // ── Tabs ──
  const list = $("[data-list]", el);
  const foot = $("[data-foot]", el);
  const tabs = {
    positions() {
      if (!holdings.length) return [`<div class="empty">Nothing held here.</div>`, ""];
      const rows = holdings.map((h) => {
        const lt = h.chainIndex === "143" && h.contract ? ledgerTokens.get(h.contract.toLowerCase()) : null;
        const cost = lt && lt.averageCost != null && lt.holding ? lt.averageCost * lt.holding : 0;
        const under = lt && cost > 0 && lt.unrealized != null
          ? `<span class="num ${dirClass(lt.unrealized)}">${fmtPct(lt.unrealized / cost)}</span>`
          : `<span class="muted">${fmtAmount(h.balance)} ${esc(h.symbol)}</span>`;
        const inner = `${logo(tokenLogo(h.chainIndex, h.contract), h.symbol, 36)}
          <div class="name"><b>${esc(h.symbol)}</b><span>${esc(h.chain)}</span></div>
          <div class="right"><b class="num">${fmtUsd(h.value)}</b>${under}</div>`;
        return h.contract ? `<a class="wl-row" href="/app/token/${esc(h.chainIndex)}/${esc(h.contract)}" data-link>${inner}</a>` : `<div class="wl-row">${inner}</div>`;
      });
      return [rows.join(""), `Showing ${rows.length} of ${holdings.length} assets`];
    },
    closed() {
      if (indexing) return [reading, ""];
      const closed = (ledger.tokens ?? []).filter((t) => Math.abs(t.holding ?? 0) < 1e-9 && t.realized).sort((a, b) => Math.abs(b.realized) - Math.abs(a.realized));
      if (!closed.length) return [`<div class="empty">No closed positions on record.</div>`, ""];
      const rows = closed.map((t) => `<a class="wl-row" href="/app/token/143/${esc(t.token)}" data-link>
        ${logo(logos[`143:${String(t.token).toLowerCase()}`], t.symbol, 36)}
        <div class="name"><b>${esc(t.symbol)}</b><span>Monad</span></div>
        <div class="right"><b class="num ${dirClass(t.realized)}">${fmtUsd(t.realized, { sign: true })}</b><span class="muted">Realized</span></div></a>`);
      return [rows.join(""), `Showing ${rows.length} of ${closed.length} closed positions`];
    },
    activity() {
      if (indexing) return [reading, ""];
      if (!trades.length) return [`<div class="empty">No trades on record.</div>`, ""];
      const shown = trades.slice(0, 60);
      const rows = shown.map((t) => `<div class="wl-row">
        <span class="wl-side"><span class="side-chip ${t.side}">${t.side === "buy" ? "BUY" : "SELL"}</span></span>
        <div class="name"><b>${esc(t.symbol)}</b><span>${fmtAmount(t.amount)} ${esc(t.symbol)}${t.price != null ? ` · ${fmtUsd(t.price)}` : ""}</span></div>
        <div class="right"><b class="num">${fmtUsd(t.value)}</b><span>${t.side === "sell" && t.gain != null ? `<span class="num ${dirClass(t.gain)}">${fmtUsd(t.gain, { sign: true })}</span> ` : ""}<span class="faint">${esc(ago(t.time))}</span></span></div></div>`);
      return [rows.join(""), `Showing ${shown.length} of ${trades.length} trades`];
    },
  };
  function paintTab(tab) {
    const [html, footer] = tabs[tab]();
    list.innerHTML = html;
    foot.textContent = footer;
    foot.hidden = !footer;
  }
  $("[data-tabs]", el).addEventListener("click", (event) => {
    const button = event.target.closest("[data-tab]");
    if (!button) return;
    $$("[data-tab]", el).forEach((b) => b.setAttribute("aria-selected", String(b === button)));
    paintTab(button.dataset.tab);
  });
  paintTab(tab0);

  return () => { if (chart) chart.remove(); };
}

async function mountPicker(el) {
  const list = recent();
  el.innerHTML = `${CSS}<div class="wl enter">
    <div class="card card-pad stack">
      <h2>Your portfolio</h2>
      <form class="wl-open" data-form>
        <label class="field"><input type="text" placeholder="0x…, name.nad, name.eth or @handle" autocomplete="off" spellcheck="false" autofocus></label>
        <button class="btn btn-primary" type="submit">Open</button>
        ${window.ethereum ? `<button class="btn btn-ghost" type="button" data-connected>Use connected wallet</button>` : ""}
      </form>
      <div class="sub" data-hint hidden></div>
      ${list.length ? `<div class="stack" style="gap:6px"><span class="eyebrow">Recent</span><div class="wl-recent">${list.map((a) => person(a, undefined, { size: 28 })).join("")}</div></div>` : ""}
    </div>
  </div>`;
  hydratePeople(el);

  const form = $("[data-form]", el);
  const input = $("input", form);
  const hint = $("[data-hint]", el);
  const button = $("button[type=submit]", form);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const q = input.value.trim();
    if (!q) return;
    if (EVM.test(q) || SOL.test(q)) return navigate(`/app/wallet/${q}`);
    button.disabled = true;
    hint.hidden = true;
    try {
      const out = await api(`/api/traders?view=lookup&q=${encodeURIComponent(q)}`, { ttl: 60_000 });
      if (out?.address) return navigate(`/app/wallet/${out.address}`);
      throw new Error("No wallet answers to that name.");
    } catch (error) {
      hint.textContent = error.message || "No wallet answers to that name.";
      hint.hidden = false;
    } finally {
      button.disabled = false;
    }
  });
  $("[data-connected]", el)?.addEventListener("click", async () => {
    try {
      const accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
      if (accounts?.[0]) navigate(`/app/wallet/${accounts[0]}`);
    } catch { /* declined */ }
  });
}
