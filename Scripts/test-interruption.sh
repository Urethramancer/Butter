#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary=${BUTTER_INTERRUPTION_BINARY:-$PWD/.dependencies/reference-build/InterruptionTests}
if [ -z "${BUTTER_INTERRUPTION_BINARY:-}" ]; then
	Scripts/build-bridge.sh
	cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON
	cmake --build .dependencies/reference-build --target InterruptionTests --parallel 4
fi
work=$(mktemp -d /tmp/butter-interruption-tests.XXXXXX)
mounted=false
cleanup() {
	if [ "$mounted" = true ]; then
		hdiutil detach "$work/mount" >/dev/null || { echo "Could not detach disposable image at $work/mount" >&2; exit 1; }
	fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
hdiutil create -size 128m -fs HFS+ -type UDIF -nospotlight -volname ButterInterruption "$work/fixture.dmg" >/dev/null
mkdir "$work/mount" "$work/source"
hdiutil attach "$work/fixture.dmg" -mountpoint "$work/mount" -nobrowse >/dev/null
mounted=true
touch "$work/mount/.butter-interruption-test"
"$binary" "$work/source" "$work/mount"
