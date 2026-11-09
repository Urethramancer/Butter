#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
derived=${BUTTER_UI_DERIVED_DATA:-$PWD/.build/ui}
exec xcodebuild -project Butter.xcodeproj -scheme Butter -configuration Debug \
	-destination 'platform=macOS' -derivedDataPath "$derived" \
	SYMROOT="$derived/Build/Products" OBJROOT="$derived/Build/Intermediates.noindex" \
	CODE_SIGNING_ALLOWED=NO -enableCodeCoverage YES test "$@"
