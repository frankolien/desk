#!/bin/sh
# Checks the plugin package against the portal's rules, then builds the ZIP that OpenAI's
# plugin portal takes (Plugins, Upload new or existing plugin): the plugin root's files at
# the archive root, nothing else.
set -eu
cd "$(dirname "$0")"
node check.mjs
mkdir -p dist
rm -f dist/desk-plugin.zip
zip -qrX dist/desk-plugin.zip plugin.json mcp.json skills assets -x '*/.*' '.*'
unzip -l dist/desk-plugin.zip
