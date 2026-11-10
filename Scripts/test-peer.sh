#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Each fixture owns its own concurrency; independent worlds share the process-wide disk budget.
swift test --no-parallel --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent --filter ButterTorrentEngineTests "$@"
