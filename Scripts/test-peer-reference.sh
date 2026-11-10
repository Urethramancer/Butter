#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/test-peer.sh
Scripts/build-bridge.sh
cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON
cmake --build .dependencies/reference-build --target TCPPeerReference --parallel 4
bin=$(swift build --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent --show-bin-path)
work=$(mktemp -d /tmp/butter-tcp-reference.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -swift-version 6 -parse-as-library -module-cache-path /tmp/butter-swift-cache -I "$bin" -L "$bin" \
	-lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	Tests/TCPTransferComparisonTests.swift Tests/HybridIdentityComparisonTests.swift Tests/SessionLocalDiscoveryComparisonTests.swift Tests/SessionPeerComparisonTests.swift Tests/SessionTrackerComparisonTests.swift Tests/SessionDHTComparisonTests.swift Tests/SessionHintComparisonTests.swift Tests/SessionWebSeedComparisonTests.swift Packages/ButterTorrent/Tests/ButterTorrentNetworkingTests/HTTPTestSupport.swift Tests/TCPFragmentingRelay.swift Tests/UTPImpairingRelay.swift Tests/DHTComparisonTests.swift -o "$work/TCPTransferComparisonTests"
.dependencies/reference-build/TCPPeerReference --create "$work"
"$work/TCPTransferComparisonTests" "$work" "$PWD/.dependencies/reference-build/TCPPeerReference"
