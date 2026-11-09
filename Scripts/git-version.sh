#!/bin/sh
set -eu

fail() {
	printf 'error: Git versioning: %s\n' "$*" >&2
	exit 1
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail 'expected repository, output plist and optional metadata plist paths'
cd "$1" || fail 'cannot open repository'
output=$2
metadata=${3-}

# Avoid optional writes and configuration outside the declared sandbox inputs.
export GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git rev-parse --verify HEAD >/dev/null 2>&1 || fail 'complete Git history with a HEAD commit is required'
shallow=$(git rev-parse --is-shallow-repository) || fail 'cannot inspect Git history'
[ "$shallow" = false ] || fail 'shallow history is unsupported; run git fetch --unshallow first'
build=$(git rev-list --count HEAD) || fail 'cannot count commits'

# Match complete release names only, including lightweight and annotated tags.
tags=$(git tag --merged HEAD) || fail 'cannot read release tags'
tags=$(printf '%s\n' "$tags" | /usr/bin/grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || :)
version=0.1.0
if [ -n "$tags" ]; then
	set -- --tags --abbrev=0
	while IFS= read -r tag; do
		set -- "$@" --match "$tag"
	done <<EOF
$tags
EOF
	tag=$(git describe "$@" HEAD) || fail 'cannot find nearest release tag'
	version=${tag#v}
fi

cat > "$output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleVersion</key>
	<string>$build</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
</dict>
</plist>
EOF

if [ -n "$metadata" ]; then
	/usr/libexec/PlistBuddy -c "Merge '$metadata'" "$output" || fail 'cannot merge app metadata'
fi
