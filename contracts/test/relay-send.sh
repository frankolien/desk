#!/bin/sh
# Runs relay-send.mjs with the web app's node_modules (viem) on the path.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../../web" && node "$here/relay-send.mjs" "$@"
