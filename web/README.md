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

Deployment Protection must stay off. With it on, Vercel answers 302 to an SSO page, and
that is the redirect Apple refuses to follow while a browser follows it silently.

Verify with `tools/check-relying-party.sh` before creating the first passkey — with no
arguments it also compares the two copies of the domain in the repository. Every passkey
binds to this domain permanently.
