#!/usr/bin/env bash
# check-ini.sh -- hard gate against MPC device-loader regressions in the .ini.
#
# The loader refuses scripts SILENTLY (no log, no load) on ini shapes it does
# not like. Known silent refusals (seen on 3.10.1 with the launchpad script):
#   - scriptVersion=1.2.0 (semver)      -> silent skip
#   - scriptVersion=1.2 (unknown minor) -> silent skip on later OS states
#   - comment lines / unknown keys      -> parser-dependent, never proven safe
#
# Comma-separated candidate port lists ARE allowed: Akai's own shipped scripts
# use them (mpkMiniMkIV.ini on 3.10.x: input=MPK mini IV DAW Port,MIDIIN2 (MPK mini IV)),
# device-observed on the target MPC. Each candidate must be a non-empty name.
# This gate makes those loud before they reach hardware.
#
# Usage:
#   tools/check-ini.sh script/LaunchControlXL3.ini.in template
#   tools/check-ini.sh build/LaunchControlXL3.ini   artifact
#
# Exit status: 0 = ok, 1 = regression found (message on stderr).
set -uo pipefail

# Script versions the loader is KNOWN to accept, device-verified via the
# launchpad project on the same firmware. Akai's own reference scripts ship 1.0.
# Bumping this list requires hardware verification FIRST (install, reboot, check
# the journal for "<device>: loaded"). Update CONTRIBUTING.md in the same commit.
ALLOWED_SCRIPT_VERSIONS="1.0"

fail=0
err() { echo "check-ini: FAIL: $*" >&2; fail=1; }

check_ini() {
    local ini="$1" mode="$2"
    local section="" have_info=0
    local device="" manufacturer="" script="" scriptversion=""
    local input="" output="" checksum=""
    local n_input=0 n_output=0 lineno=0 line

    [ -f "$ini" ] || { err "$ini: file not found"; return; }

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        if [ -z "${line//[[:space:]]/}" ]; then
            continue
        fi
        case "$line" in
            ';'*|'#'*)
                err "$ini:$lineno: comment lines not allowed (device parsers are naive; Akai's reference has none): $line"
                continue
                ;;
            \[*\])
                if [ "$line" = "[info]" ]; then
                    have_info=1
                    section="info"
                else
                    section="${line#[}"; section="${section%]}"
                    err "$ini:$lineno: unexpected section $line (only [info] is read)"
                fi
                continue
                ;;
        esac
        case "$line" in
            *=*) ;;
            *)
                err "$ini:$lineno: not a key=value line: $line"
                continue
                ;;
        esac
        local key="${line%%=*}" val="${line#*=}"
        key="${key//[[:space:]]/}"
        if [ "$section" != "info" ]; then
            err "$ini:$lineno: key outside [info]: $key"
            continue
        fi
        case "$key" in
            device)        device="$val" ;;
            manufacturer)  manufacturer="$val" ;;
            script)        script="$val" ;;
            scriptVersion) scriptversion="$val" ;;
            input)         n_input=$((n_input + 1)); input="$val" ;;
            output)        n_output=$((n_output + 1)); output="$val" ;;
            checksum)      checksum="$val" ;;
            *)             err "$ini:$lineno: unknown key '$key'" ;;
        esac
    done < "$ini"

    [ "$have_info" -eq 1 ] || err "$ini: missing [info] section"
    [ "$line" = "" ] || true

    [ -n "$device" ]       || err "$ini: missing device="
    [ -n "$manufacturer" ] || err "$ini: missing manufacturer="
    [ -n "$script" ]       || err "$ini: missing script="

    if [ -z "$scriptversion" ]; then
        err "$ini: missing scriptVersion="
    else
        case "$scriptversion" in
            [0-9]*.[0-9]*) ;;
            *) err "$ini: scriptVersion='$scriptversion' is not single-dot MAJOR.MINOR (semver like 1.2.0 is silently refused by the loader)" ;;
        esac
        local ok=0 v
        for v in $ALLOWED_SCRIPT_VERSIONS; do
            [ "$scriptversion" = "$v" ] && ok=1
        done
        [ "$ok" -eq 1 ] || err "$ini: scriptVersion='$scriptversion' is not device-verified. Loader-silent refusals have shipped before. Allowed: $ALLOWED_SCRIPT_VERSIONS (see tools/check-ini.sh)"
    fi

    [ "$n_input" -eq 1 ]  || err "$ini: expected exactly 1 input= line, found $n_input"
    [ "$n_output" -eq 1 ] || err "$ini: expected exactly 1 output= line, found $n_output"
    # port lines: comma-separated candidate lists are allowed (factory scripts
    # ship them); every candidate must be non-empty.
    for var in input output; do
        eval "val=\$$var"
        [ -n "$val" ] || continue
        IFS=','
        for cand in $val; do
            [ -n "${cand//[[:space:]]/}" ] || err "$ini: $var= has an empty candidate in '$val'"
        done
        unset IFS
    done
    [ -n "$input" ] && [ -n "$output" ] \
        || err "$ini: input= and output= are both required"

    if [ -n "$script" ]; then
        case "$script" in
            *.lua) ;;
            *) err "$ini: script= must name a .lua file" ;;
        esac
        [ -f "$(dirname "$ini")/$script" ] || err "$ini: script= target not found: $(dirname "$ini")/$script"
    fi

    if [ "$mode" = "artifact" ]; then
        case "$checksum" in
            PLACEHOLDER) err "$ini: artifact still has the PLACEHOLDER checksum (not signed)" ;;
        esac
    fi
    if [ "$checksum" != "PLACEHOLDER" ] && [ -n "$checksum" ]; then
        if [ "${#checksum}" -ne 64 ]; then
            err "$ini: checksum= must be 64 hex digits (got ${#checksum}: ${checksum:0:20}...)"
        fi
        case "$checksum" in
            *[!0-9a-f]*|"") err "$ini: checksum= must be lowercase hex only: ${checksum:0:20}" ;;
        esac
    fi
}

mode="${2:-template}"
check_ini "${1:?usage: check-ini.sh <ini> [template|artifact]}" "$mode"
if [ "$fail" -ne 0 ]; then
    echo "check-ini: REGRESSION BLOCKED (loader would silently refuse this script)" >&2
    exit 1
fi
echo "check-ini: OK ($1)"
exit 0
