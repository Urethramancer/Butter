#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
derived=${BUTTER_UI_DERIVED_DATA:-$PWD/.build/ui}
xcodebuild -project Butter.xcodeproj -scheme Butter -configuration Debug \
	-destination 'platform=macOS' -derivedDataPath "$derived" \
	SYMROOT="$derived/Build/Products" OBJROOT="$derived/Build/Intermediates.noindex" \
	CODE_SIGNING_ALLOWED=NO -enableCodeCoverage YES build-for-testing

products=$derived/Build/Products/Debug
host=$products/ButterUITestHost.app
rm -rf "$host"
cp -R "$products/Butter.app" "$host"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.grimdork.Butter.UITestTarget" "$host/Contents/Info.plist"
codesign -s - --force "$host" >/dev/null 2>&1 || true

exec xcodebuild -project Butter.xcodeproj -scheme Butter -configuration Debug \
	-destination 'platform=macOS' -derivedDataPath "$derived" \
	SYMROOT="$derived/Build/Products" OBJROOT="$derived/Build/Intermediates.noindex" \
	CODE_SIGNING_ALLOWED=NO -enableCodeCoverage YES test-without-building "$@"
