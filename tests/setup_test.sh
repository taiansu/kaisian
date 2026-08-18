#!/bin/bash
set -u

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kaisian-test.XXXXXX") || exit 1
trap 'rm -rf -- "$ROOT"' EXIT HUP INT TERM
SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/setup.sh
PASS=0
FAIL=0

run_case() {
  name=$1
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s\n' "$name" >&2
  fi
}

help_case() {
  output=$(/bin/bash "$SCRIPT" --help 2>&1) || return 1
  printf '%s\n' "$output" | /usr/bin/grep -F 'setup.sh [OPTIONS]' >/dev/null || return 1
  printf '%s\n' "$output" | /usr/bin/grep -F -- '--interactive' >/dev/null
}

run_case 'help works' help_case
printf '%s passed; %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
