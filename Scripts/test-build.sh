#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
out=$PWD/.build/verification
mkdir -p "$out"
for configuration in Debug Release; do
	xcodebuild -project Butter.xcodeproj -scheme Butter -configuration "$configuration" \
		-destination 'platform=macOS' -derivedDataPath "$out/$configuration" \
		SYMROOT="$out/$configuration/Build/Products" OBJROOT="$out/$configuration/Build/Intermediates.noindex" \
		CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build > "$out/$configuration.log" 2>&1 || { cat "$out/$configuration.log"; exit 1; }
	app=$out/$configuration/Build/Products/$configuration/Butter.app
	otool -L "$app/Contents/MacOS/Butter" > "$out/$configuration-linkage.txt"
	if /usr/bin/grep -E '(/opt/homebrew|/usr/local|libtorrent|libssl|libcrypto)' "$out/$configuration-linkage.txt"; then
		echo 'Unexpected dynamic dependency' >&2; exit 1
	fi
	for licence in Butter/Licences/*.txt; do cmp "$licence" "$app/Contents/Resources/$(basename "$licence")"; done
	done
xcodebuild -project Butter.xcodeproj -scheme Butter -configuration Debug \
	-destination 'platform=macOS' -derivedDataPath "$out/Debug" \
	SYMROOT="$out/Debug/Build/Products" OBJROOT="$out/Debug/Build/Intermediates.noindex" \
	CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build > "$out/repeat.log" 2>&1 || { cat "$out/repeat.log"; exit 1; }
if /usr/bin/grep -E '^SwiftCompile |^CompileC ' "$out/repeat.log"; then
	echo 'Unexpected compilation during unchanged repeat build' >&2; exit 1
fi
rm "$out/Debug.log" "$out/Release.log" "$out/repeat.log"
printf 'PASS: unsigned Debug/Release builds, static dependencies, bundled licences and unchanged repeat build\n'
