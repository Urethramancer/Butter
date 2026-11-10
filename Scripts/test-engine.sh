#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON
cmake --build .dependencies/reference-build --parallel 4
.dependencies/reference-build/EngineTests
