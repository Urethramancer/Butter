#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$PWD/.dependencies
[ -f "$root/install/lib/libtorrent-rasterbar.a" ] || { echo 'Run Scripts/bootstrap-engine.sh first.' >&2; exit 1; }
cmake -S Tests/Reference -B "$root/reference-build" \
	-DCMAKE_CXX_COMPILER=/usr/bin/clang++ -DCMAKE_OBJCXX_COMPILER=/usr/bin/clang++ -DBoost_NO_BOOST_CMAKE=ON -DBUTTER_ENGINE_TESTS=OFF -DBUTTER_COVERAGE=OFF -DBUTTER_SANITIZER= -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_PREFIX_PATH="$root/install" -DOPENSSL_ROOT_DIR="$root/install" \
	-DBoost_INCLUDE_DIR="$root/src/boost_1_88_0" -DCMAKE_POLICY_DEFAULT_CMP0167=OLD
cmake --build "$root/reference-build" --parallel 4
