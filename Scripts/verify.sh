#!/bin/sh
# Focused suites, full verification, first-party coverage and separate sanitizers.
set -eu
cd "$(dirname "$0")/.."
mode=${1:-all}
case "$mode" in
	client|engine|contract|metadata|metadata-reference|creation|lifecycle|interface|storage|disk|interruption|ui|build) shift; exec "Scripts/test-$mode.sh" "$@" ;;
	version) exec sh Tests/git-version.sh ;;
	final)
		sh Tests/git-version.sh
		Scripts/test-metadata.sh
		Scripts/test-metadata-reference.sh
		Scripts/test-creation.sh
		Scripts/test-contract.sh
		Scripts/verify.sh coverage "${2:-final}"
		Scripts/test-build.sh
		Scripts/verify.sh sanitizers "${2:-final}"
		;;
	all)
		sh Tests/git-version.sh
		for suite in client storage disk engine metadata metadata-reference creation contract interruption lifecycle interface ui build; do "Scripts/test-$suite.sh"; done
		Scripts/verify.sh sanitizers all
		;;
	coverage|sanitizers)
		label=${2:-after}
		case "$label" in *[!a-zA-Z0-9_-]*|'') echo 'Invalid output label' >&2; exit 2 ;; esac
		out=$PWD/.build/$mode/$label
		mkdir -p "$out"
		set -- -DCMAKE_CXX_COMPILER=/usr/bin/clang++ -DCMAKE_OBJCXX_COMPILER=/usr/bin/clang++ \
			-DBoost_NO_BOOST_CMAKE=ON -DBUTTER_ENGINE_TESTS=ON -DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_OBJCXX_FLAGS_RELEASE='-O0 -g -DNDEBUG' -DCMAKE_OSX_ARCHITECTURES=arm64 \
			-DCMAKE_PREFIX_PATH="$PWD/.dependencies/install" -DOPENSSL_ROOT_DIR="$PWD/.dependencies/install" \
			-DBoost_INCLUDE_DIR="$PWD/.dependencies/src/boost_1_88_0" -DCMAKE_POLICY_DEFAULT_CMP0167=OLD
		if [ "$mode" = sanitizers ]; then
			for sanitizer in address,undefined thread; do
				cmake -S Butter/Engine -B "$out/$sanitizer" "$@" -DBUTTER_SANITIZER="$sanitizer"
				cmake --build "$out/$sanitizer" --parallel 4
				"$out/$sanitizer/EngineTests"
				BUTTER_INTERRUPTION_BINARY="$out/$sanitizer/InterruptionTests" Scripts/test-interruption.sh
				BUTTER_ENGINE_DISK_BINARY="$out/$sanitizer/EngineDiskFailureTests" Scripts/test-disk.sh
			done
			exit 0
		fi
		cmake -S Butter/Engine -B "$out/apple-bridge" "$@" -DBUTTER_COVERAGE=ON
		cmake --build "$out/apple-bridge" --parallel 4
		# Each run gets fresh profiles; repeated collection cannot include stale counters.
		raw=$(mktemp -d "$out/raw.XXXXXX")
		export LLVM_PROFILE_FILE="$raw/%m-%p.profraw"
		status=0
		"$out/apple-bridge/EngineTests" || status=1
		BUTTER_INTERRUPTION_BINARY="$out/apple-bridge/InterruptionTests" Scripts/test-interruption.sh || status=1
		for suite in Client Lifecycle Interface StorageCrash DiskFailure; do
			case "$suite" in
				Client) sources='Butter/Core/*.swift Tests/CoreRegressionTests.swift Tests/WatcherRaceTests.swift'; bridge='' ;;
				StorageCrash|DiskFailure) sources='Butter/Core/*.swift'; bridge='' ;;
				Lifecycle) sources='Butter/Core/*.swift Butter/Engine/EngineClient.swift Butter/TransferStore.swift Tests/StoreRegressionTests.swift'; bridge=1 ;;
				Interface) sources='Butter/Core/*.swift Butter/Engine/EngineClient.swift Butter/TransferStore.swift Butter/ContentView.swift Butter/UI/*.swift'; bridge=1 ;;
			esac
			set -- -module-name Butter -DDEBUG -profile-generate -profile-coverage-mapping -g -module-cache-path /tmp/butter-swift-cache
			if [ -n "$bridge" ]; then
				sources="Packages/ButterTorrent/Sources/ButterTorrentMetadata/*.swift $sources"
				set -- "$@" -import-objc-header Butter/Engine/ButterEngine.h -L "$out/apple-bridge" -L .dependencies/install/lib \
					-lButterEngine -ltorrent-rasterbar -lssl -lcrypto -lc++ -framework AppKit -framework SystemConfiguration
			fi
			# Intentional expansion of repository-controlled source globs.
			swiftc "$@" $sources "Tests/${suite}Tests.swift" -o "$out/${suite}Tests"
			if [ "$suite" = DiskFailure ]; then
				BUTTER_DISK_TEST_BINARY="$out/DiskFailureTests" BUTTER_ENGINE_DISK_BINARY="$out/apple-bridge/EngineDiskFailureTests" Scripts/test-disk.sh || status=1
			else
				"$out/${suite}Tests" "$PWD/.build/InterfaceChecks" || status=1
			fi
		done
		# UI tests launch the real app, isolate storage, and flush profiles on termination.
		BUTTER_UI_DERIVED_DATA="$out/app" Scripts/test-ui.sh \
			ENABLE_DEBUG_DYLIB=NO LIBRARY_SEARCH_PATHS="$out/apple-bridge $PWD/.dependencies/install/lib" || status=1
		set -- "$raw"/*.profraw
		if [ -d "$out/app/Build/ProfileData" ]; then
			while IFS= read -r profile; do set -- "$@" "$profile"; done <<PROFILES
$(rg --files "$out/app/Build/ProfileData" -g '*.profdata')
PROFILES
		fi
		xcrun llvm-profdata merge -sparse "$@" -o "$out/merged.profdata"
		set -- "$out/apple-bridge/EngineTests" -object "$out/apple-bridge/InterruptionTests" -object "$out/apple-bridge/EngineDiskFailureTests" -object "$out/ClientTests" -object "$out/LifecycleTests" -object "$out/InterfaceTests" -object "$out/StorageCrashTests" -object "$out/DiskFailureTests"
		app=$out/app/Build/Products/Debug/Butter.app/Contents/MacOS/Butter
		[ ! -f "$app" ] || set -- "$@" -object "$app"
		ignore='(Tests/|\.dependencies/|/\.build/|/DerivedSources/|/Applications/|/Library/Developer/|<.*>)'
		xcrun llvm-cov report "$@" -instr-profile="$out/merged.profdata" -ignore-filename-regex="$ignore" > "$out/report.txt"
		xcrun llvm-cov show "$@" -instr-profile="$out/merged.profdata" -ignore-filename-regex="$ignore" -show-branches=count > "$out/uncovered.txt"
		xcrun llvm-cov export "$@" -instr-profile="$out/merged.profdata" -ignore-filename-regex="$ignore" > "$out/coverage.json"
		xcrun llvm-cov report "$@" -instr-profile="$out/merged.profdata" -ignore-filename-regex="$ignore" $(rg --files Butter Packages/ButterTorrent/Sources -g '*.swift') > "$out/swift-report.txt"
		xcrun llvm-cov report "$@" -instr-profile="$out/merged.profdata" Butter/Engine/ButterEngine.mm > "$out/bridge-report.txt"
		printf 'Suite status: %s (0 = passed)\n' "$status" > "$out/status.txt"
		cat "$out/report.txt"
		if [ -f .build/coverage/before/report.txt ] && [ "$label" != before ]; then
			{ echo 'Before (failed baseline suites; all first-party code):'; tail -1 .build/coverage/before/report.txt; echo 'After:'; tail -1 "$out/report.txt"; } > "$out/comparison.txt"
		fi
		exit "$status"
		;;
	*) echo 'Usage: Scripts/verify.sh [final [label]|all|client|storage|disk|interruption|engine|contract|metadata|metadata-reference|creation|lifecycle|interface|ui|build|version|coverage [label]|sanitizers [label]]' >&2; exit 2 ;;
esac
