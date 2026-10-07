import { $, api, esc, short, knownIdentity, person, toast, handoff, fmtUsd, ago, navigate, hydratePeople } from "./app.js";

// Following on the web: a list of traders kept in this browser, and alerts about their
// trades delivered to this browser through its push service. The server treats the browser
// as a seat like a phone, so the same scan that pushes to the app pushes here.

const FOLLOWS_KEY = "desk.web.follows";
const INSTALL_KEY = "desk.web.alerts-install";
const MAX_FOLLOWS = 40;
const FEED_MS = 20_000;
const EVM = /^0x[0-9a-fA-F]{40}$/;
const VERBS = { opened: "Opened", flipped: "Flipped", added: "Added to", reduced: "Trimmed", closed: "Closed" };

const state = { follows: load(), subscribed: false, offered: false, worker: null, feed: null, feedTimer: null };

function load() {
  try {
    const rows = JSON.parse(localStorage.getItem(FOLLOWS_KEY) ?? "[]");
    if (!Array.isArray(rows)) return [];
    return rows
      .filter((row) => row && EVM.test(row.address ?? ""))
      .map((row) => ({ address: row.address.toLowerCase(), name: typeof row.name === "string" ? row.name : null, at: Number(row.at) || 0 }))
      .slice(0, MAX_FOLLOWS);
  } catch { return []; }
}
function save() { try { localStorage.setItem(FOLLOWS_KEY, JSON.stringify(state.follows)); } catch {} }

export const follows = () => state.follows.slice();
export const isFollowing = (address) => state.follows.some((row) => row.address === String(address ?? "").toLowerCase());
export const supported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
const permission = () => (typeof Notification === "undefined" ? "unsupported" : Notification.permission);
export const alertsOn = () => permission() === "granted" && state.subscribed;

/// The install secret names this browser's seat on the server; it is never the push keys.
function install() {
  try {
    let value = localStorage.getItem(INSTALL_KEY);
    if (!/^[0-9a-f]{64}$/.test(value ?? "")) {
      value = [...crypto.getRandomValues(new Uint8Array(32))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
      localStorage.setItem(INSTALL_KEY, value);
    }
    return value;
  } catch { return null; }
}

async function registration() {
  if (!supported()) return null;
  state.worker ??= navigator.serviceWorker.register("/app/sw.js", { scope: "/app/" }).catch((error) => { state.worker = null; throw error; });
  await state.worker;
  return navigator.serviceWorker.ready;
}

function keyBytes(text) {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}
const sameKey = (held, wanted) => held && held.byteLength === wanted.byteLength && new Uint8Array(held).every((byte, i) => byte === wanted[i]);

/// This browser's subscription under the server's current key; a key the server no longer
/// uses is unsubscribed first, since a subscription is bound to the key it was made with.
async function ensureSubscription(reg) {
  const { publicKey } = await api("/api/alerts?job=key", { ttl: 3600_000 });
  const wanted = keyBytes(publicKey);
  let sub = await reg.pushManager.getSubscription();
  if (sub && sub.options?.applicationServerKey && !sameKey(sub.options.applicationServerKey, wanted)) {
    await sub.unsubscribe().catch(() => {});
    sub = null;
  }
  return sub ?? reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: wanted });
}

async function post(body) {
  const response = await fetch("/api/alerts", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const out = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(out.error ?? `HTTP ${response.status}`);
  return out;
}

/// The seat as it stands: this browser's subscription and the traders it follows. An empty
/// list is an unsubscribe on the server; the browser's subscription stays for the next follow.
async function sync(subscription = null) {
  const reg = await registration();
  const sub = subscription ?? (reg ? await reg.pushManager.getSubscription() : null);
  const secret = install();
  if (!sub || !secret) return null;
  const json = sub.toJSON();
  const names = {};
  for (const row of state.follows) if (row.name) names[row.address] = row.name;
  return post({ install: secret, web: { endpoint: json.endpoint, keys: json.keys }, traders: state.follows.map((row) => row.address), names });
}

export async function enableAlerts() {
  if (!supported()) {
    handoff({ title: "Alerts on your iPhone", sub: "This browser can't receive push. Desk on iPhone can, and it copies the trades too. Scan to get Desk." });
    return false;
  }
  if (!install()) { toast({ title: "Alerts need site storage", sub: "This browser blocks it for trydesk.trade." }); return false; }
  // Safari grants the prompt only inside the click itself, before anything else is awaited.
  const granted = await Notification.requestPermission();
  if (granted !== "granted") {
    toast({ title: "Notifications are off for this site", sub: granted === "denied" ? "Allow them in the browser's site settings to get alerts." : "Allow them to hear the moment a trader you follow trades." });
    paintAlerts(); paintBell();
    return false;
  }
  try {
    const reg = await registration();
    const sub = await ensureSubscription(reg);
    await sync(sub);
    state.subscribed = true;
    toast({ title: "Alerts are on", sub: state.follows.length ? "You'll hear the moment a trader you follow trades." : "Follow a trader to hear the moment they trade." });
  } catch (error) {
    toast({ title: "Alerts couldn't be turned on", sub: String(error?.message ?? error).slice(0, 90) });
  }
  paintAlerts(); paintBell();
  return state.subscribed;
}

export async function disableAlerts() {
  try {
    const reg = await registration();
    const sub = reg ? await reg.pushManager.getSubscription() : null;
    if (sub) await sub.unsubscribe().catch(() => {});
    const secret = install();
    if (secret) await post({ action: "unsubscribe", install: secret }).catch(() => {});
  } catch {}
  state.subscribed = false;
  toast({ title: "Alerts are off", sub: "Your follows stay. Turn alerts back on any time." });
  paintAlerts(); paintBell();
}

export function toggleFollow(address, name = null) {
  const key = String(address ?? "").toLowerCase();
  if (!EVM.test(key)) return false;
  const was = isFollowing(key);
  const label = name ?? knownIdentity(address)?.name ?? null;
  if (was) state.follows = state.follows.filter((row) => row.address !== key);
  else {
    if (state.follows.length >= MAX_FOLLOWS) { toast({ title: `Up to ${MAX_FOLLOWS} traders`, sub: "Unfollow one to follow another." }); return false; }
    state.follows = [{ address: key, name: label, at: Date.now() }, ...state.follows];
  }
  save();
  const who = label ?? short(address);
  if (was) toast({ title: `Unfollowed ${who}` });
  else toast({ title: `Following ${who}`, sub: alertsOn() ? "You'll hear the moment they trade." : "Turn on alerts to hear the moment they trade." });
  announce();
  if (alertsOn()) sync().catch(() => {});
  else if (!was && !state.offered && supported() && permission() === "default") { state.offered = true; openAlerts(); }
  return !was;
}

function announce() {
  document.dispatchEvent(new CustomEvent("follows", { detail: follows() }));
  paintBell();
  if (!$("#alerts")?.hidden) paintAlerts();
}

function paintBell() {
  const bell = $("#alerts-open");
  const badge = $("#alerts-badge");
  if (!bell || !badge) return;
  const count = state.follows.length;
  badge.hidden = count === 0;
  badge.textContent = count > 9 ? "9+" : String(count);
  bell.classList.toggle("on", alertsOn());
  bell.title = alertsOn() ? "Following · alerts on" : "Following";
}

export function openAlerts() {
  const overlay = $("#alerts");
  if (!overlay) return;
  overlay.hidden = false;
  paintAlerts();
  loadFeed();
  clearInterval(state.feedTimer);
  state.feedTimer = setInterval(() => { if (!overlay.hidden) loadFeed(); }, FEED_MS);
}

export function closeAlerts() {
  const overlay = $("#alerts");
  if (overlay) overlay.hidden = true;
  clearInterval(state.feedTimer);
  state.feedTimer = null;
}

function paintAlerts() {
  const body = $("#alerts-body");
  if (!body || $("#alerts").hidden) return;
  const perm = permission();
  let status;
  if (!supported()) {
    status = `<div class="al-card"><b>This browser can't receive push.</b><span class="sub">Safari on a Mac, Chrome, Edge and Firefox can. On iPhone, Desk itself does, and it can copy the trades too.</span><button class="btn btn-ghost btn-sm" type="button" data-alerts-phone>Alerts on iPhone</button></div>`;
  } else if (perm === "denied") {
    status = `<div class="al-card"><b>Notifications are blocked for trydesk.trade.</b><span class="sub">Allow them in the browser's site settings, then come back here.</span></div>`;
  } else if (alertsOn()) {
    status = `<div class="al-card al-on"><b><i class="dot"></i>Alerts are on in this browser</b><span class="sub">The moment a trader you follow opens, adds to, trims or closes a position, you hear about it, with this tab closed too.</span><button class="btn btn-ghost btn-xs" type="button" data-alerts-off>Turn off</button></div>`;
  } else {
    status = `<div class="al-card"><b>Hear it the moment they trade</b><span class="sub">Opens, adds, trims and closes on Perpl, as notifications from this browser. Nothing else, and nothing once you unfollow.</span><button class="btn btn-primary btn-sm" type="button" data-alerts-on>Turn on alerts</button></div>`;
  }
  const rows = state.follows.length
    ? state.follows.map((row) => `<div class="al-row">${person(row.address, knownIdentity(row.address) ?? (row.name ? { name: row.name } : undefined), { size: 28 })}<button class="btn btn-line btn-xs" type="button" data-unfollow="${esc(row.address)}">Unfollow</button></div>`).join("")
    : `<div class="sub" style="padding:6px 0 2px">Follow a trader from their profile, the Traders page, or a token's tape.</div>`;
  body.innerHTML = `${status}
    <div><div class="al-h">Following · ${state.follows.length}</div>${rows}</div>
    <div><div class="al-h">Latest moves</div><div id="alerts-feed">${feedHTML()}</div></div>
    <div class="al-card"><b>Also on your iPhone</b><span class="sub">Desk pushes the same alerts to your phone and, if you want, copies the trades under your rules.</span><button class="btn btn-ghost btn-xs" type="button" data-alerts-phone>Open in Desk</button></div>`;
  hydratePeople(body);
}

async function loadFeed() {
  const addresses = state.follows.map((row) => row.address).slice(0, 25);
  if (!addresses.length) { state.feed = { events: [], perps: [], pending: [] }; paintFeed(); return; }
  try { state.feed = await api(`/api/activity?view=following&addresses=${addresses.join(",")}`, { ttl: 10_000 }); }
  catch (error) { state.feed = { error: String(error?.message ?? error) }; }
  paintFeed();
}

function paintFeed() {
  const host = $("#alerts-feed");
  if (!host) return;
  host.innerHTML = feedHTML();
  hydratePeople(host);
}

function feedHTML() {
  const feed = state.feed;
  if (!state.follows.length) return `<div class="sub">Nothing to show yet.</div>`;
  if (!feed) return `<div class="sub pulse">Reading…</div>`;
  if (feed.error) return `<div class="sub">The feed could not be read right now.</div>`;
  const perps = (feed.perps ?? []).map((row) => ({
    time: Number(row.time), wallet: row.wallet, where: "Perpl",
    text: `${VERBS[row.kind] ?? row.kind} ${row.market} ${row.side}${row.leverage ? ` ${Number(row.leverage) % 1 ? Number(row.leverage).toFixed(1) : Number(row.leverage)}×` : ""}`,
    amount: row.value != null ? fmtUsd(row.value, { compact: true }) : "",
  }));
  const spot = (feed.events ?? []).map((row) => ({
    time: Number(row.time), wallet: row.wallet, where: row.chainIndex === "501" ? "Solana" : "Monad",
    text: `${row.side === "buy" ? "Bought" : "Sold"} ${row.symbol ?? "a token"}`,
    amount: row.value != null ? fmtUsd(row.value, { compact: true }) : "",
  }));
  const rows = [...perps, ...spot].filter((row) => Number.isFinite(row.time)).sort((a, b) => b.time - a.time).slice(0, 15);
  const pending = feed.pending?.length ?? 0;
  const note = pending ? `<div class="sub" style="margin-bottom:6px">Indexing ${pending} ${pending === 1 ? "wallet" : "wallets"} for the first time; trades appear shortly.</div>` : "";
  if (!rows.length) return `${note}<div class="sub">No moves in the last two weeks.</div>`;
  return note + rows.map((row) => `<div class="al-move">${person(row.wallet, undefined, { size: 20, via: false })}<b class="num">${esc(row.amount)}</b><span class="meta"><span>${esc(row.text)}</span><span>${esc(row.where)}</span><span>${esc(ago(row.time))}</span></span></div>`).join("");
}

export function startFollows() {
  paintBell();
  $("#alerts-open")?.addEventListener("click", () => openAlerts());
  const overlay = $("#alerts");
  overlay?.addEventListener("click", (event) => {
    if (event.target === overlay || event.target.closest("[data-close]")) { closeAlerts(); return; }
    if (event.target.closest("[data-alerts-on]")) { enableAlerts(); return; }
    if (event.target.closest("[data-alerts-off]")) { disableAlerts(); return; }
    if (event.target.closest("[data-alerts-phone]")) {
      closeAlerts();
      handoff({ title: "Alerts on your iPhone", sub: "Desk pushes the same alerts to your phone and can copy the trades under your rules. Scan to get Desk." });
      return;
    }
    const unfollow = event.target.closest("[data-unfollow]");
    if (unfollow) { toggleFollow(unfollow.dataset.unfollow); return; }
    // A trader or a link inside the sheet opens over the page; the sheet leaves first.
    if (event.target.closest("a.person[data-person]") || event.target.closest("a[data-link]")) closeAlerts();
  });
  document.addEventListener("keydown", (event) => { if (event.key === "Escape" && overlay && !overlay.hidden) closeAlerts(); });
  if (!supported()) return;
  navigator.serviceWorker.addEventListener("message", (event) => {
    if (event.data?.type === "navigate" && typeof event.data.url === "string") {
      const url = new URL(event.data.url, location.origin);
      navigate(url.pathname + url.search);
    }
    if (event.data?.type === "resubscribe" && state.subscribed) sync().catch(() => {});
  });
  // On every visit: the worker, and whether this browser already holds a seat.
  registration().then(async (reg) => {
    const sub = await reg.pushManager.getSubscription();
    state.subscribed = Boolean(sub) && permission() === "granted";
    paintBell();
    if (state.subscribed && state.follows.length) sync().catch(() => {});
  }).catch(() => {});
}
