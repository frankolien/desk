import { $, $$, esc, api, poll, fmtUsd, fmtPrice, fmtPct, fmtAmount, ago, short, dirClass, logo, MARKET_LOGOS, person, hydratePeople, knownIdentity, handoff, markets } from "../app.js";

const STYLE = `<style>
.tr-head { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 18px; }
.tr-head .sub { margin-top: 4px; }
.tr-grid { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 20px; align-items: start; }
.tr-rail { display: grid; gap: 20px; }
@media (max-width: 1100px) { .tr-grid { grid-template-columns: 1fr; } }
.tr-who { display: grid; gap: 2px; min-width: 236px; max-width: 280px; }
.tr-who .person { max-width: 100%; }
.tr-who .logo-32 { width: 32px; height: 32px; font-size: 12px; }
.table td.tr-pos { width: 100%; }
.tr-id { font-family: var(--mono); font-size: 10px; color: var(--faint); padding-left: 40px; }
.tr-chips { display: flex; gap: 4px; }
.tr-chips .side-chip { height: 20px; padding: 0 6px; font-size: 10px; letter-spacing: 0.02em; }
.tr-chips .tr-more { display: inline-flex; align-items: center; height: 20px; padding: 0 6px; border-radius: 6px; background: var(--chip); color: var(--muted); font-size: 10px; font-weight: 700; }
.tr-pct { font-size: 11px; font-weight: 600; color: var(--muted); }
.table td.tr-follow { width: 1%; padding-right: 16px; }
.table tbody tr[aria-expanded="true"] { background: rgba(255, 255, 255, 0.03); }
.table tr.tr-detail > td { height: auto; padding: 0; white-space: normal; background: var(--panel); }
.table tbody tr.tr-detail:hover { background: var(--panel); }
.tr-panel { display: grid; grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); }
.tr-panel > div { min-width: 0; }
.tr-panel > div + div { border-left: 1px solid var(--line); }
@media (max-width: 900px) { .tr-panel { grid-template-columns: 1fr; } .tr-panel > div + div { border-left: 0; border-top: 1px solid var(--line); } }
.tr-panel-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; height: 34px; padding: 0 16px; border-bottom: 1px solid var(--line); }
.tr-stats { display: flex; gap: 10px; font-size: 11px; color: var(--muted); white-space: nowrap; }
.tr-stats b { color: var(--text-2); font-weight: 600; }
.tr-mini { width: 100%; border-collapse: collapse; font-size: 12px; }
.table .tr-mini th { position: static; height: 26px; padding: 0 10px; background: transparent; font-size: 10px; color: var(--faint); }
.table .tr-mini td { height: 32px; padding: 0 10px; }
.table .tr-mini th:last-child, .table .tr-mini td:last-child { padding-right: 16px; }
.table .tr-mini tr:last-child td { border-bottom: 0; }
.table tbody .tr-mini tr:hover { background: transparent; }
.tr-mini .tr-pct { margin-left: 4px; }
.tr-mini .side-chip { height: 18px; padding: 0 5px; font-size: 9px; }
.tr-mini .chip-fall { height: 18px; padding: 0 6px; font-size: 9px; margin-left: 6px; }
.tr-mini .mkt { display: inline-flex; align-items: center; gap: 6px; font-weight: 700; }
.tr-mini .skel { height: 10px; }
.tr-panel .empty { padding: 22px 14px; }
.tr-crowd { display: grid; gap: 5px; padding: 10px 16px; border-bottom: 1px solid var(--line); }
.tr-crowd:last-child { border-bottom: 0; }
.tr-crowd:hover { background: rgba(255, 255, 255, 0.025); }
.tr-crowd .row-between b { display: flex; align-items: center; gap: 8px; font-size: 13px; }
.tr-crowd .bar { margin: 1px 0; }
.tr-lean { display: flex; justify-content: space-between; font-size: 11px; font-weight: 600; }
.tr-big { display: flex; align-items: center; gap: 8px; padding: 8px 16px; border-bottom: 1px solid var(--line); font-size: 12px; }
.tr-big:last-child { border-bottom: 0; }
.tr-big .person { flex: 1; min-width: 0; }
.tr-big .side-chip { height: 20px; padding: 0 6px; font-size: 10px; letter-spacing: 0.02em; }
.tr-big .num { font-weight: 600; min-width: 56px; text-align: right; }
</style>`;

const SORTS = { pnl: (t) => t.pnl, value: (t) => t.value, positions: (t) => t.positions.length };
const SKELETONS = Array.from({ length: 8 }, () => `<div class="skel-row"><div class="skel"></div><div class="skel"></div><div class="skel"></div><div class="skel"></div></div>`).join("");
const FAILED = `<div class="empty">Perpl could not be read right now.</div>`;

const lev = (x) => (Number.isFinite(Number(x)) ? `${Number(x) % 1 ? Number(x).toFixed(1) : Number(x)}×` : "");
const sideChip = (side, text) => `<span class="side-chip ${side === "short" ? "short" : "long"}">${esc(text)}</span>`;
const held = (s) => (s == null ? "—" : s < 60 ? `${Math.round(s)}s` : s < 3600 ? `${Math.round(s / 60)}m` : s < 86400 ? `${Math.round(s / 3600)}h` : `${Math.round(s / 86400)}d`);
const decimalsOf = (market) => markets().find((m) => m.name === market)?.priceDecimals ?? 2;
const nameOf = (address) => knownIdentity(address)?.name ?? short(address);

function shape(raw) {
  const positions = raw.positions ?? [];
  const value = positions.reduce((s, p) => s + Number(p.value || 0), 0);
  const collateral = positions.reduce((s, p) => s + Number(p.collateral || 0), 0);
  const pnl = Number(raw.pnl);
  return { ...raw, positions, value, pnl, pct: collateral > 0 ? pnl / collateral : null };
}

export default async function mount(el) {
  const state = { sort: "pnl", expanded: null, top: null, crowd: null, failed: false };
  const histories = new Map();

  el.innerHTML = `${STYLE}
    <div class="tr-head">
      <div><h1>Traders</h1><div class="sub">Read straight off Perpl's exchange contract · <span id="tr-updated">updating…</span></div></div>
      <div class="seg" id="tr-sort" role="tablist">
        <button data-sort="pnl" aria-selected="true">PnL</button>
        <button data-sort="value" aria-selected="false">Value</button>
        <button data-sort="positions" aria-selected="false">Positions</button>
      </div>
    </div>
    <div class="tr-grid">
      <div class="card" id="tr-main">${SKELETONS}</div>
      <div class="tr-rail">
        <div class="card" id="tr-crowd"><div class="card-head"><h3>Crowd</h3></div><div class="card-pad"><div class="skel"></div></div></div>
        <div class="card" id="tr-biggest"><div class="card-head"><h3>Biggest positions</h3></div><div class="card-pad"><div class="skel"></div></div></div>
      </div>
    </div>`;

  const main = $("#tr-main", el);

  function paintUpdated() {
    const at = state.top?.observedAt;
    const node = $("#tr-updated", el);
    if (node) node.textContent = at ? `updated ${ago(at)}` : "updating…";
  }

  function rowHTML(t, i) {
    const chips = t.positions.slice(0, 4).map((p) => sideChip(p.side, `${p.market} ${lev(p.leverage)}`)).join("");
    const more = t.positions.length > 4 ? `<span class="tr-more">+${t.positions.length - 4}</span>` : "";
    const open = state.expanded === t.address;
    return `<tr class="link" data-address="${esc(t.address)}" aria-expanded="${open}">
      <td class="rank">${i + 1}</td>
      <td class="left"><div class="tr-who">${person(t.address, undefined, { size: 32 })}<span class="tr-id">Perpl #${esc(t.accountId)}</span></div></td>
      <td class="left tr-pos"><div class="tr-chips">${chips}${more}</div></td>
      <td class="num">${fmtUsd(t.value, { compact: true })}</td>
      <td class="num ${dirClass(t.pnl)}">${fmtUsd(t.pnl, { sign: true })}<br><span class="tr-pct">${t.pct == null ? "—" : fmtPct(t.pct)}</span></td>
      <td class="tr-follow"><button class="btn btn-line btn-xs" type="button" data-follow="${esc(t.address)}">Follow</button></td>
    </tr>${open ? `<tr class="tr-detail"><td colspan="6" data-detail="${esc(t.address)}">${detailHTML(t)}</td></tr>` : ""}`;
  }

  function positionsHTML(t) {
    const rows = t.positions.map((p) => {
      const d = decimalsOf(p.market);
      const pnl = Number(p.pnl);
      return `<tr>
        <td><span class="mkt">${logo(MARKET_LOGOS[p.market], p.market, 16)}${esc(p.market)}</span></td>
        <td>${sideChip(p.side, p.side)}</td>
        <td class="num">${fmtAmount(p.size)}</td>
        <td class="num">${fmtPrice(p.entry, d)}</td>
        <td class="num">${fmtPrice(p.mark, d)}</td>
        <td class="num">${lev(p.leverage)}</td>
        <td class="num">${fmtUsd(p.value, { compact: true })}</td>
        <td class="num ${dirClass(pnl)}">${fmtUsd(pnl, { sign: true })} <span class="tr-pct">${fmtPct(Number(p.pnlPercent) / 100)}</span></td>
      </tr>`;
    }).join("");
    return `<table class="tr-mini"><thead><tr><th>Market</th><th>Side</th><th>Size</th><th>Entry</th><th>Mark</th><th>Lev</th><th>Value</th><th>PnL</th></tr></thead><tbody>${rows}</tbody></table>`;
  }

  function closedHTML(history) {
    if (history === undefined || history === "loading") {
      return `<table class="tr-mini"><tbody>${Array.from({ length: 3 }, () => `<tr><td><div class="skel" style="width:60px"></div></td><td><div class="skel" style="width:40px;margin-left:auto"></div></td><td><div class="skel" style="width:90px;margin-left:auto"></div></td><td><div class="skel" style="width:50px;margin-left:auto"></div></td></tr>`).join("")}</tbody></table>`;
    }
    const trades = (history?.trades ?? []).slice(0, 8);
    if (!trades.length) return `<div class="empty">No closed trades on record.</div>`;
    const rows = trades.map((x) => {
      const d = decimalsOf(x.market);
      const pnl = Number(x.pnl);
      return `<tr>
        <td><span class="mkt">${logo(MARKET_LOGOS[x.market], x.market, 16)}${esc(x.market)}</span></td>
        <td>${sideChip(x.side, x.side)}</td>
        <td class="num">${fmtPrice(x.entry, d)} → ${fmtPrice(x.exit, d)}</td>
        <td class="num ${dirClass(pnl)}">${fmtUsd(pnl, { sign: true })}</td>
        <td class="num muted">${held(x.holdSeconds)}${x.liquidated ? `<span class="chip chip-fall">liq</span>` : ""}</td>
      </tr>`;
    }).join("");
    return `<table class="tr-mini"><thead><tr><th>Market</th><th>Side</th><th>Entry → Exit</th><th>PnL</th><th>Held</th></tr></thead><tbody>${rows}</tbody></table>`;
  }

  function statsHTML(history) {
    const s = history?.stats;
    if (!s || !s.trades) return "";
    const parts = [
      s.winRate != null ? `Win rate <b>${fmtPct(s.winRate, { sign: false, digits: 0 })}</b>` : "",
      `Realised <b class="${dirClass(s.realised)}">${fmtUsd(s.realised, { sign: true, compact: true })}</b>`,
      s.averageLeverage != null ? `Avg <b>${lev(s.averageLeverage)}</b>` : "",
      s.liquidations ? `<b class="down">${s.liquidations} liq</b>` : "",
    ].filter(Boolean);
    return `<div class="tr-stats">${parts.join("<span class='faint'>·</span>")}</div>`;
  }

  function detailHTML(t) {
    const history = histories.get(t.address);
    return `<div class="tr-panel">
      <div><div class="tr-panel-head"><span class="eyebrow">Open positions</span><span class="tr-stats">${t.positions.length} open<span class="faint">·</span>${fmtUsd(t.value, { compact: true })}</span></div>${positionsHTML(t)}</div>
      <div><div class="tr-panel-head"><span class="eyebrow">Closed trades</span>${statsHTML(history)}</div>${closedHTML(history)}</div>
    </div>`;
  }

  function paintTable() {
    if (state.failed && !state.top) { main.innerHTML = FAILED; return; }
    if (!state.top) return;
    const key = SORTS[state.sort];
    const rows = [...state.top.traders].sort((a, b) => key(b) - key(a) || b.pnl - a.pnl);
    if (!rows.length) { main.innerHTML = `<div class="empty">No open positions on Perpl right now.</div>`; return; }
    main.innerHTML = `<div class="table-wrap"><table class="table">
      <thead><tr><th class="rank">#</th><th class="left">Trader</th><th class="left">Positions</th><th>Value</th><th>PnL</th><th></th></tr></thead>
      <tbody>${rows.map(rowHTML).join("")}</tbody></table></div>`;
  }

  function paintRail() {
    const crowd = state.crowd?.markets ?? [];
    const crowdEl = $("#tr-crowd", el);
    const bigEl = $("#tr-biggest", el);
    if (!crowd.length) {
      const body = state.failed ? FAILED : `<div class="empty">Nothing open yet.</div>`;
      crowdEl.innerHTML = `<div class="card-head"><h3>Crowd</h3></div>${body}`;
      bigEl.innerHTML = `<div class="card-head"><h3>Biggest positions</h3></div>${body}`;
      return;
    }
    // Long value equals short value on a perp by construction, so the lean is by heads, not dollars.
    const rows = crowd.map((m) => {
      const heads = (m.longTraders ?? 0) + (m.shortTraders ?? 0);
      const long = heads ? (m.longTraders / heads) * 100 : (m.longShareBps ?? 5000) / 100;
      return `<a class="tr-crowd" href="/app/trade/${esc(m.market)}" data-link>
        <div class="row-between"><b>${logo(MARKET_LOGOS[m.market], m.market, 20)}${esc(m.market)}</b><span class="muted" style="font-size:12px">${m.traders} traders</span></div>
        <div class="bar bar-thin"><i style="width:${long.toFixed(1)}%"></i></div>
        <div class="tr-lean"><span class="up">Long ${Math.round(long)}%</span><span class="down">Short ${Math.round(100 - long)}%</span></div>
      </a>`;
    }).join("");
    crowdEl.innerHTML = `<div class="card-head"><h3>Crowd</h3><span class="eyebrow">${crowd.reduce((s, m) => s + (m.traders ?? 0), 0)} positions</span></div>${rows}`;

    const biggest = crowd.filter((m) => m.biggest?.address).map((m) => ({ market: m.market, ...m.biggest })).sort((a, b) => Number(b.value) - Number(a.value)).slice(0, 5);
    bigEl.innerHTML = `<div class="card-head"><h3>Biggest positions</h3></div>
      ${biggest.map((b) => `<div class="tr-big">${person(b.address, undefined, { size: 24 })}${sideChip(b.side, `${b.market} ${lev(b.leverage)}`)}<span class="num">${fmtUsd(b.value, { compact: true })}</span></div>`).join("")}
      <div class="card-foot"><span>Every open position on every market, counted on-chain.</span></div>`;
  }

  function paint() {
    paintTable();
    paintRail();
    paintUpdated();
    hydratePeople(el);
  }

  function loadHistory(address) {
    if (histories.has(address)) return;
    histories.set(address, "loading");
    api(`/api/traders?view=history&address=${address}`, { ttl: 120_000 })
      .then((out) => histories.set(address, out ?? { trades: [] }))
      .catch(() => histories.set(address, { trades: [] }))
      .then(() => {
        const cell = $(`[data-detail="${address}"]`, el);
        const t = state.top?.traders.find((x) => x.address === address);
        if (cell && t) cell.innerHTML = detailHTML(t);
      });
  }

  el.addEventListener("click", (event) => {
    const follow = event.target.closest("[data-follow]");
    if (follow) {
      event.stopPropagation();
      handoff({ title: `Follow ${nameOf(follow.dataset.follow)} in Desk`, sub: "Following copies every move in the same block, with Face ID on each order." });
      return;
    }
    const sortBtn = event.target.closest("#tr-sort button");
    if (sortBtn) {
      state.sort = sortBtn.dataset.sort;
      for (const b of $$("#tr-sort button", el)) b.setAttribute("aria-selected", String(b === sortBtn));
      paintTable(); hydratePeople(el);
      return;
    }
    if (event.target.closest("a[data-link]")) return;
    const row = event.target.closest("tr.link[data-address]");
    if (!row) return;
    const address = row.dataset.address;
    state.expanded = state.expanded === address ? null : address;
    if (state.expanded) loadHistory(address);
    paintTable(); hydratePeople(el);
  });

  const stopPoll = poll(async () => {
    const [top, crowd] = await Promise.allSettled([
      api("/api/traders?view=top", { ttl: 30_000 }),
      api("/api/traders?view=crowd", { ttl: 30_000 }),
    ]);
    if (top.status === "fulfilled") state.top = { ...top.value, traders: (top.value.traders ?? []).map(shape) };
    if (crowd.status === "fulfilled") state.crowd = crowd.value;
    state.failed = top.status === "rejected" && crowd.status === "rejected";
    if (!el.isConnected) return;
    paint();
  }, 30_000);
  const tick = setInterval(paintUpdated, 10_000);

  return () => { stopPoll(); clearInterval(tick); };
}
