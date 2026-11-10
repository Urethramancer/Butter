#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/butter-log-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
export BUTTER_TEST_LOG_DIR=$work/logs
sh Scripts/test-log.sh passed sh -c 'echo PASS' > "$work/output"
[ -z "$(find "$BUTTER_TEST_LOG_DIR" -type f -name '*.log')" ]
status=0
sh Scripts/test-log.sh failed sh -c 'echo diagnostic >&2; exit 7' > "$work/output" 2>&1 || status=$?
[ "$status" -eq 7 ]
log=$(find "$BUTTER_TEST_LOG_DIR" -type f -name '*.log')
[ -n "$log" ]
[ "$(cat "$log")" = diagnostic ]
sh Scripts/test-log.sh another-pass sh -c 'echo PASS' > "$work/output"
[ -f "$log" ]
[ "$(find "$BUTTER_TEST_LOG_DIR" -type f -name '*.log' | wc -l | tr -d ' ')" -eq 1 ]
status=0
sh Scripts/test-log.sh '../invalid' touch "$work/unexpected" > "$work/output" 2>&1 || status=$?
[ "$status" -eq 2 ] && [ ! -e "$work/unexpected" ]
status=0
sh Scripts/test-log.sh interrupted sh -c 'kill -TERM "$PPID"' > "$work/output" 2>&1 || status=$?
[ "$status" -eq 143 ]
[ "$(find "$BUTTER_TEST_LOG_DIR" -type f -name '*.log' | wc -l | tr -d ' ')" -eq 2 ]
echo 'PASS: passing logs deleted; failure diagnostics and exit status retained'
