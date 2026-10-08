# The relying party

This exists for one file: `/.well-known/apple-app-site-association`.

Apple fetches it directly and **will not follow a redirect**, while a browser follows
one silently — so a file that looks correct when checked by hand can still fail on
device. `vercel.json` pins the content type and switches off `cleanUrls` and
`trailingSlash`, both of which introduce redirects.

The `apps` entry is `TEAMID.bundleid`. Changing either side of that string breaks the
association, and the app's `webcredentials:` entitlement must name this exact domain.

The domain is **desk-trading-opia.vercel.app**, a stable alias on the team's `web`
project. The earlier `desk-trading.vercel.app` deployment belongs to another Vercel
account and cannot be updated by this project.

The alias is **pinned to one deployment** and does not follow production: a bad deploy
cannot touch the relying party, and in return the alias has to be moved by hand whenever
something under `/.well-known` changes (it carries `apple-app-site-association` for the
app's passkeys and `webauthn`, the related-origins file that lets trydesk.trade use them).
After such a deploy:

```sh
vercel alias set <new deployment url> desk-trading-opia.vercel.app
tools/check-relying-party.sh      # must still PASS, same association file
```

`vercel inspect desk-trading-opia.vercel.app` says which deployment it resolves to.

Deployment Protection must stay off. With it on, Vercel answers 302 to an SSO page, and
that is the redirect Apple refuses to follow while a browser follows it silently.

Verify with `tools/check-relying-party.sh` before creating the first passkey — with no
arguments it also compares the two copies of the domain in the repository. Every passkey
binds to this domain permanently.

## Server-side market credentials

The functions under `api/` read credentials only from Vercel environment variables. Never
embed them in the iOS target or expose them through a public-prefixed variable.

- `OKX_API_KEY`, `OKX_SECRET_KEY`, and `OKX_PASSPHRASE` power discovery, market data,
  Solana quotes, and the primary spot-quote route.
- `ZEROX_API_KEY` enables the 0x Swap API v2 fallback for supported EVM chains.

`api/swap-quote` returns a `provider` field (`okx` or `0x`) so production failures can be
traced without exposing either credential.

## Testnet faucet

`api/faucet` sends a Desk wallet 0.1 test MON when it holds under 0.05, and claims
10,000 test AUSD from Agora's faucet on its behalf when it holds under 100. The paying
wallet's key is `FAUCET_PRIVATE_KEY`, set only in Vercel; it must never be a key that
holds anything on mainnet. `MONAD_TESTNET_RPC` optionally overrides the public RPC.

Create the key without it ever being printed or written to disk. Only the address is
shown, on stderr:

```sh
node -e "import('viem/accounts').then(({generatePrivateKey,privateKeyToAccount})=>{const k=generatePrivateKey();process.stdout.write(k);console.error('Faucet address:',privateKeyToAccount(k).address)})" \
  | vercel env add FAUCET_PRIVATE_KEY production
```

Then send testnet MON to that address and redeploy. Each funded wallet costs about 0.13
MON (the drip plus the AUSD claim's gas); the function keeps 0.05 back for gas and reports
`faucet-empty` below that, and the app falls back to Monad's own faucet.

## Browser alerts

Web push needs a VAPID key pair, set only in Vercel: `VAPID_PUBLIC_KEY` and
`VAPID_PRIVATE_KEY` (base64url, from `generateVapidKeys()` in `api/_webpush.mjs`) and
`VAPID_SUBJECT` (`https://trydesk.trade`). Generate the pair without the private half ever
being printed:

```sh
node -e "import('./api/_webpush.mjs').then(({generateVapidKeys})=>{const k=generateVapidKeys();require('fs').writeFileSync('/tmp/vapid-pub',k.publicKey,{mode:0o600});process.stdout.write(k.privateKey)})" \
  | vercel env add VAPID_PRIVATE_KEY production
vercel env add VAPID_PUBLIC_KEY production < /tmp/vapid-pub && rm /tmp/vapid-pub
printf 'https://trydesk.trade' | vercel env add VAPID_SUBJECT production
```

Browsers subscribe with the public key, so rotating the pair makes every browser
re-subscribe the next time it opens the app; nothing else breaks. Like the other
credentials the keys exist only in Production, so a preview deployment answers the key
route 503 and "Turn on alerts" says the server is not set up for it.

## Card and Apple Pay deposits

Deposits by card or Apple Pay go through Crossmint. `CROSSMINT_API_KEY` is the server-side key
(`sk_staging_…` or `sk_production_…`, scopes `orders.create` and `orders.read`); the environment
follows the key's prefix, so a staging key can only ever reach staging. `CROSSMINT_CLIENT_KEY` is
the matching client key (`ck_…`), public by design: the app hands it to Crossmint's sheet to
identify itself, and the server serves it from `GET /api/swap-quote?view=onramp`. In staging the
delivered token is test USDC on Base Sepolia, Crossmint's stand-in, and nothing reaches Monad; in
production it is AUSD on Monad, which Crossmint enables per customer. `CROSSMINT_TOKEN_LOCATOR`
overrides the token for either.

```sh
vercel env add CROSSMINT_API_KEY production      # paste the sk_ key when asked
vercel env add CROSSMINT_CLIENT_KEY production   # paste the ck_ key
```

The route: `GET` says what is set up, `POST { wallet, amount, email, currency? }` links the wallet
to a Crossmint user and opens an order, answering with a `clientSecret` scoped to that order, and
`GET ?orderId=` follows it to delivery. The app never sees the server key, and the server never
sees a card.
