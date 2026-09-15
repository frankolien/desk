# Perpl order 400 audit — 2026-09-15

## Outcome

The rejection was a client/server protocol mismatch, not a network timeout. Desk was
successfully authenticated and Perpl was parsing the `mt: 22` request, then rejecting
its contents with status code 400.

Two fields in Desk differed from Perpl's deployed version-235 web client:

1. Desk chose the first account in the wallet snapshot. The deployed client selects the
   account whose `in` (exchange instance) equals the selected market's `instance_id`.
   A wallet may contain accounts for several exchange instances, so the first account is
   not necessarily valid for the requested market.
2. Desk encoded `lb` as `head block + order_ttl_blocks`. The deployed version-235 client
   encodes `lb: 0` for an order. The advertised TTL remains useful as a local UI timeout,
   but the future block must not be sent in the wire request.

Desk also decoded the numeric status but discarded `status.error`. That is why the UI
only showed “code 400” rather than Perpl's actual rejection sentence.

## Implemented correction

- Decode each market's `instance_id`.
- Select and seed the request counter from the wallet account with the matching `in`.
- Encode `lb: 0` for version-235 orders, while retaining a local deadline derived from
  `order_ttl_blocks` so a missing response cannot leave the UI spinning forever.
- Preserve nested `status.error` through the tracker and display it to the user.
- Added regressions for a deliberately wrong first account, the v235 `lb` sentinel, and
  nested rejection text.

## Verification

- `swift test --package-path DeskKit`: 396 tests passed.
- iPhone Air simulator build: succeeded.
- `git diff --check`: clean.

## Primary sources

- [Perpl documentation](https://docs.perpl.xyz/) — architecture and Monad deployment.
- [Perpl testnet public context](https://testnet.perpl.xyz/api/v1/pub/context) — live
  protocol version, market `instance_id`, exchange instances, and order TTL.
- [Perpl testnet deployed client bundle](https://testnet.perpl.xyz/assets/index-CeNIxKAx.js)
  — current order-frame construction and account-selection behavior. The bundle is
  minified, so conclusions above were verified against executable field assignments and
  locked into readable regression tests rather than copied into application code.

## Remaining live check

Only Perpl can confirm an actual fill. Run the newly built app with the real enrolled
key and submit the minimum-size order. If Perpl rejects a different condition (balance,
margin, forwarding, or market state), Desk now surfaces its exact `status.error` rather
than hiding it behind code 400.

## Follow-up: false expiry after a real fill

The live check opened a 0.06518 BTC long, but Desk later called it expired. Version 235
sends order updates as a batch (`mt: 24`, `d: [...]`) and correlates each item with the
order request id in `rq`. Desk was still looking for the older root-level `sn`, so it
ignored the settlement while correctly applying the separate position update. The
tracker now stores both correlation identifiers and settles the UI from the batched
`rq`. A pinned regression covers this exact frame shape; the full suite now contains
397 passing tests.
