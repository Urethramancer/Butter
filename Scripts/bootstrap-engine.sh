#!/bin/sh
# Apple Silicon, macOS 26. Sources and products stay inside .dependencies.
set -eu
cd "$(dirname "$0")/.."
root=$PWD/.dependencies
mkdir -p "$root/downloads" "$root/src" "$root/install" Butter/Licences
fetch() {
	file=$1 url=$2 checksum=$3
	[ -f "$root/downloads/$file" ] || curl --fail --location --retry 3 "$url" -o "$root/downloads/$file"
	printf '%s  %s\n' "$checksum" "$root/downloads/$file" | shasum -a 256 -c -
}
# libtorrent revision 6da363d2994f17c0b3c0450d124cf73a31a73847 (v2.1.2).
fetch libtorrent.tar.gz https://codeload.github.com/arvidn/libtorrent/tar.gz/6da363d d2715db6228c42dca7072983f0ea78646f84cee8ad1eeb1f3bf6d15b11212145
fetch try_signal.tar.gz https://codeload.github.com/arvidn/try_signal/tar.gz/105cce59972f925a33aa6b1c3109e4cd3caf583d 6f111b0d77429a8051be4faed06cf23fb03cf6ee233967c84fdd9d8d3b42ba8e
fetch boost.tar.bz2 https://archives.boost.io/release/1.88.0/source/boost_1_88_0.tar.bz2 46d9d2c06637b219270877c9e16155cbd015b6dc84349af064c088e9b5b12f7b
fetch openssl.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.4/openssl-3.5.4.tar.gz 967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99
[ -f "$root/src/libtorrent-6da363d/CMakeLists.txt" ] || tar -xzf "$root/downloads/libtorrent.tar.gz" -C "$root/src"
[ -f "$root/src/boost_1_88_0/boost/version.hpp" ] || tar -xjf "$root/downloads/boost.tar.bz2" -C "$root/src"
[ -f "$root/src/openssl-3.5.4/Configure" ] || tar -xzf "$root/downloads/openssl.tar.gz" -C "$root/src"
[ -f "$root/src/libtorrent-6da363d/deps/try_signal/try_signal.cpp" ] || tar -xzf "$root/downloads/try_signal.tar.gz" -C "$root/src/libtorrent-6da363d/deps/try_signal" --strip-components=1
jobs=${BUTTER_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}
if [ ! -f "$root/install/lib/libssl.a" ]; then
	mkdir -p "$root/openssl-build"
	(cd "$root/openssl-build"; "$root/src/openssl-3.5.4/Configure" darwin64-arm64-cc no-shared no-tests no-module --prefix="$root/install" --libdir=lib -mmacosx-version-min=26.0; make -j "$jobs"; make install_sw)
fi
cmake -S "$root/src/libtorrent-6da363d" -B "$root/engine-build" \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
	-DCMAKE_CXX_FLAGS="-include iterator" \
	-DCMAKE_INSTALL_PREFIX="$root/install" -DBUILD_SHARED_LIBS=OFF -Dwebtorrent=OFF \
	-DOPENSSL_ROOT_DIR="$root/install" -DOPENSSL_USE_STATIC_LIBS=ON \
	-DBoost_INCLUDE_DIR="$root/src/boost_1_88_0" -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=OFF \
	-DCMAKE_POLICY_DEFAULT_CMP0167=OLD
cmake --build "$root/engine-build" --parallel "$jobs"
cmake --install "$root/engine-build"
cp "$root/src/libtorrent-6da363d/LICENSE" Butter/Licences/libtorrent.txt
cp "$root/src/boost_1_88_0/LICENSE_1_0.txt" Butter/Licences/Boost.txt
cp "$root/src/openssl-3.5.4/LICENSE.txt" Butter/Licences/OpenSSL.txt
cp "$root/src/libtorrent-6da363d/deps/try_signal/LICENSE" Butter/Licences/try_signal.txt
