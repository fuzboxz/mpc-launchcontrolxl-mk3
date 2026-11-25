#!/usr/bin/env bash
# check-docs.sh -- hard gate that keeps the reference docs in step with the script.
#
# MANUAL.md is generated from the ACTIONS table, so gen-manual --check already
# catches drift there. Everything else is prose, and prose rots silently: the
# Q-Link knob order shipped wrong for two releases because docs/MAPPING.md was
# never re-checked against QLINK_ORDER. This gate makes that loud.
#
# Checks:
#   1. docs/MANUAL.md is fresh (delegates to tools/gen-manual.sh --check).
#   2. The Q-Link knob-order rows in the script appear verbatim in docs/MAPPING.md
#      (both the track/plugin table and the global identity claim).
#   3. Every __LCXL3_* tunable/flag in the script is documented somewhere in docs/.
#   4. Every field of the __LCXL3_QFEEL table is documented in docs/MAPPING.md.
#
# Usage: tools/check-docs.sh
# Exit status: 0 = ok, 1 = stale docs (each finding on stderr).
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT=script/LaunchControlXL3.lua
MAPPING=docs/MAPPING.md
fail=0
err() { echo "check-docs: FAIL: $*" >&2; fail=1; }

[ -f "$SCRIPT" ] || { echo "check-docs: error: $SCRIPT not found" >&2; exit 1; }
[ -f "$MAPPING" ] || { echo "check-docs: error: $MAPPING not found" >&2; exit 1; }

# 1. generated manual ---------------------------------------------------------
if ! tools/gen-manual.sh --check >/dev/null 2>&1; then
	err "docs/MANUAL.md is stale — run tools/gen-manual.sh"
fi

# 2. Q-Link knob order --------------------------------------------------------
order="$(grep -m1 '^local QLINK_ORDER = {' "$SCRIPT" | sed 's/.*{\([^}]*\)}.*/\1/' | tr -d ' ')"
if [ -z "$order" ]; then
	err "could not read QLINK_ORDER from $SCRIPT"
else
	row1="$(printf '%s' "$order" | cut -d, -f1-8)"
	row2="$(printf '%s' "$order" | cut -d, -f9-16)"
	count="$(printf '%s' "$order" | tr ',' '\n' | grep -c .)"
	if [ "$count" != "16" ]; then
		err "QLINK_ORDER has $count entries, expected 16"
	fi
	grep -qF "{$row1}" "$MAPPING" || err "$MAPPING does not quote the track row 1 order {$row1}"
	grep -qF "{$row2}" "$MAPPING" || err "$MAPPING does not quote the track row 2 order {$row2}"
	# the global page is identity; the doc must say so next to the order tables
	grep -q 'Global / main page' "$MAPPING" || err "$MAPPING does not document the global (identity) Q-Link order"
	grep -q 'identity' "$MAPPING" || err "$MAPPING does not mention the identity order"
fi

# 3. every tunable/flag is documented ----------------------------------------
missing=""
for name in $(grep -oE '__LCXL3_[A-Z0-9_]+' "$SCRIPT" | sort -u); do
	if ! grep -rqF "$name" docs/*.md; then
		missing="$missing $name"
	fi
done
if [ -n "$missing" ]; then
	err "undocumented flag(s) in docs/:$missing"
fi

# 4. QFEEL fields -------------------------------------------------------------
qfeel="$(grep -oE '^__LCXL3_QFEEL\.[a-zA-Z]+' "$SCRIPT" | sed 's/.*\.//' | sort -u)"
for field in $qfeel; do
	grep -qF "$field" "$MAPPING" || err "__LCXL3_QFEEL.$field is not documented in $MAPPING"
done

if [ "$fail" -ne 0 ]; then
	echo "check-docs: documentation must be updated in the same commit as the change" >&2
	exit 1
fi
echo "check-docs: OK (manual fresh, Q-Link order + flags documented)"
