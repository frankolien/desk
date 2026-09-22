/// Keep newly followed or stale wallets ahead of the historical index backlog,
/// without letting them starve every other wallet in the pool.
export function selectWallets(tracked, urgent, cursor = 0, limit = 12, urgentLimit = 6) {
  const trackedSet = new Set(tracked);
  const priority = [...new Set(urgent)].filter((wallet) => trackedSet.has(wallet)).slice(0, urgentLimit);
  const prioritySet = new Set(priority);
  const regular = tracked.filter((wallet) => !prioritySet.has(wallet));
  const start = regular.length ? cursor % regular.length : 0;
  const regularCount = Math.min(regular.length, Math.max(0, limit - priority.length));
  const rotated = [...regular.slice(start), ...regular.slice(0, start)].slice(0, regularCount);
  return { wallets: [...priority, ...rotated], nextCursor: cursor + regularCount };
}
