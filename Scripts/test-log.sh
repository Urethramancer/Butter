#!/bin/sh
# Retain command output only when the verification fails or is interrupted.
set -eu
cd "$(dirname "$0")/.."
label=${1:?Usage: test-log.sh label command [arguments...]}
shift
case "$label" in *[!a-zA-Z0-9_-]*|'') echo 'Invalid test log label' >&2; exit 2 ;; esac
[ "$#" -gt 0 ] || { echo 'A test command is required' >&2; exit 2; }
out=${BUTTER_TEST_LOG_DIR:-"$PWD/.build/test-logs"}
mkdir -p "$out"
run=$(mktemp -d "$out/$label.XXXXXX")
log=$run/output.log
trap 'printf "Interrupted; test log retained: %s\n" "$log" >&2; exit 129' HUP
trap 'printf "Interrupted; test log retained: %s\n" "$log" >&2; exit 130' INT
trap 'printf "Interrupted; test log retained: %s\n" "$log" >&2; exit 143' TERM
printf 'Running %s; output: %s\n' "$label" "$log"
status=0
BUTTER_TEST_LOG_ACTIVE=1 "$@" > "$log" 2>&1 || status=$?
cat "$log"
if [ "$status" -eq 0 ]; then
	rm "$log"
	rmdir "$run"
else
	printf 'Test log retained: %s\n' "$log" >&2
fi
exit "$status"
