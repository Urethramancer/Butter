#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON
cmake --build .dependencies/reference-build --target MetadataReference --parallel 4
bin=$(Scripts/build-native.sh)
work=$(mktemp -d /tmp/butter-metadata-reference.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
.dependencies/reference-build/MetadataReference "$work"
swiftc -module-cache-path /tmp/butter-swift-cache -import-objc-header Tests/Reference/ButterEngine.h \
	Butter/Core/*.swift Butter/Engine/*.swift Tests/Reference/ReferenceEngineClient.swift Tests/MetadataComparisonTests.swift \
	-I "$bin" -L "$bin" -lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	-L .dependencies/reference-build -L .dependencies/install/lib -lButterEngine -ltorrent-rasterbar -lssl -lcrypto -lc++ \
	-framework AppKit -framework SystemConfiguration -o "$work/MetadataComparisonTests"
"$work/MetadataComparisonTests" "$work"
