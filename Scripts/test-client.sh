#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/butter-client-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -module-cache-path /tmp/butter-swift-cache Butter/Core/*.swift Tests/ClientTests.swift Tests/CoreRegressionTests.swift Tests/WatcherRaceTests.swift -o "$work/ClientTests"
"$work/ClientTests"
