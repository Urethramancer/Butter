#!/bin/sh
# A disposable image exercises actual ENOSPC without filling the user's disk.
set -eu
cd "$(dirname "$0")/.."
engine=${BUTTER_ENGINE_DISK_BINARY:-$PWD/.dependencies/bridge-build/EngineDiskFailureTests}
if [ -z "${BUTTER_ENGINE_DISK_BINARY:-}" ]; then
	Scripts/build-bridge.sh
	cmake -S Butter/Engine -B .dependencies/bridge-build -DBUTTER_ENGINE_TESTS=ON
	cmake --build .dependencies/bridge-build --target EngineDiskFailureTests --parallel 4
fi
work=$(mktemp -d /tmp/butter-disk-tests.XXXXXX)
mounted=false
cleanup() {
	if [ "$mounted" = true ]; then
		hdiutil detach "$work/mount" >/dev/null || { echo "Could not detach disposable test image at $work/mount" >&2; exit 1; }
	fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
binary=${BUTTER_DISK_TEST_BINARY:-$work/DiskFailureTests}
if [ -z "${BUTTER_DISK_TEST_BINARY:-}" ]; then
	swiftc -module-cache-path /tmp/butter-swift-cache Butter/Core/*.swift Tests/DiskFailureTests.swift -o "$binary"
fi
hdiutil create -size 16m -fs HFS+ -volname ButterAudit -type UDIF -nospotlight "$work/fixture.dmg" >/dev/null
mkdir "$work/mount" "$work/source"
hdiutil attach "$work/fixture.dmg" -mountpoint "$work/mount" -nobrowse >/dev/null
mounted=true
touch "$work/mount/.butter-disk-test"
"$binary" "$work/mount"
"$engine" "$work/mount" "$work/source"
hdiutil detach "$work/mount" >/dev/null
mounted=false
hdiutil attach "$work/fixture.dmg" -mountpoint "$work/mount" -nobrowse -readonly >/dev/null
mounted=true
"$binary" "$work/mount" --read-only
"$engine" "$work/mount" "$work/source" --read-only
hdiutil detach "$work/mount" >/dev/null
mounted=false
hdiutil attach "$work/fixture.dmg" -mountpoint "$work/mount" -nobrowse >/dev/null
mounted=true
"$engine" "$work/mount" "$work/source" --cleanup
