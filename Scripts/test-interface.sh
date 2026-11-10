#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bin=$(Scripts/build-native.sh)
work=$(mktemp -d /tmp/butter-interface-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -module-cache-path /tmp/butter-swift-cache \
	Butter/Core/*.swift Butter/Engine/*.swift Butter/TransferStore.swift Butter/ContentView.swift Butter/UI/*.swift Tests/InterfaceTests.swift \
	-I "$bin" -L "$bin" -lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	-framework AppKit -framework SystemConfiguration -o "$work/InterfaceTests"
"$work/InterfaceTests" "$PWD/.build/InterfaceChecks"
