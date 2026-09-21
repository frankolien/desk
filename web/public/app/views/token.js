import { $, $$, esc, api, poll, fmtUsd, fmtSmall, fmtCompact, fmtPct, fmtAmount, short, ago, dirClass, logo, nativeLogo, person, hydratePeople, handoff, identity, knownIdentity, navigate } from "../app.js";

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
.tk-chart { height: 420px; position: relative; }
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
const BAR_SECONDS = { "1m": 60, "5m": 300, "15m": 900, "1H": 3600, "4H": 14400 };
const WINDOWS = [["5m", 5 * 60e3], ["15m", 15 * 60e3], ["1h", 3600e3], ["24h", 86400e3]];
const TABS = [["trades", "Trades"], ["holders", "Holders"], ["traders", "Traders"], ["bundlers", "Bundlers"], ["snipers", "Snipers"], ["insiders", "Insiders"]];
const EARLY_TABS = ["bundlers", "snipers", "insiders"];
const EARLY_LABEL = { bundlers: ["Bundles", "bundles"], snipers: ["Snipers", "snipers"], insiders: ["Insiders", "insiders"] };
const EARLY_RETRIES = 5;
const RISK_LABEL = { low: "Low risk", caution: "Caution", high: "High risk", unchecked: "Not checked" };
const WATCH_KEY = "desk.web.watch";
const FACES_KEY = "desk.web.chartfaces";
const FACES_MAX = 60;
const STACK_MAX = 4;

const num = (value) => { const n = Number(value); return value === "" || value == null || !Number.isFinite(n) ? null : n; };
const first = (...values) => values.find((v) => v != null) ?? null;
const ms = (value) => { const n = num(value); return n == null ? null : n < 1e12 ? n * 1000 : n; };
const hue = (text) => [...String(text)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);
const skel = (w = "100%", h = 14) => `<div class="skel" style="width:${w};height:${h}px"></div>`;
const icon = (id) => `<svg aria-hidden="true"><use href="#${id}"/></svg>`;

function readWatch() { try { return JSON.parse(localStorage.getItem(WATCH_KEY) || "[]"); } catch { return []; } }
function writeWatch(list) { try { localStorage.setItem(WATCH_KEY, JSON.stringify(list)); } catch { /* private mode */ } }
function readFaces() { try { return localStorage.getItem(FACES_KEY) !== "0"; } catch { return true; } }
function writeFaces(on) { try { localStorage.setItem(FACES_KEY, on ? "1" : "0"); } catch { /* private mode */ } }

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

/// A face alone: the avatar, or a monogram on the same gradient `person()` uses.
function face(address, id = knownIdentity(address), size = 20) {
  if (id?.avatar) return `<span class="logo logo-${size}"><img src="${esc(id.avatar)}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.remove()"></span>`;
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
  let candlesAt = 0;
  let generation = 0;
  const chartEl = q("#tk-chart");
  const factor = () => (scale === "mc" && supply != null ? supply : 1);
  const priceFormatter = (v) => (scale === "mc" ? `$${fmtCompact(v)}` : price < 0.01 ? `$${fmtSmall(v)}` : `$${v.toLocaleString("en-US", { minimumFractionDigits: precisionFor(price), maximumFractionDigits: precisionFor(price) })}`);
  const toPoint = (c) => ({ time: c.time, open: c.open * factor(), high: c.high * factor(), low: c.low * factor(), close: c.close * factor() });
  const toVolume = (c) => ({ time: c.time, value: c.volUsd, color: c.close >= c.open ? "rgba(47,214,123,0.35)" : "rgba(255,92,92,0.35)" });
  // Lightweight Charts labels the axis in UTC, so times are shifted to read as local.
  const tzShift = -new Date().getTimezoneOffset() * 60;
  const barTime = (at) => Math.floor(at / 1000 / BAR_SECONDS[bar]) * BAR_SECONDS[bar] + tzShift;
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
    chart.timeScale().fitContent();
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
    schedulePlace();
  };

  // ── Faces on the chart ────────────────────────────────

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
    for (const t of trades.slice(0, FACES_MAX)) {
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

  // ── Trades, holders, traders, launch ──────────────────

  const TAB_IDS = TABS.map(([id]) => id);
  let tab = TAB_IDS.includes(query.tab) ? query.tab : "trades";
  $$("[data-tab]", el).forEach((b) => b.setAttribute("aria-selected", String(b.dataset.tab === tab)));
  let trades = [];
  let seenTrades = new Set();
  let win = "1h";
  let early = { status: "loading", data: null };
  const holders = (details?.holders ?? []).map((h) => ({ address: h.holderWalletAddress, amount: num(h.holdAmount), pct: num(h.holdPercent) }));

  function tradeKey(t) { return t.id ?? `${t.time}:${t.userAddress}:${t.volume}`; }
  const tokenAmount = (t) => {
    const hit = (t.changedTokenInfo ?? []).find((c) => String(c.tokenAddress ?? "").toLowerCase() === address.toLowerCase()) ?? (t.changedTokenInfo ?? []).find((c) => c.tokenSymbol === symbol);
    return num(hit?.amount);
  };

  const TX_EXPLORERS = { "143": "https://monadscan.com/tx/", "501": "https://solscan.io/tx/", "1": "https://etherscan.io/tx/", "8453": "https://basescan.org/tx/", "56": "https://bscscan.com/tx/", "42161": "https://arbiscan.io/tx/", "10": "https://optimistic.etherscan.io/tx/", "137": "https://polygonscan.com/tx/" };
  // The other leg of the swap: what was paid for a buy, what was received for a sell.
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
        ? `<table class="table table-compact"><thead><tr><th>Wallet</th><th class="left">Type</th><th>USD</th><th>${esc(symbol)}</th><th>Price</th><th>Quote</th><th>Txn · Time</th></tr></thead><tbody>${trades.map((t) => tradeRow(t, fresh.has(tradeKey(t)))).join("")}</tbody></table>`
        : `<div class="empty">No trades yet.</div>`;
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
    while (tbody.rows.length > trades.length) tbody.lastElementChild.remove();
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

  // ── Polling ───────────────────────────────────────────

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
