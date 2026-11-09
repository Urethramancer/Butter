#!/bin/sh
# A disposable image exercises actual ENOSPC without filling the user's disk.
set -eu
cd "$(dirname "$0")/.."
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
mkdir "$work/mount"
hdiutil attach "$work/fixture.dmg" -mountpoint "$work/mount" -nobrowse >/dev/null
mounted=true
touch "$work/mount/.butter-disk-test"
"$binary" "$work/mount"
hdiutil detach "$work/mount" >/dev/null
mounted=false
hdiutil attach "$work/fixture.dmg" -mountpoint "$work/mount" -nobrowse -readonly >/dev/null
mounted=true
"$binary" "$work/mount" --read-only
