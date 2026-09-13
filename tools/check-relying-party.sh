#!/bin/bash
# Checks whether a domain can serve as Desk's passkey relying party.
#
# The relying party is permanent: every passkey is scoped to it, so changing it after
# anyone has enrolled orphans their credential and their derived address. Apple fetches
# the association file directly, over HTTPS, and will not follow a redirect — which is
# the requirement that fails quietly, because the file loads perfectly well in a browser.
#
# With no argument it reads the domain out of the repository and first checks the one
# thing no remote fetch can: that the Swift constant and the entitlement agree. They are
# two copies of one string — iOS cannot read its own entitlement at run time, and a custom
# INFOPLIST_KEY never reaches the built plist — so something has to compare them, and a
# mismatch is invisible until a device refuses to create a passkey.
#
#   tools/check-relying-party.sh              # the repo's own domain, both copies
#   tools/check-relying-party.sh desk.trade   # a candidate, before adopting it
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

domain="${1:-}"
if [[ -z "$domain" ]]; then
  swift_value=$(grep -oE 'relyingPartyIdentifier = "[^"]+"' "$root/App/Desk/DeskApp.swift" \
    | head -1 | sed -E 's/.*"([^"]+)"/\1/')
  # `?mode=developer` is a fetch instruction to the device, not part of the relying
  # party, so it is stripped before comparing and before checking the domain.
  entitlement_value=$(grep -oE 'webcredentials:[^ ]+' "$root/project.yml" \
    | head -1 | sed -E 's/webcredentials://' | sed -E 's/\?.*$//')

  if [[ -z "$swift_value" || -z "$entitlement_value" ]]; then
    echo "FAIL  no relying party set yet. The app cannot create a passkey." >&2
    exit 1
  fi
  if [[ "$swift_value" != "$entitlement_value" ]]; then
    echo "FAIL  the two copies disagree, and this fails only on hardware:" >&2
    echo "        DeskApp.swift   $swift_value" >&2
    echo "        entitlement     $entitlement_value" >&2
    exit 1
  fi
  echo "  ok    Swift constant and entitlement agree: $swift_value"
  domain="$swift_value"
fi
if [[ "$domain" == *"://"* || "$domain" == *"/"* ]]; then
  echo "FAIL  a relying party is a bare domain: no scheme, no path" >&2
  exit 1
fi

url="https://${domain}/.well-known/apple-app-site-association"
echo "checking ${url}"

# The trailing newline matters: without it `read` reports failure at EOF even though it
# read the line perfectly well.
summary=$(curl -sS -m 20 -o "/tmp/aasa.$$" -D "/tmp/aasa.hdr.$$" \
  -w '%{http_code} %{num_redirects} %{content_type} %{url_effective}\n' "$url" 2>/dev/null)
if [[ -z "$summary" ]]; then
  echo "FAIL  could not reach the host over HTTPS"
  rm -f "/tmp/aasa.$$" "/tmp/aasa.hdr.$$"
  exit 1
fi
read -r status redirects type effective <<<"$summary"

fail=0
note() { printf '  %-5s %s\n' "$1" "$2"; [[ "$1" == "FAIL" ]] && fail=1; return 0; }

# Redirects are the one that catches people out: the file loads fine in a browser,
# because a browser follows them, and Apple does not.
if [[ "$status" == "200" ]]; then
  note "ok" "HTTP $status, served directly"
elif [[ "$status" -ge 300 && "$status" -lt 400 ]]; then
  location=$(grep -i '^location:' "/tmp/aasa.hdr.$$" 2>/dev/null | head -1 | tr -d '\r' | cut -d' ' -f2-)
  note "FAIL" "HTTP $status redirect to ${location:-elsewhere} — Apple will not follow it"
else
  note "FAIL" "HTTP $status"
fi

if [[ "$redirects" != "0" ]]; then
  note "FAIL" "$redirects redirect(s), ending at $effective"
fi

# A JSON content type is conventional but not required; Apple accepts any as long as the
# body parses.
note "note" "content-type: ${type:-none}"

if python3 -c "import json,sys; json.load(open('/tmp/aasa.$$'))" 2>/dev/null; then
  note "ok" "body is valid JSON"
  apps=$(python3 - "/tmp/aasa.$$" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
creds = doc.get("webcredentials") or {}
print(",".join(creds.get("apps", [])) or "(none)")
PY
)
  if [[ "$apps" == "(none)" ]]; then
    note "FAIL" "no webcredentials.apps entries — passkeys need TEAMID.bundle.id listed"
  else
    note "ok" "webcredentials.apps: $apps"
  fi
else
  head -c 120 "/tmp/aasa.$$" | tr -d '\n' | sed 's/^/  FAIL  body is not JSON: /'
  echo
  fail=1
fi

rm -f "/tmp/aasa.$$" "/tmp/aasa.hdr.$$"
if [[ $fail -eq 0 ]]; then
  echo "PASS  ${domain} can serve as the relying party"
else
  echo "NOT READY  fix the FAIL lines above before creating the first passkey"
  exit 1
fi
