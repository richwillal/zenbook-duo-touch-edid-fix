#!/bin/bash
#
# Regression test for edid_tool.py's patch logic.
#
# test/fixtures/edid-edp1-original.bin is a real, unmodified EDID dump
# from a Zenbook Duo's top panel (serial 0).
#
# test/fixtures/edid-edp2-manual-fix.bin is the bottom panel's EDID as
# manually fixed by hand (by directly editing bytes and recomputing the
# checksum) on real hardware, before this tool existed -- serial 2. This
# is not derived from the tool; it's the independent, known-good result
# this project was built to reproduce.
#
# This test patches the original fixture with serial 2 using
# edid_tool.py and asserts the result is byte-for-byte identical to the
# manual fix, proving the tool's patch logic (serial field + checksum
# recomputation) exactly matches a real, working, independently-created
# fix -- not just "looks plausible".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
FIXTURES="${SCRIPT_DIR}/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass=0
fail=0

# check(description, result_code)
#
# Intent: record and print one test's pass/fail outcome in a uniform
# format, and tally it into the running pass/fail counters used for the
# final summary line and the script's own exit code.
check() {
    local desc="$1" result="$2"
    if [ "${result}" = "0" ]; then
        echo "PASS: ${desc}"
        pass=$((pass + 1))
    else
        echo "FAIL: ${desc}"
        fail=$((fail + 1))
    fi
}

# run(command...)
#
# Intent: execute a command that is *expected to sometimes fail* (e.g. a
# `cmp` we want to assert on) and capture its exit code into the global
# `rc`, without letting that failure trip this script's own `set -e` and
# abort the whole test run -- so a genuinely failing assertion is
# reported by check() instead of silently killing the script before it
# can be reported at all.
run() {
    if "$@"; then rc=0; else rc=$?; fi
}

echo "=== Test 1: patched eDP-1 original matches the real manual eDP-2 fix ==="
python3 "${REPO_DIR}/edid_tool.py" patch \
    "${FIXTURES}/edid-edp1-original.bin" \
    "${WORK}/patched.bin" \
    2 >/dev/null
run cmp -s "${WORK}/patched.bin" "${FIXTURES}/edid-edp2-manual-fix.bin"
check "patch(original, serial=2) == real manual fix, byte-for-byte" "${rc}"

echo
echo "=== Test 2: patching leaves everything except serial+checksum untouched ==="
run python3 - "${FIXTURES}/edid-edp1-original.bin" "${WORK}/patched.bin" <<'PYEOF'
import sys

a = open(sys.argv[1], "rb").read()
b = open(sys.argv[2], "rb").read()
diffs = {i for i in range(len(a)) if a[i] != b[i]}
allowed = {12, 13, 14, 15, 127}
# Every changed byte must be within the serial field or the checksum --
# not every one of those bytes need actually change (e.g. going from
# serial 0 to serial 2 only flips byte 12).
sys.exit(0 if diffs <= allowed and diffs else 1)
PYEOF
check "only bytes 12-15 (serial) and 127 (checksum) differ from the original" "${rc}"

echo
echo "=== Test 3: patched EDID has a valid checksum ==="
run bash -c "python3 '${REPO_DIR}/edid_tool.py' info '${WORK}/patched.bin' \
    | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[\"checksum_valid\"] else 1)'"
check "recomputed checksum is valid" "${rc}"

echo
echo "=== Test 4: idempotent -- patching an already-patched file to the same serial changes nothing further ==="
python3 "${REPO_DIR}/edid_tool.py" patch "${WORK}/patched.bin" "${WORK}/patched-again.bin" 2 >/dev/null
run cmp -s "${WORK}/patched.bin" "${WORK}/patched-again.bin"
check "re-patching to the same serial is a no-op" "${rc}"

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
