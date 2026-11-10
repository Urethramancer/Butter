#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
swift build --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent
bin=$(swift build --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent --show-bin-path)
work=$(mktemp -d /tmp/butter-contract-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -module-cache-path /tmp/butter-swift-cache -import-objc-header Butter/Engine/ButterEngine.h \
	Packages/ButterTorrent/Sources/ButterTorrentMetadata/*.swift Butter/Core/*.swift Butter/Engine/EngineClient.swift Butter/Engine/SwiftEngineClient.swift Tests/EngineContractCases.swift Tests/EngineContractTests.swift \
	-I "$bin" -L "$bin" -lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	-L .dependencies/bridge-build -L .dependencies/install/lib -lButterEngine -ltorrent-rasterbar -lssl -lcrypto -lc++ \
	-framework AppKit -framework SystemConfiguration -o "$work/EngineContractTests"
"$work/EngineContractTests"
