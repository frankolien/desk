# The relying party

This exists for one file: `/.well-known/apple-app-site-association`.

Apple fetches it directly and **will not follow a redirect**, while a browser follows
one silently — so a file that looks correct when checked by hand can still fail on
device. `vercel.json` pins the content type and switches off `cleanUrls` and
`trailingSlash`, both of which introduce redirects.

The `apps` entry is `TEAMID.bundleid`. Changing either side of that string breaks the
association, and the app's `webcredentials:` entitlement must name this exact domain.

Verify with `tools/check-relying-party.sh <domain>` before creating the first passkey.
Every passkey binds to this domain permanently.
