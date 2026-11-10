#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift test --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent --filter ButterTorrentNetworkingTests "$@"
