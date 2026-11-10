#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
	'') set -- ;;
	--system-trash) export BUTTER_TEST_SYSTEM_TRASH=1; set -- ;;
	--reference)
		Scripts/build-bridge.sh
		set -- -D BUTTER_REFERENCE_ENGINE -import-objc-header Tests/Reference/ButterEngine.h \
			Tests/Reference/ReferenceEngineClient.swift -L .dependencies/reference-build -L .dependencies/install/lib \
			-lButterEngine -ltorrent-rasterbar -lssl -lcrypto -lc++ ;;
	*) echo 'Usage: Scripts/test-contract.sh [--reference|--system-trash]' >&2; exit 2 ;;
esac
bin=$(Scripts/build-native.sh)
work=$(mktemp -d /tmp/butter-contract-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -module-cache-path /tmp/butter-swift-cache "$@" \
	Butter/Core/*.swift Butter/Engine/*.swift Tests/EngineContractCases.swift Tests/EngineContractTests.swift \
	Packages/ButterTorrent/Tests/ButterTorrentNetworkingTests/HTTPTestSupport.swift \
	-I "$bin" -L "$bin" -lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	-framework AppKit -framework SystemConfiguration -o "$work/EngineContractTests"
"$work/EngineContractTests"
