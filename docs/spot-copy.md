# Spot copy trading

Auto-Copy for followed wallets' **token** trades on Monad. It runs on Desk's server while the phone
is closed, and Desk never holds the user's money. It is the spot sibling of server copy for perps
(`docs/server-copy.md`), and it reuses that feature's device key, rules API, log and notifications.

## How others do it

| | Custody | What users set | Fee |
|---|---|---|---|
| GMGN (de facto template) | Server-held keys, not exportable | Fixed amount, or match the leader up to a max; buy once per token; follow-sells proportionally for copied positions only; TP/SL; market-cap, liquidity, age and leader-buy-size filters; blacklist; pauses after 3 failures | 1% + priority fee |
| Trojan, Maestro, Banana Gun | Bot holds the key | Fixed or % of the leader's buy with a max; copy sells; daily loss limit | ~1% (0.5% manual) |
| Axiom | Turnkey-hosted wallets | Tracker + alerts; copying only via third-party extensions | 0.75–0.95% |
| Fomo, OKX, Bitget wallets | Self-custodial (Privy / MPC) | One-tap follow-buy, not automatic | 0.5% |

Every product that copies **automatically** does it by holding the user's key. Nobody on Monad
ships auto-copy yet. Desk can be the first to do it without custody, because every Desk wallet
already runs Calibur, Uniswap's audited EIP-7702 account.

Known failure modes this design answers:

- **Honeypots and sell taxes.** A round-trip quote is checked before every buy.
- **Exit liquidity.** A max per buy and a daily cap.
- **Leaders who farm their copiers.** The leader-buy-size filter and buy-once-per-token.
- **Fees eating small accounts.** One flat fee, and Desk pays the gas.
- **Missed sells.** The hook records exactly what each copy bought.

## Custody: a fenced key, not a held key

Turning Auto-Copy on is one Face ID. It signs one Calibur `SignedBatchedCall`, plus an EIP-7702
authorization if the wallet doesn't run Calibur on Monad yet. Desk's relayer submits it and pays the
gas. The batch makes three calls:

1. `register(Key{Secp256k1, Desk's copy address})`
2. `update(keyHash, {hook: DeskCopyHook, expiry: now + N days, admin: false})`
3. `DeskCopyHook.configure(keyHash, perTrade, perDay)` (AUSD limits)

Desk's copy key is **one** AWS KMS secp256k1 key, the same for every wallet. It never leaves KMS. It
calls `wallet.execute(BatchedCall)` directly, so it is both the signer and the gas payer, with no
relayer nonces and no signatures to forward. Calibur runs `DeskCopyHook`
(`contracts/src/DeskCopyHook.sol`) around every call the key makes. The hook lets through only:

- **Buys:** `AllowanceHolder.exec` that spends AUSD, through the live 0x Settler (read from 0x's
  deployer on-chain), paying the wallet itself with a non-zero floor, within the per-trade and
  per-day limits. The hook records how much of the token arrived.
- **Sells:** up to what copied buys brought in, and only for AUSD.
- **Approvals:** to AllowanceHolder, and only for AUSD or a copied token.

Everything else reverts: transfers, other approvals, MON, calling the hook (so the key can't raise
its own limits), ERC-1271 signatures (no Permit2 permits), ERC-4337 user ops, and managing the
wallet. **Worst case if Desk's key leaks:** it can spend up to the day limit on junk tokens, or sell
copied positions badly. It can never move funds out, and never touch what the user holds on their
own. The expiry ends the key without any action from the user.

Turning off is one Face ID. It signs `revoke(keyHash)`, and Desk relays it. If Desk ever didn't, the
app can send the same call itself with the user's own gas.

**Monad's reserve rule.** A delegated EOA's MON balance can't be lowered *by value transfers* below
10 MON. Gas is exempt. Copies spend only AUSD and Desk pays the gas, so copying is never affected.
The user's own MON sends and MON-paid buys must leave 10 MON while the wallet is delegated, so the
app caps "Max" accordingly and says why. The enable sheet states this.

## The copy loop (copyd, `web/copyd/spot*.mjs`)

**Detection.** The worker's fast lane re-indexes followed wallets every 12 s into `wl:<address>`.
It also reads `copy:spot:leaders`, so every copied leader is in that lane. copyd reads those ledgers
every 3 s and diffs them against its own marker, `copy:spot:seen:<leader>`. End-to-end latency is
about 15–25 s today. Moving to direct block subscription for leaders is the planned next step.

**Buy rule** (per copier, per leader event):

- Skip in these cases:
  - the leader's buy is under the minimum, or over the "bait" maximum
  - the token is blacklisted
  - buy-once is on and the copier already holds a copied position in the token
- Amount: the fixed AUSD amount, or the leader's USD size, capped at the per-trade max. The hook
  enforces the cap on-chain anyway.
- **Round-trip check:** quote the token back to AUSD for the expected output. If it would return
  under 85% of the spend (tax, honeypot, or no depth), skip it as "Can't sell back".
- Quote 0x with `taker = wallet`, `slippageBps` from the copier's rules, and the integrator fee in
  AUSD. Simulate the batch `[AUSD.approve(holder, amount), holder.exec(...)]` from Desk's key, then
  send it.

**Sell rule.** The leader sold a fraction *f* of their holding, so sell *f* of the copy's position,
or all of it when the leader closed out. The hook's `copied(wallet, keyHash, token)` is the
position. Selling more than that is impossible.

**Safety.** These carry over from server copy:

- Single-flight per copier.
- An intent written before the send, so a crash never double-sends.
- Pause after 3 consecutive failures.
- The global `copy:halt`.
- An hourly trade limit.

**Pushes.** "Copied 0xab…cd: 5 AUSD → 1.2M PEPE", the same through the API relay.

## Money

- **Fee:** `COPY_FEE_BPS` (default 50 = 0.5%) on every copied buy and sell. It is taken in AUSD
  through 0x's integrator fee (`swapFeeRecipient`, `swapFeeToken = AUSD`), so Desk never collects
  memecoins.
- **Gas:** Desk pays the MON for every copy. On Monad that is about 0.03–0.05 MON per swap. The
  fee covers it from about $10 trades upward.
- **Market:** the market charges 1% (GMGN, Trojan, Maestro); wallets charge 0.5% (Bitget, Fomo).
  Desk sits at the wallet price, with gas included, and is the only one that doesn't hold the key.

## Settings (per followed wallet)

| Setting | Default | Where it's enforced |
|---|---|---|
| Amount per buy | 10 AUSD, fixed | server |
| Or match leader, up to | off | server |
| Max per buy | 25 AUSD | **chain** (`perTrade`) |
| Max per day, all leaders | 100 AUSD | **chain** (`perDay`) |
| Copy sells | on, proportional | server; chain caps at what was copied |
| Buy each token once | on | server |
| Skip leader buys under / over | $250 / none | server |
| Slippage | 5% | server (0x `slippageBps`) |
| Runs for | 30 days | **chain** (key expiry) |

Server rules change instantly with the device key. Changing the chain limits or the expiry needs one
Face ID.

## Pieces

1. `contracts/`: `DeskCopyHook`, fork-tested against real Calibur and real 0x quotes. Deployed
   with CREATE2 at an address whose low bits are `11110`.
2. `web/copyd/spot*.mjs`: detection, rules, quotes, simulation, sending, log.
3. `web/api/_copy.mjs`: `spot-prepare`, `spot-enable`, `spot-rules`, `spot-disable`.
4. App: the Auto-Copy sheet on token wallets, the enable sheet (one Face ID), the activity log, and
   the reserve-aware MON max.
5. Ops: the KMS key (`ECC_SECG_P256K1`), funded with MON for gas; the fee recipient; and the hook
   deployment.
