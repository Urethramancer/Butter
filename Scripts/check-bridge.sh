#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
archive=.dependencies/bridge-build/libButterEngine.a
stamp=.dependencies/bridge-build/verified
for input in Butter/Engine/ButterEngine.mm Butter/Engine/ButterEngine.h Butter/Engine/CMakeLists.txt Scripts/build-bridge.sh Scripts/bootstrap-engine.sh .dependencies/install/lib/libtorrent-rasterbar.a .dependencies/install/lib/libssl.a .dependencies/install/lib/libcrypto.a; do
	if [ ! -f "$archive" ] || [ ! -f "$stamp" ] || [ "$input" -nt "$stamp" ]; then
		echo 'error: Embedded engine is missing or stale. Run Scripts/bootstrap-engine.sh and Scripts/build-bridge.sh, then build again.' >&2
		exit 1
	fi
done
if ! shasum -a 256 -c .dependencies/bridge-build/verified-inputs.sha256 >/dev/null 2>&1; then
	echo 'error: Embedded engine inputs changed. Run Scripts/build-bridge.sh before building the app.' >&2
	exit 1
fi
[ -z "${SCRIPT_OUTPUT_FILE_0:-}" ] || touch "$SCRIPT_OUTPUT_FILE_0"
