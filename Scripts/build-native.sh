#!/bin/sh
# Emit only the path for headless app-level drivers that import the Swift package.
set -eu
cd "$(dirname "$0")/.."
swift build --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent >&2
swift build --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent --show-bin-path
