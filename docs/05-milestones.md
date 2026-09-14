# Desk: the milestones

The schedule, the cut line, and the risks. Written 12 September 2026, which is day one.
This document supersedes the build order in `01-technical-spec.md`.

**Thirty-two days.** Code starts today; the bounty closes **14 October 2026 at 04:59
GMT+1**. Desk and Olien on Monad now run in parallel rather than one behind the other,
so this schedule assumes full days rather than afternoons.

## Today, before anything else

Three items, ordered by lead time rather than by importance. The first has a lead time
longer than the slack in this schedule.

1. ~~**Check the Apple Developer account type.**~~ **Checked 13 September: it is an
   individual account, and that is fine.** Guideline 5.1.1(ix) — which added "crypto
   exchanges" on 13 November 2025 and requires a legal entity — is applied at App Store
   review, and the path here is **internal TestFlight, which has no review step**. So the
   two-to-four week re-enrolment is a problem for shipping publicly after the bounty, not
   a problem for the bounty. Do not start it now; it would consume the schedule to solve
   something nothing depends on.

   **Confirmed paid on 13 September.** Associated Domains is available, so the
   `webcredentials:` entitlement, the passkey ceremony and Face ID are all reachable.
   Nothing about the Apple account blocks this project any longer.

2. **Claim testnet AUSD now, and again tomorrow.** Agora's faucet holds 640,000 AUSD
   and is not a minter — about sixty-four claims remain, and it held 670,000 two days
   ago. When it empties it stops. Take the demo's collateral early rather than on the
   13th of October. There is no per-address lockout, so one address can be stacked to
   the 100,000 AUSD ceiling in ten calls, sixty seconds apart. And `requestFunds` pays
   its **argument**, not the caller, so a funded wallet can fill a phone's address
   without that phone holding any MON.

3. **Run the PRF probe on a real device.** The probe screen exists in Recourse. Confirm
   the derived address matches what Mera's library produces in a browser at the same
   relying party. The native path is proven at the API level — exact Swift symbols, and
   WebKit itself reads PRF the same way — so this is verification rather than discovery,
   but it is cheap and it closes the argument.

**Settled 14 September: `desk-trading-opia.vercel.app`.** A Vercel
subdomain rather than a bought domain, because the decision was blocking everything and
on testnet the permanence costs a re-enrolment rather than money. Buy a domain before any
real launch; until then this is the relying party and it does not change again.

The original question, kept for the reasoning: **what is Desk's relying party?** Passkeys bind to
it permanently, an associated-domains file must be served from it with no redirect, and
the acceptance test compares against Mera's library at the same domain. Borrowing
Recourse's domain is the cheap answer; a Desk domain is the honest one. Decide before
the first passkey is created, because afterwards it is not a decision.

## The phases

| Dates | Days | What ships |
|---|---|---|
| **12–14 Sept** | 3 | **Foundation.** Repo, project generation, iOS 18.4 target. Derivation verified on a real device against Mera. `Core/Money` with the scaling tests, including a market where the decimals do not sum to six. `PerplCanonical` and `PerplREST` with vectors pinned from the Node script. A funded testnet account, and real authenticated socket traffic captured from it |
| **15–18 Sept** | 4 | **Sign in and Fund.** The ceremony, create and assert, with the create-time fallback and the address guard. The guided testnet funding sequence. The four-step opening sequence with resume. Enrolment. **One real order sent from the phone** |
| **19–23 Sept** | 5 | **Market and Position.** Live price with the four freshness states. Depth-lite. The ticket, with liquidation distance, fee and price impact above the confirm. The position card, PnL-first, with field-level staleness. Close, whole and partial |
| **24–28 Sept** | 5 | **Account and polish.** Withdraw. The session screen with a countdown that actually zeroes the key. The second-device demo. The design pass, against the tokens in `03-screen-designs.md`. Accessibility: grayscale test per screen, Dynamic Type reflow, VoiceOver on the price |
| **29 Sept – 5 Oct** | 7 | **The stretch, or the buffer.** The treasury signer, if Olien on Monad is far enough along. Otherwise: internal TestFlight build, the live-test suite, and the bugs the first four weeks deferred |
| **6–12 Oct** | 7 | **Record and write up.** A working run recorded as soon as one exists, then re-recorded only if there is time. The write-up, including the native-versus-Mera address comparison. Submit |
| **13–14 Oct** | 2 | **Buffer.** Deliberately empty. The deadline is 04:59 GMT+1 on the 14th, which is the middle of the night, so nothing may depend on the 13th |

**Record the demo the moment a working run exists** — from the 18th, not from October.
Perpl's testnet being unstable near the deadline is the one risk with no mitigation
other than having recorded earlier.

## What "finished" means per phase

Each phase ends on a demonstrable fact, not a feeling.

- **Foundation.** A test suite that passes offline, plus captured frames on disk for
  every authenticated message type the app will read.
- **Sign in and Fund.** A stranger's phone goes from a cold install to an open desk and
  one filled order without being told anything.
- **Market and Position.** The numbers agree with Perpl's own interface to the decimal,
  and a dropped socket reconnects and re-signs without the user touching anything.
- **Account.** A withdrawal reaches the derived address on Monad, the collateral figure
  drops by the right amount, and ending the session forces Face ID on the next order.
- **Stretch or buffer.** A TestFlight build installed on a second physical device.
- **Record.** A video that needs no explanation and a repo whose tests a judge can run.

## The cut line

In the order things get cut, decided now so it is not argued at 2am on 12 October.

1. **The treasury stretch.** First to go, and the decision is made on 1 October against
   the state of Olien on Monad, not later.
2. **The withdraw screen**, which becomes a contract call demonstrated from a script in
   the video rather than a screen in the app.
3. **The depth view**, leaving the price and the ticket.
4. **Limit orders**, leaving market only.

**Market, Position and Fund ship no matter what.** An app that cannot open a desk and
place an order is not an entry.

Below the cut line permanently, so they cannot creep back: multiple markets, order
history, notifications, TP/SL, an Android or web build, a relayer.

## Risks

| Risk | What happens | What we do |
|---|---|---|
| ~~Apple Developer account is individual, not org~~ | Closed 13 September | It is individual, and internal TestFlight has no review step, so 5.1.1(ix) does not apply on this path. Re-enrolling as an organisation is a post-bounty task and must not be started inside the thirty-two days |
| ~~Apple Developer membership is not paid~~ | Closed 13 September | Paid membership confirmed. Associated Domains is available and the ceremony is unblocked |
| ~~The relying party is still not chosen~~ | Closed 14 September | `desk-trading-opia.vercel.app`, live and verified. The prior domain belonged to an inaccessible Vercel account and could not be kept in sync with the signed application. |
| ~~iOS returns no PRF output~~ | Closed 12 September | Native PRF confirmed from iOS 18.0 against the SDK headers. Ship-gated at **18.4**, because 18.0 to 18.3 return wrong values |
| Synced passkey returns different PRF on a second device | The recovery demo fails, and a real user sees a funded account as empty | Open Apple bug, no fix. Mitigations: the address guard, both demo devices on iOS 26, and the recovery claim stated honestly rather than absolutely |
| ~~No testnet AUSD~~ | Closed 11 September | Agora's faucet. But see the next row |
| Agora's faucet empties | No collateral, no demo | 640,000 left and falling, about sixty-four claims. Claim early, and stack an address to the 100,000 ceiling while it lasts. The sixty-second cooldown is **global**, so contention is expected on demo day |
| Monad testnet resets again | The account, the position and the recording's chain history all vanish | It was reset from genesis on 16 December 2025. Re-runnable setup, and a recording made early |
| Perpl testnet unstable near the deadline | The recording cannot be made | Record from the 18th onward, re-record only if there is time |
| Perpl changes its API mid-build | The client breaks | Every message shape pinned to a test against a captured frame |
| The calendar collides with Olien on Monad | Both entries suffer | Neither wins automatically now that they run in parallel; collisions are decided on the day against this cut line |
| App Store rejection | Irrelevant for the bounty, fatal for anything after | Guideline 3.1.5(iv) names cryptocurrency futures trading and requires a bank, securities firm or FCM. **Internal TestFlight, 100 testers, has no review step.** That is the path. External TestFlight is a real guideline review and must stay off the critical path |

## Two things to remember about TestFlight

**Builds expire after ninety days**, so upload fresh before demo day rather than relying
on a build from September. And every internal tester must be added to the App Store
Connect team with a role — there is no link-sharing for the internal track.

Nothing in the bounty brief requires App Store distribution. The deliverable is a
working demo of passkey login, an AUSD balance, and at least one trade; a video plus an
internal TestFlight build satisfies that completely.


## The relying party, and how to settle it

Written 13 September, because this is the one decision with no second chance.

Every passkey is scoped to the relying party identifier. Changing it after a single
person has enrolled orphans their credential and the address derived from it — there is
no migration and no recovery. So it is chosen once, before the first passkey exists.

`RelyingParty` in `DeskAuth` refuses the shapes that fail on a device rather than at
build time: a scheme, a path, a port, a bare label, a trailing dot, an underscore, a
non-punycoded domain. It also derives the `webcredentials:` entitlement value and the
association file URL from the same string, so the entitlement and the ceremony cannot
drift apart — a mismatch there only shows up on hardware.

What cannot be checked in a test is whether the domain actually serves its association
file the way Apple demands, so `tools/check-relying-party.sh <domain>` does that:

```
tools/check-relying-party.sh desk.trade
```

The requirement that catches people is **no redirect**. Apple fetches
`https://<domain>/.well-known/apple-app-site-association` directly and will not follow a
redirect, while a browser follows it silently — so the file looks perfectly fine when you
check it by hand. `apple.com` itself fails this, answering 301 to `www.apple.com`; the
script reports it, along with the status, the JSON, and whether
`webcredentials.apps` lists a `TEAMID.bundle.id` entry. Verified against real passkey
deployments in both directions on 13 September.

Run it against the candidate domain before anything else, because the answer changes
which domain to buy.
