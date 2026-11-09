#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/butter-storage-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -module-cache-path /tmp/butter-swift-cache Butter/Core/*.swift Tests/StorageCrashTests.swift -o "$work/StorageCrashTests"
"$work/StorageCrashTests"
