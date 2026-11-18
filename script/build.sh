#!/bin/sh
# Build the deployable controller script into build/:
#   build/LaunchControlXL3.lua — minified artifact (comments/indentation stripped)
#   build/LaunchControlXL3.ini — signed ini; its checksum covers the artifact
# The checksum is sha256(lua_bytes || salt); the salt is read from the owner's own
# MPC binary at run time. Set MPC_BIN to your own MPC binary (see CONTRIBUTING.md).
#
# PHASE-0 WARNING: the input=/output= port names in LaunchControlXL3.ini.in are a
# best guess for the DAW USB interface as MPC/ALSA names it. Verify against
# `aconnect -l` on the device BEFORE shipping (docs/INSTALL.md, step 3).
set -eu
cd "$(dirname "$0")"
: "${MPC_BIN:?set MPC_BIN to your own MPC binary (see CONTRIBUTING.md)}"
mkdir -p ../build
../tools/minify-lua.sh LaunchControlXL3.lua > ../build/LaunchControlXL3.lua
if command -v luac5.4 >/dev/null 2>&1; then
	luac5.4 -p ../build/LaunchControlXL3.lua
else
	echo "build.sh: warning: luac5.4 not found; skipped the syntax check" >&2
fi
cp LaunchControlXL3.ini.in ../build/LaunchControlXL3.ini
python3 ../tools/sign_script.py "$MPC_BIN" ../build/LaunchControlXL3.lua ../build/LaunchControlXL3.ini >/dev/null
../tools/check-ini.sh LaunchControlXL3.ini.in template
../tools/check-ini.sh ../build/LaunchControlXL3.ini artifact
wc -c ../build/LaunchControlXL3.lua LaunchControlXL3.lua | sed '$d'
grep '^checksum=' ../build/LaunchControlXL3.ini
