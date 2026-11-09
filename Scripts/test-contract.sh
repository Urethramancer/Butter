#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
work=$(mktemp -d /tmp/butter-contract-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -module-cache-path /tmp/butter-swift-cache -import-objc-header Butter/Engine/ButterEngine.h \
	Butter/Core/*.swift Butter/Engine/EngineClient.swift Tests/EngineContractCases.swift Tests/EngineContractTests.swift \
	-L .dependencies/bridge-build -L .dependencies/install/lib -lButterEngine -ltorrent-rasterbar -lssl -lcrypto -lc++ \
	-framework AppKit -framework SystemConfiguration -o "$work/EngineContractTests"
"$work/EngineContractTests"
