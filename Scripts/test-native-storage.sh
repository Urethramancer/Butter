#!/bin/sh
# Headless native storage, including real volume failures and killed child processes.
set -eu
cd "$(dirname "$0")/.."
swift test --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent --filter ButterTorrentStorageTests
bin=$(swift build --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent --show-bin-path)
work=$(mktemp -d /tmp/butter-native-storage.XXXXXX)
mounted=false
cleanup() {
	if [ "$mounted" = true ]; then
		hdiutil detach "$work/mount" >/dev/null || { echo "Could not detach disposable image at $work/mount" >&2; exit 1; }
	fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
swiftc -swift-version 6 -parse-as-library -module-cache-path /tmp/butter-swift-cache -I "$bin" -L "$bin" \
	-lButterTorrentStorage -lButterTorrentMetadata Tests/NativeStorageRecoveryTests.swift -o "$work/StorageRecoveryTests"
hdiutil create -size 16m -fs HFS+ -type UDIF -nospotlight -volname ButterNativeStorage "$work/fixture.dmg" >/dev/null
mkdir "$work/mount" "$work/cases"
hdiutil attach "$work/fixture.dmg" -mountpoint "$work/mount" -nobrowse >/dev/null
mounted=true
touch "$work/mount/.butter-native-storage-test"
"$work/StorageRecoveryTests" "$work/cases" "$work/mount"
# Recovery cases have already verified their copies; free the small volume for ENOSPC.
find "$work/mount" -mindepth 1 -maxdepth 1 -name 'target-*' -exec rm -rf {} +
"$work/StorageRecoveryTests" --disk "$work/cases" "$work/mount"
hdiutil detach "$work/mount" >/dev/null
mounted=false
hdiutil attach "$work/fixture.dmg" -mountpoint "$work/mount" -nobrowse -readonly >/dev/null
mounted=true
"$work/StorageRecoveryTests" --read-only "$work/mount"
