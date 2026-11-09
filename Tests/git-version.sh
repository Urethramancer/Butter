#!/bin/sh
set -eu

script=$(cd "$(dirname "$0")/../Scripts" && pwd)/git-version.sh
fixture=$(mktemp -d /tmp/butter-version-test.XXXXXX)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q -b main "$fixture/repo"
cd "$fixture/repo"

check() {
	/bin/sh "$script" "$PWD" "$fixture/version.plist"
	actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$fixture/version.plist")
	[ "$actual" = "$1" ] || { echo "Expected version $1, got $actual" >&2; exit 1; }
	actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$fixture/version.plist")
	[ "$actual" = "$2" ] || { echo "Expected build $2, got $actual" >&2; exit 1; }
}

reject() {
	if /bin/sh "$script" "$1" "$fixture/version.plist" >"$fixture/error" 2>&1; then
		echo 'Expected Git versioning to fail' >&2
		exit 1
	fi
	/usr/bin/grep -q "$2" "$fixture/error"
}

reject "$PWD" 'HEAD commit is required'
git commit -q --allow-empty -m Initial
check 0.1.0 1
git tag -a v0.2.0 -m Release
check 0.2.0 1
git commit -q --allow-empty -m Second
check 0.2.0 2
git tag v0.3.0
check 0.3.0 2
git commit -q --allow-empty -m Third
git tag v9.9.9-beta
git tag v8.8.8.8
check 0.3.0 3
git switch -q -c unrelated HEAD~2
git commit -q --allow-empty -m Unrelated
git tag v9.9.9
git switch -q main
check 0.3.0 3
# A merge must count both branches, rather than only first-parent history.
git branch merged HEAD~1
git switch -q merged
git commit -q --allow-empty -m Branch
git switch -q main
git merge -q --no-ff merged -m Merge
check 0.3.0 5
cat > "$fixture/App metadata.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
EOF
/bin/sh "$script" "$PWD" "$fixture/version.plist" "$fixture/App metadata.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$fixture/version.plist")" = '$(PRODUCT_BUNDLE_IDENTIFIER)' ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$fixture/version.plist")" = public.app-category.utilities ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$fixture/version.plist")" = 5 ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$fixture/version.plist")" = 0.3.0 ]
git clone -q --depth 1 "file://$PWD" "$fixture/shallow"
reject "$fixture/shallow" 'shallow history is unsupported'
mkdir "$fixture/no-git"
reject "$fixture/no-git" 'complete Git history'
printf 'Git versioning fixtures passed.\n'
