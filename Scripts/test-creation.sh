#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
	''|--reference) ;;
	*) echo 'Usage: Scripts/test-creation.sh [--reference]' >&2; exit 2 ;;
esac
bin=$(Scripts/build-native.sh)
work=$(mktemp -d /tmp/butter-creation-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -module-cache-path /tmp/butter-swift-cache \
	Butter/Core/*.swift Butter/Engine/*.swift Tests/CreationComparisonTests.swift \
	-I "$bin" -L "$bin" -lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	-framework AppKit -framework SystemConfiguration -o "$work/CreationComparisonTests"
"$work/CreationComparisonTests" "$work"
if [ "${1:-}" = --reference ]; then
	Scripts/build-bridge.sh
	cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON
	cmake --build .dependencies/reference-build --target CreationReference --parallel 4
	.dependencies/reference-build/CreationReference "$work"
fi
