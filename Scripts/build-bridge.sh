#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$PWD/.dependencies
[ -f "$root/install/lib/libtorrent-rasterbar.a" ] || { echo 'Run Scripts/bootstrap-engine.sh first.' >&2; exit 1; }
cmake -S Butter/Engine -B "$root/bridge-build" \
	-DBUTTER_ENGINE_TESTS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_PREFIX_PATH="$root/install" -DOPENSSL_ROOT_DIR="$root/install" \
	-DBoost_INCLUDE_DIR="$root/src/boost_1_88_0" -DCMAKE_POLICY_DEFAULT_CMP0167=OLD
cmake --build "$root/bridge-build" --parallel 4
touch "$root/bridge-build/verified"
