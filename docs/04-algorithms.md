# Desk: the algorithms

Every formula the app computes, with the trap beside it. Written 12 September 2026 from
research that checked Perpl's contract and live context endpoint rather than its prose.
Where Perpl's documentation and Perpl's contract disagree, this follows the contract and
says so.

An off-by-ten in a leveraged order is the worst bug this app can ship. Most of this
document exists to make that bug impossible rather than unlikely.

## 1. Numbers

**Nothing in this app does arithmetic in `Double`, and nothing does arithmetic in
`Decimal` either.**

`Double` is obvious. `Decimal` is not, and it is worse than folklore suggests. On Swift
6.3.1 `Decimal(0.1)` is now exact, so the test everyone writes passes and the bug ships
anyway — while `let size: Decimal = 0.07` is `0.07000000000000001024`. `NSDecimalRound`
with `.down` is **floor**, not truncation, so on a signed quantity it rounds away from
zero and makes a short position *larger*. Division truncates while reporting no error.

The representation is a scaled `Int64` carrying its own decimals, with `Int128`
intermediates for products. `Int128` needs iOS 18, which Desk already requires.

```
struct Scaled { let raw: Int64; let decimals: UInt8 }
```

Multiplication widens to `Int128`, divides by the scale, and narrows with an explicit
rounding rule. Never implicitly.

**Perpl's own documented scaling helper is float-based** — `Math.round(price * 10**d)`.
Do not port it. Measured, 12.4% of valid prices on a 0.01 tick lose a whole tick through
a `Double` pipeline: `0.29` at two decimals becomes 28, and `4.35` becomes 434.

Parsing is decimal-string in, integer out, with no float ever constructed. The keypad
already binds a decimal string rather than a number for exactly this reason.

## 2. Scale, which is per market and not a constant

Price and size decimals come from `GET /pub/context` per market. Two facts make
hardcoding them a demo-day bug:

- **`price_decimals + size_decimals` is not always 6.** It is 5 on mainnet ETH and on
  four testnet markets. Wherever the sum is not 6, the natural `p × s` shortcut for
  notional is exactly ten times wrong.
- **The same asset carries different decimals on testnet and mainnet.** A constant that
  works through the whole build breaks when the network changes.

Testnet BTC, the launch market: id **16**, `price_decimals` **1**, `size_decimals` **5**.
So the price grid is $0.10 and the lot is 0.00001 BTC. There is no tick-size field; the
grid is `10^-price_decimals`. Minimum order size is one size unit.

Notional, done correctly:

```
notionalRaw = Int128(priceRaw) * Int128(sizeRaw) / 10^(pd + sd - collateralDecimals)
```

with `collateralDecimals` = 6 for AUSD. Write the test on a market where `pd + sd = 5`.

## 3. Margin, and the encoding that inverts

`initial_margin` and `maintenance_margin` in `MarketConfig` are **divisors in
hundredths**, not percentages:

```
maxLeverage = initial_margin / 100
initialMarginRate    = 100 / initial_margin
maintenanceMarginRate = 100 / maintenance_margin
```

Testnet BTC: `initial_margin: 1500` → **15x** and a 6.667% initial margin.
`maintenance_margin: 2500` → **4%** maintenance.

The trap is that the maintenance number is *larger* while its rate is *smaller*, and
that Perpl's Types page says elsewhere that a `Fraction` is hundredths of a percent —
true for fees, false for these two. **The two readings coincide at exactly 1000**, so a
market with `initial_margin: 1000` passes either way and the misreading survives casual
testing.

Read as percentages, a fresh long's liquidation price comes out *above* its entry.

**The assertion that catches it**, for every market in the context response:

```
assert(maintenance_margin > initial_margin)
```

That inequality only holds under the correct reading, on every market, at any time.

Initial margin is a floor rather than a fixed value: it rises with open interest and
position size. `getMarginFractions(perpId, lotLNS)` returns the dynamic figure beside
the static one. Currently they are equal on testnet BTC.

Margin is **isolated only**. Cross is future work at Perpl, which simplifies everything
below.

## 4. Liquidation

**Perpl computes maintenance margin against the *entry* price, not the mark.** Perpl's
own "liquidation distance" prose uses the mark-based form and therefore contradicts its
own contract. The contract and Perpl's published worked example agree with each other,
so they win.

Let `E` be entry, `S` size, `C` collateral, `mm` the maintenance rate.

```
long:   C + S(P − E) = mm · S · E     →   P_liq = E(1 + mm) − C/S
short:  C − S(P − E) = mm · S · E     →   P_liq = E(1 − mm) + C/S
```

Against Perpl's own example — a $100,000 BTC long at 10x, so `S = 1`, `C = 10,000`,
`mm = 0.04`:

```
P_liq = 100,000 × 1.04 − 10,000 = 94,000       ✓ matches the published $94,000
mark-based form would give 90,000 / 0.96 = 93,750     ✗ 250 out
```

Because `C/(S·E)` is exactly `1/L`, the distance collapses to something worth putting on
a screen:

```
liquidation distance (fraction of entry) = 1/L − mm
```

10x with 4% maintenance is a 6% move, which is what the worked example says. **At BTC's
15x ceiling the distance is 1/15 − 0.04 = 2.67%**, which is the number the ticket should
make impossible to miss.

Liquidation triggers on **mark**, even though the requirement is computed at entry.
Proceeds split 80% to the holder, 10% insurance, 10% protocol — so a liquidated position
is not a total loss of margin, and saying that plainly is both more accurate and more
trustworthy than the industry's vagueness. Displayed PnL on a liquidated position is the
would-be PnL at exit and understates the real balance change for the same reason.

## 5. Profit and loss

```
unrealised (long)  = S × (mark − entry)
unrealised (short) = S × (entry − mark)
```

Mark, not last traded price. The percentage has **no standard denominator** across
exchanges, so pick one, and label it on screen with what it is divided by.

## 6. Funding

**The interval is 2,580 seconds. Forty-three minutes.** Not an hour. Annualising at
8,760 intervals instead of 12,223 understates funding by 28.4%.

Perpl's Funding page describes the rate as a *sum* of samples and its Price Indices page
as an *average*; they differ by a factor of about 720 and **the average is correct**.
There is no interest-rate term, unlike every centralised exchange.

Funding settles against the spot index rather than mark, and virtually, through an
accumulator — no per-position transfer occurs. Positions carry entry and exit funding
sums, so funding since entry is a subtraction rather than something to accumulate
client-side.

The wire encoding is undocumented and was derived, then reproduced on **15 of 15 live
markets across both networks including negative rates**:

```
ppl = trunc(idx × rate × div / 10^6)
```

which establishes that `rate` is in micros — a fact no field name reveals; the contract
calls it `fundingRatePct100k`.

Each interval emits **two** funding messages with the same event block: a provisional
one with an estimated timestamp, then a republish with the exact one. Treat a repeated
event block as an update, not a new event.

**Unresolved, and owed a live test:** the sign of `premiumPnlCNS`. The prose and the
formula disagree, and the ABI type name favours positive meaning received. Do not ship
a "funding paid or received" line until a real position has settled at least one
interval and the sign is observed.

## 7. Fees

Maker and taker are in **micros**, not basis points. Testnet **45 / 345** = 0.45 and
3.45 bps; mainnet **90 / 690** = 0.9 and 6.9 bps.

**Fees are charged only on size that opens or increases a position.** Closing and
reducing are free. Two consequences:

- The ticket must show an opening cost, never a round trip.
- **Every close path must use order type 3 or 4.** Closing a long by opening a short
  inverts the position and pays taker on the way; on a $9,931 position that is $6.85 for
  the same economic action. The close types are also exempt from the initial margin
  check, which is what lets an underwater position always be closed.

## 8. Building an order

There is no market order type and no reduce-only flag. Everything composes:

| Intent | Encoding |
|---|---|
| Limit | `t: 1/2`, `p: <price>`, `fl: 0` |
| Market | `p: 0`, `fl: 4` (IOC), `ms: <slippage bps>` |
| Post-only | `fl: 1` |
| Close | `t: 3` (close long) or `t: 4` (close short) |
| Cancel | `t: 5` with `oid`. Not a separate message type |

`lv` is leverage in hundredths, so 1x is `100` and 15x is `1500`.

`lb` is the last execution block and must satisfy `head < lb <= head + order_ttl_blocks`,
where the TTL is 20 blocks on both networks. At 0.305s per block that is about six
seconds of validity, so `lb` is computed at send time from a fresh head, never from a
head read when the ticket opened.

`rq` is the per-account idempotency key and **must strictly increase**. Seed it on every
connect as `max(localCounter, account.lfr) + 1`; a value at or below `lfr` rejects with
`sr: 32`. `sn` is a separate frame id, must be non-zero — the status response omits the
correlation field when `sn` was zero — and is what `mt: 3` echoes back.

## 9. Rounding, stated once

| Quantity | Rule | Why |
|---|---|---|
| Size | **round toward zero**, always | Rounding up can exceed available margin. Use truncation, not `.down`, which is floor and grows a short |
| Price, buy | round **down** to the grid | Never pay more than intended |
| Price, sell | round **up** to the grid | Never accept less |
| Fee estimate | round **up** | Never understate a cost |
| Liquidation, long | round **up** | Never show more headroom than exists |
| Liquidation, short | round **down** | Same |
| Displayed PnL | round toward zero | Never overstate a gain |

The asymmetry is deliberate: every rule rounds against the user's interest so that no
displayed number is more optimistic than reality.

## 10. Walking the book

A market order's estimate walks the visible levels, accumulating until the size is
filled, all in scaled integers:

```
remaining = sizeRaw
cost = 0
for level in book(side):
    take = min(remaining, level.size)
    cost += Int128(level.price) * Int128(take)
    remaining -= take
    if remaining == 0: break
if remaining > 0:  the visible book cannot fill this
```

Average price is `cost / filled`, and price impact is that against the mid. Perpl caps
market-order slippage at `order_max_market_slippage_bps`, **1000 on testnet BTC** — ten
percent, read live rather than taken from the docs — so the honest question on a thin book is not
"what will this cost" but "will this fill at all" — and an order that cannot fill within
the cap should say so before the confirm, not after.

Bids arrive best-first; a level with `o: 0` is a deletion.

## 11. Signing

```
REST    chain_id \n METHOD \n target \n ts \n nonce \n sha256(body) lowercase hex
Socket  chain_id \n trading-ws-signin \n ts \n nonce
```

Newline separated, no trailing newline. `target` is the path with its query, byte-exact
as sent. Timestamps are **milliseconds** with a ±30 second window; nonces are base64url,
unpadded, single-use. Signatures are base64url Ed25519, unpadded. An empty body hashes
as sha256 of zero bytes.

The timestamp and the nonce must be generated once and used for both the canonical
string and the headers. The gateway rebuilds the canonical string from the headers, so
generating them twice is a rejected signature that reads like a clock problem.

**CryptoKit's Ed25519 is hedged rather than deterministic.** Signing the same bytes
twice gives two different signatures, both valid — Apple randomises the nonce
derivation on purpose. So a signature can never be compared against a fixture from
another implementation; it has to be verified. Perpl verifies rather than compares, and
its idempotency comes from `rq`, so the only consequence is for tests.

The enrolment digest's trap survives from the spike, and a live payload on 13 September
showed it is **two fields, not one**: `chainId` arrives as `"0x279f"` and `time` as
`"0x1a09a29c91c"`, both typed as integers. Either hashed as characters gives a digest
the gateway rejects — and viem produces that wrong digest silently rather than throwing,
which is why the integer encoder accepts decimal and hex and nothing else.

The rest of the payload is worth recording, since it is server-supplied and has changed
once already. Domain `EIP712Domain(string name,string version,uint256 chainId,address
verifyingContract,bytes32 salt)`; primary type `PerplRegisterApiKey(address signer,
string statement,string publicKey,string scope,string label,string expiresAt,string
ipCidrs,string origin,string builderId,string maxBuilderFeePer100K,uint64 time)`. Every
message field is a string except `time` and `signer`, `origin` comes back empty for a
native client, and `publicKey` is echoed as **base64url**, not the 0x-hex that was sent.

## 12. Gas

```
gasLimit = ceil(estimateGas × 1.075)
maxPriorityFeePerGas = 2 gwei
maxFeePerGas = max(200 gwei, 2 × baseFee + priority)
```

The multiplier is Monad's own published constant. Monad charges the **limit**, so the
limit is the bill and a conventional 1.5x to 2x library default is an 86% overcharge.
A plain MON transfer is hardcoded at 21,000 with no buffer. When an estimate reverts,
surface the revert; never substitute a large limit.

Below 100 gwei a transaction is dropped at the mempool as `FeeTooLow`. The cap is a
ceiling rather than a charge, so headroom is free.

Measured costs at 102 gwei: `approve` 0.0078 MON, `requestFunds` 0.0143 MON. The faucet
call is cheaper against an address that already holds AUSD — about 113,000 gas rather
than 130,000 — because the recipient's balance slot is already non-zero. That gap is
storage cost, not a signal about cooldown state.

## 13. Freshness

Every streamed value carries the time it was observed, and freshness is computed from
**the message's own timestamp** — never from socket state, because a socket can be open
and stalled. The four states and their thresholds are in `03-screen-designs.md`; the
disconnected threshold should equal Perpl's on-chain maximum index age, so that the
moment the interface stops trusting a price is the moment the contract stops accepting
orders priced from it.

## What still needs a live test

Owed on day one, with a funded testnet account, because no authenticated frame has been
observed on the wire:

1. The sign of `premiumPnlCNS`.
2. Every account-side message shape: wallet snapshot, account update, orders, fills,
   positions. All current models come from type definitions, not bytes.
3. That `maintenance_margin > initial_margin` holds on every live market.
4. The four order flags against the real gateway.
5. Book delta semantics, including the `o: 0` deletion, on a book with real depth.


## 14. What the wallet key is allowed to sign

Added 13 September, after an audit of `DeskChain` found that nothing stopped it signing
anything.

The enrolment payload is chosen by Perpl and hashed by us, and the wallet key signs the
result. EIP-712 hashing cannot tell an enrolment from an ERC-2612 `Permit` — both are
valid typed data, and a correct implementation hashes both correctly. So a gateway that
answered `/api-key/payload` with

```
primaryType: "Permit"
domain:      { name: "AUSD", chainId: "0x279f", verifyingContract: <the AUSD token> }
message:     { owner: <the user>, spender: <an attacker>, value: 2^256-1, deadline: 2^256-1 }
```

would have been handed a signed unlimited allowance over the user's collateral, with
every line of the hashing behaving exactly as specified. The `mac` field sitting beside
`typed_data` is not a defence either: it is Perpl's own, and Perpl is the party being
distrusted here.

The fix is that the digest function which hashes anything is no longer reachable from
outside the module. The way in is `digest(_:expecting:)`, and what it pins is:

| Pinned | Why that one |
|---|---|
| The canonical type string | Load-bearing. It fixes the primary type and every field name and field type in a single comparison, so no substituted struct can match it. |
| The domain type string | Same, for the domain. |
| `domain.name`, `domain.version` | Cheap, and they move together with a real protocol change rather than an attack. |
| `domain.chainId` | Against a payload for the other network. |
| `message.signer` equals our own address | Binds the payload to the key about to sign it. |
| `message.statement` | The sentence the user is told they are agreeing to. |
| No message field the type does not declare | A field outside the type is a field outside the signature, so it must not exist rather than be quietly ignored. |

The last row is the only one that is not about substitution: `structHash` iterates the
declared fields and ignores the rest, so an undeclared field would be shown by any
screen that renders the message and covered by nothing.

The same audit found the encoder itself accepted more than it should. `uint8` and
`int128` were encoded as though they were `uint256`, which produces a digest no Solidity
verifier agrees with; `intN` could not be encoded at all; `bytesN` was left-padded where
the ABI right-pads; odd-length hex silently dropped its last nibble, so `0xabc` and
`0xab` hashed alike; `UInt8(_:radix:)` honours a sign prefix, so a run of `+1+2+3…`
parsed as a valid twenty-byte address; and `Character.wholeNumberValue` answers for
Arabic-Indic and fullwidth digits, so `"١٠٠"` parsed as a hundred and `"1²"` as twelve —
the same grapheme-cluster trap `DecimalText` already carried a warning about. Each is
pinned to a viem vector in `Tests/DeskChainTests/EIP712Vectors.json`, generated by
`reference/perpl/eip712-vectors.mjs`.


## 15. What a venue is not allowed to decide

Added 13 September, after an audit of `DeskPerpl`. Section 14 covered the payload the
wallet key signs; this is the rest of the same argument, applied to everything the
gateway sends.

Four of the findings were the venue steering the client rather than informing it. A
`maintenance_margin` of zero passed validation and made the displayed margin percentage
infinite. An `order_max_market_slippage_bps` of zero passed, and then made **every close
throw** — a server able to lock a user out of their own position with one field. A head
block near `Int64.max` passed, and `headBlock + orderTTLBlocks` then trapped, which in
Swift is a dead process rather than a rejected order. The same was true of the
gateway's `lastForwarded` seed, which arrives on every connect and was fed straight into
`+ 1`. `validated()` now bounds all four, and the arithmetic saturates where a bound is
not enough.

Two were order construction:

| Was | Cost |
|---|---|
| `close` never checked the size scale | A 1.5 BTC close at the wrong scale went out as **0.015 BTC**, and the position stayed open with nothing on screen to say so |
| `limit` accepted price zero | Price zero is how this venue spells *marketable*, so a limit order carrying it is a market order with good-till-cancelled and **no slippage bound at all** — exactly what `market` exists to prevent |

And `initialMarginFraction / 100 * 100` rounded a 12.5x market's ceiling down to 12x,
refusing leverage the venue allows. Leverage is now checked against the fraction itself.

The socket findings were lifecycle. The channel was stored before the sign-in frame was
written, so `isConnected` was true and `send` succeeded while still unauthenticated —
and the gateway answers a pre-authentication order by closing 3401, which the app would
have reported as a refused key rather than its own mistake. There is now an
`isAuthenticated` flag set only by the wallet snapshot. A `disconnect()` during the
handshake was undone by the handshake completing afterwards, leaving a heartbeat running
forever with no reference left to cancel it; a generation counter closes that. And
`frames()` could be called twice, starting two independent readers that took alternate
frames, so each consumer silently missed half of its own order statuses.

The subtlest one is worth its own paragraph, because it is a property of structured
concurrency rather than of this code. A `withThrowingTaskGroup` that races work against
a sleep bounds **when the error is thrown**, not when the call returns: cancelling the
losing child is only a request, and the group awaits it on the way out. Measured at two
seconds against a fifty-millisecond timeout when the loser ignores cancellation, which a
read blocked on a live socket does. Closing the channel is what actually unblocks the
read, so that is what the timeout now does — and against the gateway's 10.2 second
pre-authentication idle close, that path is the one that must not stall.

One bug was introduced by the fix for another and is recorded because the shape recurs:
tolerating an unparseable frame with `try? InboundFrame(payload: Data(try await
channel.receive().utf8))` swallows the *read's* error too, so a closed socket becomes a
loop calling `receive()` forever at full tilt. The test suite hung at 360% CPU, which is
how it was found. The read's error has to escape; only the parse may be tolerated.


## 16. The ticket, assembled

Built 13 September. Everything the user sees before Face ID is asked for, in one value,
because a screen that renders four of the five figures and omits the fifth is a screen
that omits the liquidation price.

Worked through on the live BTC configuration — price to a tenth, size to a
hundred-thousandth, taker 345 micros, initial margin fraction 1500, maintenance 2500 —
for 0.01 BTC long at 10x marked at 76,719.0:

| Figure | Value |
|---|---|
| Notional | 767.190000 |
| Margin | 76.719000 |
| Fee | 0.264681 |
| **Total leaving collateral** | **76.983681** |
| Liquidation | 72,142.4 |
| Buffer | 6.0000% |

Three things that are decisions rather than arithmetic.

**The total, not the margin.** What leaves the collateral balance is margin plus fee. A
ticket showing only the margin surprises the user by the difference at exactly the moment
they can least afford it, so `total` is its own field and affordability is checked
against it — not against `margin`.

**The fee is deducted from what backs the position.** Whether the venue takes the taker
fee out of position collateral or out of free collateral is not documented, and it moves
the liquidation price. Deducting it is the conservative reading: if we are wrong, the
real liquidation sits *further* away than the screen said, never nearer. That is the same
rule as §9's rounding — never show more headroom than exists.

**The buffer is stated, not implied.** At the 15x ceiling with 4% maintenance it is
2.6666%, and at 10x it is 6%. A number that small is the whole risk of the trade and the
ticket has to make it impossible to miss.

The quote also carries when it was struck. Past sixty seconds it is re-priced rather than
sent — Apple Pay re-asks for intent on the same interval and for the same reason: an
estimate the user has stopped looking at is not an estimate they agreed to.
