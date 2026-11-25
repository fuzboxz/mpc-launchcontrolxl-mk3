#!/bin/sh
# Run the host-side tests: Lua syntax, ini gate, generated-manual freshness,
# the mock harness, and the same suite against the minified artifact.
set -eu
cd "$(dirname "$0")/.."

echo "== luac -p =="
luac5.4 -p script/LaunchControlXL3.lua
echo "luac: OK"

echo "== check-ini (loader regression gate) =="
tools/check-ini.sh script/LaunchControlXL3.ini.in template

echo "== generated manual =="
tools/gen-manual.sh --check

echo "== check-docs (manual freshness + Q-Link order + documented flags) =="
tools/check-docs.sh

SELENE="${SELENE:-$(command -v selene || true)}"
if [ -n "$SELENE" ] && [ -x "$SELENE" ]; then
  echo "== selene =="
  "$SELENE" script/LaunchControlXL3.lua || true
fi

for t in tests/test-*.lua; do
  echo "== $t =="
  lua5.4 "$t"
done

# The shipped artifact is the minified Lua: the whole suite must pass on it too.
echo "== minified artifact (the deployed form) =="
MIN_ARTIFACT="$(mktemp)"
tools/minify-lua.sh script/LaunchControlXL3.lua > "$MIN_ARTIFACT"
luac5.4 -p "$MIN_ARTIFACT"
for t in tests/test-*.lua; do
  LCXL3_LUA="$MIN_ARTIFACT" lua5.4 "$t" >/dev/null
done
rm -f "$MIN_ARTIFACT"
echo "minified artifact: OK"

echo "ALL TESTS PASS"
