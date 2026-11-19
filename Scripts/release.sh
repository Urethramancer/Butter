#!/bin/bash
set -euo pipefail

fail() { printf 'Release failed: %s\n' "$*" >&2; exit 1; }
usage() {
	cat <<'EOF'
Usage: Scripts/release.sh setup
       Scripts/release.sh vMAJOR.MINOR.PATCH [--prepare]
       Scripts/release.sh --prepare

setup stores notarisation credentials in Keychain using a secure prompt.
Releases build an existing annotated tag, notarise and verify an arm64 ZIP,
then push the tag and publish a GitHub release. --prepare keeps it local;
without a tag it builds HEAD, labelling untagged builds -dev-<commit>.
Optional environment: BUTTER_NOTARY_PROFILE (default Butter-notary).
EOF
}

profile=${BUTTER_NOTARY_PROFILE:-Butter-notary}
team=ZWL2A2VN43
identity="Developer ID Application: Ronny Bangsund ($team)"
repository=Urethramancer/Butter
if [[ ${1-} == --help ]]; then usage; exit 0; fi
if [[ ${1-} == setup && $# == 1 ]]; then
	[[ -t 0 ]] || fail 'run setup interactively in Terminal; do not pass credentials to this script'
	read -r -p 'Developer Apple ID: ' apple_id
	[[ -n $apple_id ]] || fail 'an Apple ID is required'
	exec xcrun notarytool store-credentials "$profile" --apple-id "$apple_id" --team-id "$team"
fi
[[ $# == 1 || ( $# == 2 && $2 == --prepare ) ]] || { usage >&2; exit 1; }
target=$1
publish=true
if [[ $target == --prepare ]]; then
	[[ $# == 1 ]] || fail 'unexpected arguments after --prepare'
	target=HEAD
	publish=false
fi
[[ ${2-} != --prepare ]] || publish=false
[[ $target != HEAD || $publish == false ]] || fail 'use --prepare for a development build of HEAD'
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
[[ $(git rev-parse --is-shallow-repository) == false ]] || fail 'a complete Git checkout is required'
development=false
if [[ $target == HEAD ]]; then
	revision=$(git rev-parse HEAD)
	tag=
	while IFS= read -r candidate; do
		if [[ $candidate =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && $(git cat-file -t "refs/tags/$candidate") == tag ]]; then
			tag=$candidate
			break
		fi
	done < <(git tag --points-at HEAD --sort=-version:refname)
	if [[ -z $tag ]]; then tag=dev-${revision:0:12}; development=true; fi
else
	tag=$target
	[[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'expected vMAJOR.MINOR.PATCH'
	[[ $(git cat-file -t "refs/tags/$tag") == tag ]] || fail 'create the requested annotated release tag first'
	tag_object=$(git rev-parse "refs/tags/$tag")
	revision=$(git rev-parse "refs/tags/$tag^{commit}")
fi
remote=$(git remote get-url origin)
case "$remote" in
	git@github.com:Urethramancer/Butter.git|https://github.com/Urethramancer/Butter.git|https://github.com/Urethramancer/Butter) ;;
	*) fail 'origin must point to Urethramancer/Butter on GitHub' ;;
esac
if $publish; then
	gh auth status --active >/dev/null 2>&1 || fail 'run gh auth login first'
	releases=$(gh api --paginate "repos/$repository/releases" --jq '.[].tag_name')
	if grep -Fxq "$tag" <<<"$releases"; then
		fail 'a release or draft already exists for this tag; inspect it before continuing'
	fi
	remote_tag=$(git ls-remote --refs "$remote" "refs/tags/$tag")
	[[ -z $remote_tag || ${remote_tag%%[[:space:]]*} == "$tag_object" ]] || fail 'the remote tag differs from the local tag'
fi
security find-identity -v -p codesigning | grep -Fq "\"$identity\"" || fail "no valid $identity certificate with a private key"
xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null || fail 'notarisation credentials unavailable; run Scripts/release.sh setup'

mkdir -p "$root/.build/releases"
output=$(mktemp -d "$root/.build/releases/$tag.XXXXXX")
source_dir=$output/source
cleanup() {
	status=$?
	trap - EXIT
	# Only the disposable clone and derived data are removed; retain release evidence.
	rm -rf "$source_dir" "$output/DerivedData" "$output/BuildProducts" "$output/Intermediates"
	if [[ $status != 0 ]]; then printf 'Release stopped. Logs and artifacts: %s\n' "$output" >&2; fi
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Building %s (%s). Logs: %s\n' "$tag" "$revision" "$output"
# A full local clone preserves version history and isolates the build from local edits.
git clone --quiet --no-hardlinks --no-checkout "$root" "$source_dir"
git -C "$source_dir" checkout --quiet --detach "$revision"
archive=$output/Butter-$tag.xcarchive
if ! xcodebuild -project "$source_dir/Butter.xcodeproj" -scheme Butter -configuration Release \
	-destination 'generic/platform=macOS' -derivedDataPath "$output/DerivedData" \
	-archivePath "$archive" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
	SYMROOT="$output/BuildProducts" OBJROOT="$output/Intermediates" \
	DEVELOPMENT_TEAM="$team" ENABLE_HARDENED_RUNTIME=YES \
	CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp archive >"$output/build.log" 2>&1; then
	tail -n 60 "$output/build.log" >&2
	fail 'archive failed'
fi
cat >"$output/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>$identity</string>
<key>teamID</key><string>$team</string>
</dict></plist>
EOF
if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$output/ExportOptions.plist" \
	-exportPath "$output/export" >"$output/export.log" 2>&1; then
	cat "$output/export.log" >&2
	fail 'Developer ID export failed'
fi
app=$output/export/Butter.app
plist=$app/Contents/Info.plist
version=$(plutil -extract CFBundleShortVersionString raw "$plist")
if ! $development; then
	[[ $version == "${tag#v}" ]] || fail 'built version does not match the tag'
fi
[[ $(plutil -extract CFBundleIdentifier raw "$plist") == net.grimdork.Butter ]] || fail 'unexpected bundle identifier'
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --verbose=4 "$app" >"$output/signature.log" 2>&1
grep -Fxq "Authority=$identity" "$output/signature.log" || fail 'unexpected signing certificate'
grep -Fxq "TeamIdentifier=$team" "$output/signature.log" || fail 'unexpected signing team'
grep -Eq 'flags=.*\(.*runtime.*\)' "$output/signature.log" || fail 'hardened runtime is missing'
grep -q '^Timestamp=' "$output/signature.log" || fail 'secure timestamp is missing'
codesign -d --entitlements - --xml "$app" >"$output/entitlements.plist" 2>"$output/entitlements.log"
plutil -lint "$output/entitlements.plist" >/dev/null || fail 'cannot inspect signing entitlements'
debugging=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$output/entitlements.plist" 2>/dev/null || :)
[[ $debugging != true ]] || fail 'debugger entitlement is enabled'
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/submission.zip"
printf 'Submitting to Apple; this can take several minutes.\n'
notary_exit=0
xcrun notarytool submit "$output/submission.zip" --keychain-profile "$profile" \
	--wait --timeout 30m --output-format json >"$output/notarisation.json" || notary_exit=$?
submission=$(plutil -extract id raw "$output/notarisation.json" 2>/dev/null || :)
if [[ -n $submission ]]; then
	xcrun notarytool log "$submission" --keychain-profile "$profile" "$output/notarisation-log.json" || fail 'cannot retrieve the notarisation log'
fi
status=$(plutil -extract status raw "$output/notarisation.json" 2>/dev/null || :)
[[ $notary_exit == 0 && $status == Accepted ]] || fail "notarisation did not succeed (${status:-no status}); inspect notarisation logs"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app"
release_name=$tag
if $development; then release_name=v$version-$tag; fi
asset=Butter-$release_name-arm64.zip
# Repack after stapling so downloads include the offline Gatekeeper ticket.
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$asset"
(cd "$output" && shasum -a 256 "$asset" >SHA256SUMS)
printf 'Tag: %s\nCommit: %s\n' "$tag" "$revision" >"$output/source.txt"
if $publish; then
	git push "$remote" "refs/tags/$tag:refs/tags/$tag"
	gh release create "$tag" "$output/$asset" "$output/SHA256SUMS" --repo "$repository" \
		--verify-tag --draft --title "Butter $tag" --generate-notes
	mkdir "$output/download"
	gh release download "$tag" --repo "$repository" --dir "$output/download" --pattern "$asset" --pattern SHA256SUMS
	cmp "$output/$asset" "$output/download/$asset"
	cmp "$output/SHA256SUMS" "$output/download/SHA256SUMS"
	gh release edit "$tag" --repo "$repository" --draft=false
	printf 'Published https://github.com/%s/releases/tag/%s\n' "$repository" "$tag"
fi
printf 'Verified release files: %s\n' "$output"
