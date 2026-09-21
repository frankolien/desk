// The shell: routing, fetching, formatting, names and faces, the ticker, search and the
// hand-off sheet. Pages live in ./views and import what they need from here.

export const $ = (selector, root = document) => root.querySelector(selector);
export const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
export const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ── Fetch ───────────────────────────────────────────────

const cache = new Map();
const inflight = new Map();

/// GET a same-origin path. `ttl` keeps a good answer that long; a request already on the
/// wire is shared rather than repeated.
export async function api(path, { ttl = 0, signal } = {}) {
  const hit = cache.get(path);
  if (hit && Date.now() - hit.at < ttl) return hit.value;
  if (inflight.has(path)) return inflight.get(path);
  const run = (async () => {
    const response = await fetch(path, { signal, headers: { accept: "application/json" } });
    const body = await response.json().catch(() => null);
    if (!response.ok) {
      const error = new Error(body?.detail ?? body?.error ?? `HTTP ${response.status}`);
      error.status = response.status;
      throw error;
    }
    const value = body && typeof body === "object" && "data" in body && "meta" in body ? body.data : body;
    cache.set(path, { at: Date.now(), value });
    return value;
  })();
  inflight.set(path, run);
  try { return await run; } finally { inflight.delete(path); }
}

/// Runs `tick` now and every `ms` until the returned stop is called or the tab hides.
export function poll(tick, ms) {
  let timer = null;
  let stopped = false;
  const run = async () => {
    if (stopped) return;
    try { await tick(); } catch { /* the page shows what it has */ }
    if (!stopped) timer = setTimeout(run, document.hidden ? ms * 4 : ms);
  };
  run();
  const onVisible = () => { if (!document.hidden && !stopped) { clearTimeout(timer); run(); } };
  document.addEventListener("visibilitychange", onVisible);
  return () => { stopped = true; clearTimeout(timer); document.removeEventListener("visibilitychange", onVisible); };
}

// ── Formatting ──────────────────────────────────────────

const usd0 = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
const usd2 = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 });

export function fmtUsd(value, { compact = false, cents = "auto", sign = false } = {}) {
  if (value == null || !Number.isFinite(Number(value))) return "—";
  const n = Number(value);
  const abs = Math.abs(n);
  let text;
  if (compact && abs >= 1e3) text = `$${fmtCompact(abs)}`;
  else if (cents === "never" || (cents === "auto" && abs >= 1e5)) text = usd0.format(abs);
  else if (abs > 0 && abs < 0.01) text = `$${fmtSmall(abs)}`;
  else if (abs < 1) text = `$${Number(abs.toPrecision(4)).toString()}`;
  else text = usd2.format(abs);
  if (n < 0) return `−${text}`;
  return sign && n > 0 ? `+${text}` : text;
}

export function fmtCompact(value) {
  const n = Math.abs(Number(value));
  if (n >= 1e12) return `${trim(n / 1e12)}T`;
  if (n >= 1e9) return `${trim(n / 1e9)}B`;
  if (n >= 1e6) return `${trim(n / 1e6)}M`;
  if (n >= 1e3) return `${trim(n / 1e3)}K`;
  return trim(n);
}
const trim = (n) => (n >= 100 ? n.toFixed(0) : n >= 10 ? n.toFixed(1) : n.toFixed(2)).replace(/\.0+$|(\.\d*[1-9])0+$/, "$1");

/// Sub-cent prices the way a trader reads them: 0.0₅123 is 0.00000123.
export function fmtSmall(value) {
  const n = Number(value);
  if (n === 0) return "0";
  if (n >= 0.01) return n.toPrecision(4);
  const zeros = -Math.floor(Math.log10(n)) - 1;
  const digits = Math.round(n * 10 ** (zeros + 4)).toString().replace(/0+$/, "") || "0";
  const sub = String(zeros).replace(/\d/g, (d) => "₀₁₂₃₄₅₆₇₈₉"[d]);
  return zeros >= 3 ? `0.0${sub}${digits}` : n.toFixed(zeros + 4).replace(/0+$/, "");
}

/// A price at its market's decimals, with grouping.
export function fmtPrice(value, decimals = 2) {
  if (value == null || !Number.isFinite(Number(value))) return "—";
  const n = Number(value);
  if (n > 0 && n < 0.01 && decimals > 4) return fmtSmall(n);
  return n.toLocaleString("en-US", { minimumFractionDigits: Math.min(decimals, 6), maximumFractionDigits: Math.min(decimals, 6) });
}

export function fmtPct(fraction, { sign = true, digits = 2 } = {}) {
  if (fraction == null || !Number.isFinite(Number(fraction))) return "—";
  const n = Number(fraction) * 100;
  const text = `${Math.abs(n).toFixed(Math.abs(n) >= 100 ? 0 : digits)}%`;
  if (n < 0) return `−${text}`;
  return sign && n > 0 ? `+${text}` : text;
}

export function fmtAmount(value, digits = 4) {
  if (value == null || !Number.isFinite(Number(value))) return "—";
  const n = Number(value);
  if (Math.abs(n) >= 1e6) return fmtCompact(n);
  return n.toLocaleString("en-US", { maximumFractionDigits: Math.abs(n) >= 1000 ? 2 : digits });
}

export const short = (address) => (address && address.length > 12 ? `${address.slice(0, 6)}…${address.slice(-4)}` : address ?? "");

export function ago(ms, { suffix = true } = {}) {
  const s = Math.max(0, (Date.now() - Number(ms)) / 1000);
  const text = s < 60 ? `${Math.round(s)}s` : s < 3600 ? `${Math.round(s / 60)}m` : s < 86400 ? `${Math.round(s / 3600)}h` : `${Math.round(s / 86400)}d`;
  return suffix ? `${text} ago` : text;
}

export const dirClass = (n) => (n > 0 ? "up" : n < 0 ? "down" : "muted");

// ── Pictures ────────────────────────────────────────────

const NATIVE_LOGOS = {
  "143": "https://static.oklink.com/cdn/web3/currency/token/large/143-null-110/type=default_90_0?v=1763995219024",
  "1": "https://assets.coingecko.com/coins/images/279/small/ethereum.png",
  "501": "https://assets.coingecko.com/coins/images/4128/small/solana.png",
  "56": "https://assets.coingecko.com/coins/images/825/small/bnb-icon2_2x.png",
  "8453": "https://assets.coingecko.com/coins/images/279/small/ethereum.png",
  "42161": "https://assets.coingecko.com/coins/images/279/small/ethereum.png",
};
export const MARKET_LOGOS = {
  BTC: "https://assets.coingecko.com/coins/images/1/small/bitcoin.png",
  ETH: "https://static.oklink.com/cdn/web3/currency/token/large/4663-0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-999/type=default_90_0?v=1783473458568",
  SOL: "https://static.oklink.com/cdn/web3/currency/token/501-11111111111111111111111111111111-1.png/type=default_350_0?v=1734571825920",
  MON: "https://static.oklink.com/cdn/web3/currency/token/large/143-null-110/type=default_90_0?v=1763995219024",
  HYPE: "https://static.oklink.com/cdn/web3/currency/token/large/501-F7eL5pudRQBgF9RtCbv6sWBf2qmSVw2H517wmL6sSwki-108/type=default_90_0?v=1789931249951",
  ZEC: "https://static.oklink.com/cdn/web3/currency/token/large/501-ABypSz8b54GVnxuZTWHg1ixXQGo9DWNvSPBCgT3xKDoM-108/type=default_90_0?v=1789934630437",
  PUMP: "https://static.oklink.com/cdn/web3/currency/token/large/501-pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn-107/type=default_90_0?v=1788753584256",
  LIT: "https://static.oklink.com/cdn/web3/currency/token/large/1-0x232ce3bd40fcd6f80f3d55a522d03f25df784ee2-110/type=default_90_0?v=1767180873311",
};
export const nativeLogo = (chainIndex) => NATIVE_LOGOS[String(chainIndex)] ?? "";

const hue = (text) => [...String(text)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);

/// A round picture with the symbol's initials behind it, so a missing image is a
/// monogram rather than a hole.
export function logo(url, label, size = 32, { square = false } = {}) {
  const initials = esc(String(label ?? "?").replace(/[^A-Za-z0-9]/g, "").slice(0, 2).toUpperCase() || "?");
  const bg = `hsl(${hue(label)} 22% 18%)`;
  const img = url ? `<img src="${esc(url)}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.remove()">` : "";
  return `<span class="logo logo-${size}${square ? " sq" : ""}" style="background:${bg}"><span style="position:absolute">${initials}</span>${img}</span>`;
}

// ── Names and faces ─────────────────────────────────────

const identities = new Map();
let identityQueue = new Set();
let identityTimer = null;
const identityWaiters = [];

/// Who an address is. Asked in batches: every address a page paints within a frame
/// travels in one request.
export function identity(address) {
  const key = String(address ?? "").toLowerCase();
  if (!/^0x[0-9a-f]{40}$/.test(key)) return Promise.resolve(null);
  if (identities.has(key)) return Promise.resolve(identities.get(key));
  identityQueue.add(key);
  return new Promise((resolve) => {
    identityWaiters.push({ key, resolve });
    clearTimeout(identityTimer);
    identityTimer = setTimeout(flushIdentities, 30);
  });
}

async function flushIdentities() {
  const batch = [...identityQueue].slice(0, 40);
  batch.forEach((key) => identityQueue.delete(key));
  let found = {};
  try {
    const out = await api(`/api/traders?view=identity&addresses=${batch.join(",")}`);
    found = out?.identities ?? {};
  } catch { /* unnamed stays unnamed */ }
  for (const key of batch) identities.set(key, found[key] ?? null);
  for (let i = identityWaiters.length - 1; i >= 0; i -= 1) {
    const waiter = identityWaiters[i];
    if (batch.includes(waiter.key)) { identityWaiters.splice(i, 1); waiter.resolve(identities.get(waiter.key)); }
  }
  if (identityQueue.size) identityTimer = setTimeout(flushIdentities, 10);
}

export const knownIdentity = (address) => identities.get(String(address ?? "").toLowerCase()) ?? null;

/// The person row: face, name or short address, and where the name came from.
export function person(address, id = knownIdentity(address), { size = 24, via = true, link = true } = {}) {
  const name = id?.name ?? short(address);
  const face = id?.avatar
    ? `<span class="logo logo-${size}"><img src="${esc(id.avatar)}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.remove()"></span>`
    : `<span class="logo logo-${size}" style="background:linear-gradient(135deg,hsl(${hue(address)} 60% 45%),hsl(${(hue(address) + 40) % 360} 60% 30%))"></span>`;
  const label = id?.name ? `<b>${esc(name)}</b>` : `<span class="addr">${esc(name)}</span>`;
  const source = via && id?.source ? `<span class="via">${esc(SOURCE_LABEL[id.source] ?? id.source)}</span>` : "";
  const inner = `${face}${label}${source}`;
  return link ? `<a class="person" href="/app/wallet/${esc(address)}" data-link data-person="${esc(address)}">${inner}</a>` : `<span class="person" data-person="${esc(address)}">${inner}</span>`;
}
const SOURCE_LABEL = { nad: ".nad", nadfun: "nad.fun", ens: "ENS", farcaster: "Farcaster" };

/// Paints names into every person placeholder under `root` as they arrive.
export function hydratePeople(root) {
  for (const el of $$("[data-person]", root)) {
    const address = el.dataset.person;
    if (knownIdentity(address)) continue;
    identity(address).then((id) => {
      if (!id || !el.isConnected) return;
      const size = Number((el.querySelector(".logo")?.className.match(/logo-(\d+)/) ?? [])[1] ?? 24);
      const link = el.tagName === "A";
      el.outerHTML = person(address, id, { size, link, via: el.dataset.via !== "off" });
    });
  }
}

// ── Sparkline ───────────────────────────────────────────

export function sparkline(values, { width = 96, height = 28, up = null } = {}) {
  const points = (values ?? []).map(Number).filter(Number.isFinite);
  if (points.length < 2) return `<svg class="spark" viewBox="0 0 ${width} ${height}"></svg>`;
  const min = Math.min(...points);
  const max = Math.max(...points);
  const span = max - min || 1;
  const step = (width - 6) / (points.length - 1);
  const coords = points.map((v, i) => [3 + i * step, 3 + (height - 6) * (1 - (v - min) / span)]);
  const d = coords.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const rising = up ?? points[points.length - 1] >= points[0];
  const color = rising ? "var(--rise)" : "var(--fall)";
  const [lx, ly] = coords[coords.length - 1];
  return `<svg class="spark" viewBox="0 0 ${width} ${height}" aria-hidden="true">
    <path class="fill" d="${d} L${lx.toFixed(1)},${height} L3,${height} Z" fill="${color}"/>
    <path d="${d}" stroke="${color}"/>
    <circle cx="${lx.toFixed(1)}" cy="${ly.toFixed(1)}" fill="${color}"/>
  </svg>`;
}

// ── Toasts and the hand-off sheet ───────────────────────

export function toast({ logoHTML = "", title, sub = "", amount = "", ttl = 6000 }) {
  const host = $("#toast");
  const el = document.createElement("div");
  el.innerHTML = `${logoHTML}<div><b>${esc(title)}</b><small>${esc(sub)}</small></div><span class="amt">${esc(amount)}</span>`;
  host.prepend(el);
  while (host.children.length > 3) host.lastChild.remove();
  setTimeout(() => { el.style.opacity = "0"; el.style.transition = "opacity .3s"; setTimeout(() => el.remove(), 320); }, ttl);
}

export const APP_URL = "https://trydesk.trade/#get";

/// The web cannot sign. Anything that would be an order opens this instead.
export function handoff({ title = "Trade this in Desk", sub = "Every order signs with Face ID in the app. Scan to get Desk on your iPhone." } = {}) {
  $("#handoff-title").textContent = title;
  $("#handoff-sub").textContent = sub;
  const box = $("#handoff-qr");
  if (!box.firstChild && window.qrcode) {
    const qr = window.qrcode(0, "M");
    qr.addData(APP_URL);
    qr.make();
    box.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 0, scalable: true });
  }
  $("#handoff").hidden = false;
}

// ── Router ──────────────────────────────────────────────

const ROUTES = [
  { pattern: /^\/app\/?$/, view: "trade", section: "trade", params: () => ({}) },
  { pattern: /^\/app\/trade\/([A-Za-z0-9]{1,12})\/?$/, view: "trade", section: "trade", params: (m) => ({ market: m[1].toUpperCase() }) },
  { pattern: /^\/app\/markets\/?$/, view: "markets", section: "markets", params: () => ({}) },
  { pattern: /^\/app\/traders\/?$/, view: "traders", section: "traders", params: () => ({}) },
  { pattern: /^\/app\/portfolio\/?$/, view: "wallet", section: "portfolio", params: () => ({}) },
  { pattern: /^\/app\/wallet\/([A-Za-z0-9]{20,64})\/?$/, view: "wallet", section: "portfolio", params: (m) => ({ address: m[1] }) },
  { pattern: /^\/app\/token\/(\d{1,10})\/([A-Za-z0-9]{20,64})\/?$/, view: "token", section: "markets", params: (m) => ({ chainIndex: m[1], address: m[2] }) },
];

let unmount = null;
let mountToken = 0;

export function navigate(path, { replace = false } = {}) {
  if (path === location.pathname + location.search) return;
  history[replace ? "replaceState" : "pushState"]({}, "", path);
  render();
}

async function render() {
  const path = location.pathname;
  const route = ROUTES.find((r) => r.pattern.test(path));
  if (!route) return navigate("/app", { replace: true });
  const params = { ...route.params(path.match(route.pattern)), query: Object.fromEntries(new URLSearchParams(location.search)) };
  const token = ++mountToken;
  if (unmount) { try { unmount(); } catch { /* gone */ } unmount = null; }
  for (const link of $$("#side-nav .side-link")) {
    if (link.dataset.section === route.section) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current");
  }
  const view = $("#view");
  view.scrollTop = 0;
  window.scrollTo(0, 0);
  try {
    const module = await import(`/app/views/${route.view}.js`);
    if (token !== mountToken) return;
    view.innerHTML = "";
    unmount = (await module.default(view, params)) ?? null;
  } catch (error) {
    if (token !== mountToken) return;
    view.innerHTML = `<div class="empty">This page could not load.<br><span class="faint">${esc(error.message)}</span></div>`;
  }
}

document.addEventListener("click", (event) => {
  const link = event.target.closest("a[data-link]");
  if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
  const url = new URL(link.href, location.origin);
  if (url.origin !== location.origin) return;
  event.preventDefault();
  navigate(url.pathname + url.search);
});
window.addEventListener("popstate", render);

// ── Ticker ──────────────────────────────────────────────

let marketsNow = [];
export const markets = () => marketsNow;

function paintTicker(rows) {
  const run = $("#ticker-run");
  const items = rows.map((m) => `<a class="ticker-item" href="/app/trade/${esc(m.name)}" data-link>
      ${logo(MARKET_LOGOS[m.name], m.name, 16)}<b>${esc(m.name)}</b>
      <span class="num" data-mark="${esc(m.name)}">${fmtPrice(m.mark, m.priceDecimals)}</span>
      <small class="num ${dirClass(m.change)}">${fmtPct(m.change)}</small>
    </a>`).join("");
  run.innerHTML = items + items;
  run.style.setProperty("--ticker-duration", `${Math.max(30, Math.round(run.scrollWidth / 2 / 50))}s`);
}

function startTicker() {
  let painted = false;
  poll(async () => {
    try {
      const out = await api("/api/v1/markets");
      const rows = out.markets ?? [];
      const previous = new Map(marketsNow.map((m) => [m.name, m.mark]));
      marketsNow = rows;
      if (!painted) { paintTicker(rows); painted = true; }
      else {
        for (const m of rows) {
          for (const el of $$(`[data-mark="${m.name}"]`, $("#ticker-run"))) {
            const was = previous.get(m.name);
            el.textContent = fmtPrice(m.mark, m.priceDecimals);
            if (was != null && was !== m.mark) { el.classList.remove("flash-up", "flash-down"); void el.offsetWidth; el.classList.add(m.mark > was ? "flash-up" : "flash-down"); }
            const change = el.nextElementSibling;
            if (change) { change.textContent = fmtPct(m.change); change.className = `num ${dirClass(m.change)}`; }
          }
        }
      }
      $("#ticker-dot").className = "dot";
      document.dispatchEvent(new CustomEvent("markets", { detail: rows }));
    } catch {
      $("#ticker-dot").className = "dot amber";
    }
  }, 10_000);
}

// ── Search ──────────────────────────────────────────────

function startSearch() {
  const overlay = $("#search");
  const input = $("#search-input");
  const body = $("#search-body");
  let seq = 0;
  let selected = 0;
  let rows = [];

  const open = () => { overlay.hidden = false; input.value = ""; body.innerHTML = hint(); rows = []; setTimeout(() => input.focus(), 0); };
  const close = () => { overlay.hidden = true; };
  const hint = () => `<div class="search-section">Try</div>${["MON", "vitalik.eth", "salmo.nad", "@dwr"].map((q) => `<div class="search-row" data-q="${q}"><span class="logo logo-28"><span>${q[0]}</span></span><div class="name"><b>${q}</b></div></div>`).join("")}`;

  $("#search-open").addEventListener("click", open);
  overlay.addEventListener("click", (event) => { if (event.target === overlay) close(); });
  document.addEventListener("keydown", (event) => {
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName ?? "");
    if (event.key === "/" && !typing && overlay.hidden) { event.preventDefault(); open(); }
    else if (event.key === "Escape" && !overlay.hidden) close();
    else if (event.key === "Escape" && !$("#handoff").hidden) $("#handoff").hidden = true;
    else if (!overlay.hidden && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
      event.preventDefault();
      selected = Math.max(0, Math.min(rows.length - 1, selected + (event.key === "ArrowDown" ? 1 : -1)));
      paintSelection();
    } else if (!overlay.hidden && event.key === "Enter") {
      const row = $$(".search-row", body)[selected];
      if (row) row.click();
    }
  });
  const paintSelection = () => $$(".search-row", body).forEach((el, i) => el.setAttribute("aria-selected", String(i === selected)));

  body.addEventListener("click", (event) => {
    const row = event.target.closest(".search-row");
    if (!row) return;
    if (row.dataset.q) { input.value = row.dataset.q; input.dispatchEvent(new Event("input")); return; }
    if (row.dataset.href) { close(); navigate(row.dataset.href); }
  });

  let timer = null;
  input.addEventListener("input", () => {
    clearTimeout(timer);
    const q = input.value.trim();
    if (!q) { body.innerHTML = hint(); rows = []; return; }
    timer = setTimeout(() => lookup(q), 180);
  });

  async function lookup(q) {
    const mine = ++seq;
    const wantsPerson = /^(0x[0-9a-fA-F]{40}|[1-9A-HJ-NP-Za-km-z]{32,44}|@[\w.-]+|[\w-]+\.(nad|eth))$/i.test(q);
    body.innerHTML = `<div class="skel-row"><div class="skel"></div><div class="skel"></div><div class="skel"></div><div class="skel"></div></div><div class="skel-row"><div class="skel"></div><div class="skel"></div><div class="skel"></div><div class="skel"></div></div>`;
    const [tokens, people] = await Promise.all([
      api(`/api/token-discovery?q=${encodeURIComponent(q)}`, { ttl: 30_000 }).then((out) => out.tokens ?? []).catch(() => []),
      wantsPerson ? api(`/api/traders?view=lookup&q=${encodeURIComponent(q)}`, { ttl: 60_000 }).catch(() => null) : Promise.resolve(null),
    ]);
    if (mine !== seq) return;
    const perps = marketsNow.filter((m) => m.name.toLowerCase().startsWith(q.toLowerCase()));
    let html = "";
    rows = [];
    if (people?.address) {
      const id = people.identity ?? {};
      html += `<div class="search-section">People</div><div class="search-row" data-href="/app/wallet/${esc(people.address)}">
        ${id.avatar ? `<span class="logo logo-28"><img src="${esc(id.avatar)}" alt="" referrerpolicy="no-referrer" onerror="this.remove()"></span>` : `<span class="logo logo-28" style="background:linear-gradient(135deg,var(--brand-deep),#221a55)"></span>`}
        <div class="name"><b>${esc(id.name ?? short(people.address))}</b><span>${esc(short(people.address))} · via ${esc(SOURCE_LABEL[people.via] ?? people.via ?? "address")}</span></div>
        <div class="right"><small class="muted">Wallet</small></div></div>`;
      rows.push(1);
    }
    if (perps.length) {
      html += `<div class="search-section">Perps on Perpl</div>` + perps.map((m) => { rows.push(1); return `<div class="search-row" data-href="/app/trade/${esc(m.name)}">
        ${logo(MARKET_LOGOS[m.name], m.name, 28)}<div class="name"><b>${esc(m.name)}-PERP</b><span>Up to ${m.maxLeverage}× · AUSD</span></div>
        <div class="right"><b class="num">${fmtPrice(m.mark, m.priceDecimals)}</b><small class="num ${dirClass(m.change)}">${fmtPct(m.change)}</small></div></div>`; }).join("");
    }
    if (tokens.length) {
      html += `<div class="search-section">Tokens</div>` + tokens.slice(0, 12).map((t) => { rows.push(1); return `<div class="search-row" data-href="/app/token/${esc(t.chainIndex)}/${esc(t.contract)}">
        ${logo(t.logoURL, t.symbol, 28)}<div class="name"><b>${esc(t.symbol)} <span class="muted" style="font-weight:500">${esc(t.name)}</span></b><span>${esc(t.chainName)} · ${esc(short(t.contract))}</span></div>
        <div class="right"><b class="num">${fmtUsd(t.price)}</b><small class="num ${dirClass(t.change)}">${fmtPct(t.change == null ? null : t.change / 100)}</small></div></div>`; }).join("");
    }
    body.innerHTML = html || `<div class="empty">Nothing by that name on any chain.</div>`;
    selected = 0;
    paintSelection();
  }
}

// ── Boot ────────────────────────────────────────────────

$("#get-app").addEventListener("click", () => handoff({ title: "Desk for iPhone", sub: "Perps with Face ID, copy trading, alerts. Scan to get it." }));
$("#handoff").addEventListener("click", (event) => { if (event.target === $("#handoff") || event.target.closest("[data-close]")) $("#handoff").hidden = true; });
startTicker();
startSearch();
render();
