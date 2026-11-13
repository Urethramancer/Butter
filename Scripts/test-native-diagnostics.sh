#!/bin/sh
# Standalone diagnostic probe; does not alter the pinned acceptance target.
set -eu
cd "$(dirname "$0")/.."
out=${1:-$PWD/.build/native-diagnostics}
mkdir -p "$out"
[ ! -e "$out/results.jsonl" ] || { echo 'Use a fresh output directory.' >&2; exit 2; }
work=$(mktemp -d /tmp/butter-native-diagnostics.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
# The installed archive exposes Boost 1.92's execution_context ABI. Its cached
# Apple-build flags name 1.88; using those headers crashes this direct API probe.
# Match the installed ABI here without rebuilding the reference library.
/opt/homebrew/opt/llvm/bin/clang++ -O3 -DNDEBUG -std=c++17 -arch arm64 \
	-DBOOST_ASIO_NO_DEPRECATED -DBOOST_SYSTEM_USE_UTF8 -DTORRENT_ABI_VERSION=2 -DTORRENT_SSL_PEERS \
	-DTORRENT_USE_LIBCRYPTO -DTORRENT_USE_OPENSSL -DTORRENT_USE_RTC=0 \
	-I .dependencies/install/include -I /opt/homebrew/include Tests/NativeDiskDiagnostics.cpp \
	.dependencies/install/lib/libtorrent-rasterbar.a .dependencies/install/lib/libssl.a .dependencies/install/lib/libcrypto.a \
	-L/opt/homebrew/opt/llvm/lib/c++ -Wl,-rpath,/opt/homebrew/opt/llvm/lib/c++ \
	-framework Foundation -framework CoreFoundation -framework SystemConfiguration -o "$work/probe" > "$out/build.log" 2>&1
ruby -rjson -rdigest -e 'puts JSON.pretty_generate({revision: `git rev-parse HEAD`.strip, libtorrent_revision: "6da363d2994f17c0b3c0450d124cf73a31a73847", library_sha256: Digest::SHA256.file(".dependencies/install/lib/libtorrent-rasterbar.a").hexdigest, probe_sha256: Digest::SHA256.file("Tests/NativeDiskDiagnostics.cpp").hexdigest, settings: {aio_threads: 0, hashing_threads: 0}, purpose: "deterministic path counts; not timing acceptance", clang: `/opt/homebrew/opt/llvm/bin/clang++ --version`.strip, boost_headers: File.read("/opt/homebrew/include/boost/version.hpp").lines.grep(/^#define BOOST_(?:LIB_)?VERSION/).map(&:strip), provenance: "Probe toolchain matches the installed archive ABI; cached Apple-build flags do not describe that ABI. Reference archive/binaries are unchanged."})' > "$out/environment.json"
"$work/probe" "$work" > "$out/results.jsonl" 2> "$out/errors.log"
cat "$out/results.jsonl"
