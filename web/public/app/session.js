// The signed-in account, in memory only. Keys are derived from the passkey's PRF at sign-in
// and live until lock: closing the tab, fifteen minutes without a touch, or the Lock button.
// Nothing here is written to storage; the next visit asks the passkey again.
import { deriveTradingKey, deriveWallet } from "./keys.js";

const IDLE_MS = 15 * 60_000;
let current = null;
let idleTimer = null;
const listeners = new Set();

function wipe(bytes) { if (bytes instanceof Uint8Array) bytes.fill(0); }
function emit() { for (const fn of listeners) { try { fn(current); } catch {} } }

function armIdle() {
  clearTimeout(idleTimer);
  if (current) idleTimer = setTimeout(() => lock("idle"), IDLE_MS);
}

/// Derives the wallet and the trading key at `tradingIndex` and keeps them until lock.
export function unlockWithPRF(prf, { tradingIndex = 0 } = {}) {
  lock("replace");
  const wallet = deriveWallet(prf);
  const trading = deriveTradingKey(prf, tradingIndex);
  current = { address: wallet.address, wallet, trading, prf: new Uint8Array(prf), at: Date.now() };
  armIdle();
  emit();
  return current;
}

/// Another trading key from the same PRF, for an enrolment that has to move to the next index.
export function retradingKey(index) {
  if (!current) return null;
  wipe(current.trading.seed);
  current.trading = deriveTradingKey(current.prf, index);
  return current.trading;
}

export const session = () => current;
export const isUnlocked = () => current !== null;

export function lock(reason = "user") {
  if (!current) return;
  wipe(current.wallet.privateKey); wipe(current.trading.seed); wipe(current.prf);
  current = null;
  clearTimeout(idleTimer); idleTimer = null;
  emit();
  return reason;
}

export function onSession(fn) { listeners.add(fn); return () => listeners.delete(fn); }

for (const event of ["pointerdown", "keydown"]) document.addEventListener(event, armIdle, { passive: true });
window.addEventListener("pagehide", () => lock("pagehide"));
