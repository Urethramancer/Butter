#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
archive=.dependencies/bridge-build/libButterEngine.a
stamp=.dependencies/bridge-build/verified
for input in Butter/Engine/ButterEngine.mm Butter/Engine/ButterEngine.h Butter/Engine/CMakeLists.txt Scripts/build-bridge.sh; do
	if [ ! -f "$archive" ] || [ ! -f "$stamp" ] || [ "$input" -nt "$stamp" ]; then
		echo 'error: Embedded engine is missing or stale. Run Scripts/bootstrap-engine.sh and Scripts/build-bridge.sh, then build again.' >&2
		exit 1
	fi
done
[ -z "${SCRIPT_OUTPUT_FILE_0:-}" ] || touch "$SCRIPT_OUTPUT_FILE_0"
