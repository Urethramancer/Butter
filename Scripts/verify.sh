#!/bin/sh
# Native verification by default. The pinned engine is available in optional suites.
set -eu
cd "$(dirname "$0")/.."
mode=${1:-all}
if [ "${BUTTER_TEST_LOG_ACTIVE:-0}" != 1 ]; then
	exec sh Scripts/test-log.sh "$mode" sh Scripts/verify.sh "$@"
fi
case "$mode" in
	network) shift; exec Scripts/test-http.sh "$@" ;;
	client|engine|contract|metadata|metadata-reference|creation|http|native-storage|native-diagnostics|restart-diagnostics|peer|peer-reference|benchmark|storage-benchmark|lifecycle|interface|storage|disk|interruption|ui|build) shift; exec "Scripts/test-$mode.sh" "$@" ;;
	version) exec sh Tests/git-version.sh ;;
	all|final)
		sh Tests/test-log.sh
		sh Tests/git-version.sh
		for suite in client storage disk native-storage creation contract lifecycle interface build; do "Scripts/test-$suite.sh"; done
		if [ "$mode" = final ]; then Scripts/verify.sh coverage "${2:-final}"
		else swift test --no-parallel --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent; fi
		Scripts/verify.sh sanitizers "${2:-$mode}"
		Scripts/test-ui.sh
		;;
	reference)
		Scripts/test-metadata-reference.sh
		Scripts/test-creation.sh --reference
		Scripts/test-peer-reference.sh
		Scripts/test-contract.sh --reference
		Scripts/test-engine.sh
		Scripts/test-interruption.sh
		Scripts/test-disk.sh --reference
		;;
	coverage|sanitizers|reference-sanitizers)
		label=${2:-after}
		case "$label" in *[!a-zA-Z0-9_-]*|'') echo 'Invalid output label' >&2; exit 2 ;; esac
		out=$PWD/.build/$mode/$label
		mkdir -p "$out"
		if [ "$mode" = coverage ]; then
			swift test --no-parallel --enable-code-coverage --package-path Packages/ButterTorrent --scratch-path "$out/package"
			generated=$(swift test --show-codecov-path --package-path Packages/ButterTorrent --scratch-path "$out/package")
			cp "$generated" "$out/coverage.json"
		elif [ "$mode" = sanitizers ]; then
			for sanitizer in address thread; do
				swift test --no-parallel --sanitize="$sanitizer" --package-path Packages/ButterTorrent --scratch-path "$out/$sanitizer"
			done
		else
			set -- -DCMAKE_CXX_COMPILER=/usr/bin/clang++ -DCMAKE_OBJCXX_COMPILER=/usr/bin/clang++ \
				-DBoost_NO_BOOST_CMAKE=ON -DBUTTER_ENGINE_TESTS=ON -DCMAKE_BUILD_TYPE=Release \
				-DCMAKE_OBJCXX_FLAGS_RELEASE='-O0 -g -DNDEBUG' -DCMAKE_OSX_ARCHITECTURES=arm64 \
				-DCMAKE_PREFIX_PATH="$PWD/.dependencies/install" -DOPENSSL_ROOT_DIR="$PWD/.dependencies/install" \
				-DBoost_INCLUDE_DIR="$PWD/.dependencies/src/boost_1_88_0" -DCMAKE_POLICY_DEFAULT_CMP0167=OLD
			for sanitizer in address,undefined thread; do
				cmake -S Tests/Reference -B "$out/$sanitizer" "$@" -DBUTTER_SANITIZER="$sanitizer"
				cmake --build "$out/$sanitizer" --parallel 4
				"$out/$sanitizer/EngineTests"
				BUTTER_INTERRUPTION_BINARY="$out/$sanitizer/InterruptionTests" Scripts/test-interruption.sh
				BUTTER_ENGINE_DISK_BINARY="$out/$sanitizer/EngineDiskFailureTests" Scripts/test-disk.sh
			done
		fi
		;;
	*) echo 'Usage: Scripts/verify.sh [all|final|reference|benchmark|storage-benchmark|native-diagnostics|restart-diagnostics|client|storage|native-storage|disk|interruption|engine|contract|metadata|metadata-reference|creation|http|network|peer|peer-reference|lifecycle|interface|ui|build|version|coverage|sanitizers|reference-sanitizers]' >&2; exit 2 ;;
esac
