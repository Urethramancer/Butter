#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
cmake -S Butter/Engine -B .dependencies/bridge-build -DBUTTER_ENGINE_TESTS=ON
cmake --build .dependencies/bridge-build --target CreationReference --parallel 4
work=$(mktemp -d /tmp/butter-creation-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -module-cache-path /tmp/butter-swift-cache -import-objc-header Butter/Engine/ButterEngine.h \
	Packages/ButterTorrent/Sources/ButterTorrentMetadata/*.swift Butter/Core/*.swift Butter/Engine/EngineClient.swift Tests/CreationComparisonTests.swift \
	-L .dependencies/bridge-build -L .dependencies/install/lib -lButterEngine -ltorrent-rasterbar -lssl -lcrypto -lc++ \
	-framework AppKit -framework SystemConfiguration -o "$work/CreationComparisonTests"
"$work/CreationComparisonTests" "$work"
.dependencies/bridge-build/CreationReference "$work"
