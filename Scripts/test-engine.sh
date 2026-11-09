#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
cmake -S Butter/Engine -B .dependencies/bridge-build -DBUTTER_ENGINE_TESTS=ON
cmake --build .dependencies/bridge-build --parallel 4
.dependencies/bridge-build/EngineTests
