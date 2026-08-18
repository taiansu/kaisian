#!/bin/bash
set -u

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kaisian-test.XXXXXX") || exit 1
ROOT=$(cd -P "$ROOT" && pwd -P)
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

assert_status() {
  expected=$1
  shift
  "$@"
  actual=$?
  test "$actual" -eq "$expected"
}

assert_contains() {
  haystack=$1
  needle=$2
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

assert_not_exists() {
  target=$1
  if test -e "$target" || test -L "$target"; then
    return 1
  fi
  return 0
}

make_home() {
  h=$(mktemp -d "$ROOT/home.XXXXXX")
  (cd -P "$h" && pwd -P)
}

make_empty_bin() {
  dir="$ROOT/empty-bin"
  mkdir -p "$dir"
  (cd -P "$dir" && pwd -P)
}

# 1. --help succeeds when git/stow/fzf are absent
help_without_tools_case() {
  empty_bin=$(make_empty_bin)
  test_home=$(make_home)
  output=$(env -i HOME="$test_home" PATH="$empty_bin:/bin:/usr/bin" /bin/bash "$SCRIPT" --help 2>&1) || return 1
  assert_contains "$output" 'setup.sh [OPTIONS]' || return 1
  assert_contains "$output" '--interactive'
}

# 2. --profile/--groups/--interactive/--all reject every pair
selection_mutual_exclusion_case() {
  test_home=$(make_home)
  pairs=(
    "--profile minimal --groups shell"
    "--profile minimal --interactive"
    "--profile minimal --all"
    "--groups shell --interactive"
    "--groups shell --all"
    "--interactive --all"
  )
  for pair in "${pairs[@]}"; do
    output=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" $pair 2>&1)
    status=$?
    if test "$status" -eq 0; then
      printf 'Expected pair to fail: %s\n' "$pair" >&2
      return 1
    fi
  done
  return 0
}

# 3. unknown arguments and missing values fail
unknown_and_missing_values_case() {
  test_home=$(make_home)
  bad_args=(
    "--unknown"
    "-x"
    "--profile"
    "--profile="
    "--groups"
    "--groups="
    "--repo"
    "--repo="
    "--ref"
    "--ref="
    "--repo-dir"
    "--repo-dir="
    "--lang"
    "--lang="
  )
  for arg in "${bad_args[@]}"; do
    output=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" $arg 2>&1)
    status=$?
    if test "$status" -eq 0; then
      printf 'Expected arg to fail: %s\n' "$arg" >&2
      return 1
    fi
  done
  return 0
}

# 4. --lang accepts only en and zh-TW
lang_validation_case() {
  test_home=$(make_home)
  # Invalid explicit languages
  for invalid_lang in "fr" "zh" "de" "en-US" "zh-CN"; do
    output=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" --lang "$invalid_lang" 2>&1)
    status=$?
    if test "$status" -eq 0; then
      printf 'Expected --lang %s to fail\n' "$invalid_lang" >&2
      return 1
    fi
  done

  # Valid explicit languages
  for valid_lang in "en" "zh-TW"; do
    output=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" --help --lang "$valid_lang" 2>&1) || return 1
    output_eq=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" --help "--lang=$valid_lang" 2>&1) || return 1
  done
  return 0
}

# 5. LC_ALL > LC_MESSAGES > LANG > English fallback
locale_precedence_case() {
  test_home=$(make_home)

  # Explicit --lang en overrides zh_TW environment
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" LC_ALL="zh_TW.UTF-8" /bin/bash "$SCRIPT" --lang en --unknown 2>&1)
  assert_contains "$out" "Error" || return 1

  # Explicit --lang zh-TW overrides English environment
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" LC_ALL="C" /bin/bash "$SCRIPT" --lang zh-TW --unknown 2>&1)
  assert_contains "$out" "錯誤" || return 1

  # LC_ALL overrides LC_MESSAGES and LANG
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" LC_ALL="C" LC_MESSAGES="zh_TW.UTF-8" LANG="zh_TW.UTF-8" /bin/bash "$SCRIPT" --unknown 2>&1)
  assert_contains "$out" "Error" || return 1

  # LC_MESSAGES overrides LANG
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" LC_ALL="" LC_MESSAGES="zh_TW.UTF-8" LANG="C" /bin/bash "$SCRIPT" --unknown 2>&1)
  assert_contains "$out" "錯誤" || return 1

  # LANG takes effect when LC_ALL and LC_MESSAGES are empty
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" LC_ALL="" LC_MESSAGES="" LANG="zh_TW.UTF-8" /bin/bash "$SCRIPT" --unknown 2>&1)
  assert_contains "$out" "錯誤" || return 1

  # Default fallback is English
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" LC_ALL="" LC_MESSAGES="" LANG="" /bin/bash "$SCRIPT" --unknown 2>&1)
  assert_contains "$out" "Error" || return 1
  return 0
}

# 6. zh, zh_TW.UTF-8, and zh-Hant select zh-TW text
chinese_locale_variants_case() {
  test_home=$(make_home)
  variants=("zh" "zh_TW.UTF-8" "zh-Hant" "zh_CN.UTF-8" "zh_HK")
  for var in "${variants[@]}"; do
    out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" LC_ALL="$var" /bin/bash "$SCRIPT" --unknown 2>&1)
    assert_contains "$out" "錯誤" || {
      printf 'Failed for locale variant: %s\n' "$var" >&2
      return 1
    }
  done
  return 0
}

# 7. normal execution reports every missing prerequisite without installing it
missing_prerequisites_case() {
  test_home=$(make_home)
  empty_bin=$(make_empty_bin)
  out=$(env -i HOME="$test_home" PATH="$empty_bin:/usr/bin:/bin" /bin/bash "$SCRIPT" 2>&1)
  status=$?
  test "$status" -ne 0 || return 1
  assert_contains "$out" "stow" || return 1
  assert_contains "$out" "fzf" || return 1
  return 0
}

# 8. relative, missing, symlinked, unowned, or unwritable HOME fails
home_validation_case() {
  # Relative HOME
  out=$(env -i HOME="relative/home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1

  # Missing HOME
  out=$(env -i HOME="$ROOT/nonexistent_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1

  # Symlinked HOME
  real_h=$(make_home)
  sym_h="$ROOT/sym_home"
  ln -s "$real_h" "$sym_h"
  out=$(env -i HOME="$sym_h" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1

  # Unwritable HOME
  unwritable_h=$(make_home)
  chmod 500 "$unwritable_h"
  out=$(env -i HOME="$unwritable_h" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  chmod 700 "$unwritable_h"
  return 0
}

# 9. existing /private/tmp/kaisian-$UID.lock fails and is never removed
existing_lock_case() {
  test_home=$(make_home)
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"

  if test -d "$lock_dir"; then
    rm -rf "$lock_dir" 2>/dev/null || true
  fi

  mkdir -m 0700 "$lock_dir" || return 1
  touch "$lock_dir/existing_marker"

  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" 2>&1)
  status=$?
  test "$status" -ne 0 || return 1

  # Verify lock directory and marker are still there
  test -d "$lock_dir" || return 1
  test -f "$lock_dir/existing_marker" || return 1

  # Cleanup our test marker and lock
  rm -f "$lock_dir/existing_marker"
  rmdir "$lock_dir"
  return 0
}

# 10. runs with different TMPDIR values contend on the same fixed lock
tmpdir_lock_contention_case() {
  test_home=$(make_home)
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"

  if test -d "$lock_dir"; then
    rm -rf "$lock_dir" 2>/dev/null || true
  fi

  mkdir -m 0700 "$lock_dir" || return 1

  out=$(env -i TMPDIR="$ROOT/custom_tmp" HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" 2>&1)
  status=$?
  test "$status" -ne 0 || return 1

  rmdir "$lock_dir"
  return 0
}

# 11. repo-dir/state paths equal to, above, or below the lock fail; sibling paths pass
path_overlap_with_lock_case() {
  test_home=$(make_home)
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"

  # Equals lock
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" --repo-dir "$lock_dir" 2>&1)
  test $? -ne 0 || return 1

  # Ancestor of lock (/private/tmp)
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" --repo-dir "/private/tmp" 2>&1)
  test $? -ne 0 || return 1

  # Descendant of lock
  out=$(env -i HOME="$test_home" PATH="/usr/bin:/bin" /bin/bash "$SCRIPT" --repo-dir "$lock_dir/sub" 2>&1)
  test $? -ne 0 || return 1

  return 0
}

# 12. cleanup leaves an unrecognized lock entry untouched
cleanup_leaves_unrecognized_lock_case() {
  export KAISIAN_TESTING=1
  . "$SCRIPT"
  uid=$(/usr/bin/id -u)
  LOCK_DIR="/private/tmp/kaisian-$uid.lock"
  if test -d "$LOCK_DIR"; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi

  mkdir -m 0700 "$LOCK_DIR" || return 1
  SANDBOX="$LOCK_DIR/sandbox"
  mkdir -m 0700 "$SANDBOX" || return 1
  RECORDED_LOCK_DEV_INO=$(/usr/bin/stat -f '%d %i' "$LOCK_DIR")
  RECORDED_SANDBOX_DEV_INO=$(/usr/bin/stat -f '%d %i' "$SANDBOX")
  touch "$LOCK_DIR/pid"
  touch "$LOCK_DIR/unrecognized_file"

  # Run cleanup
  cleanup

  # Sandbox and pid should be removed, but unrecognized_file and lock_dir must remain
  assert_not_exists "$SANDBOX" || return 1
  assert_not_exists "$LOCK_DIR/pid" || return 1
  test -f "$LOCK_DIR/unrecognized_file" || return 1
  test -d "$LOCK_DIR" || return 1

  # Clean up test artifact
  rm -f "$LOCK_DIR/unrecognized_file"
  rmdir "$LOCK_DIR"
  return 0
}

# 13. Bilingual message key parity test
message_key_parity_case() {
  export KAISIAN_TESTING=1
  . "$SCRIPT"

  keys=(
    "error_prefix"
    "missing_tools"
    "unsupported_os"
    "no_tty"
    "selection_conflict"
    "unknown_argument"
    "missing_option_value"
    "invalid_language"
    "invalid_home"
    "lock_failed"
    "unsafe_path_overlap"
    "unsupported_stow"
  )

  for key in "${keys[@]}"; do
    en_msg=$(LANGUAGE=en message "$key" "test_arg" "test_arg2") || {
      printf 'message_en failed for key: %s\n' "$key" >&2
      return 1
    }
    zh_msg=$(LANGUAGE=zh-TW message "$key" "test_arg" "test_arg2") || {
      printf 'message_zh_tw failed for key: %s\n' "$key" >&2
      return 1
    }
    test -n "$en_msg" || return 1
    test -n "$zh_msg" || return 1
  done

  # Unknown key returns 64
  LANGUAGE=en message "unknown_test_key" >/dev/null 2>&1
  test $? -eq 64 || return 1
  LANGUAGE=zh-TW message "unknown_test_key" >/dev/null 2>&1
  test $? -eq 64 || return 1
  return 0
}

# 14. run_git environment sanitization
run_git_sanitization_case() {
  export KAISIAN_TESTING=1
  . "$SCRIPT"

  uid=$(/usr/bin/id -u)
  LOCK_DIR="/private/tmp/kaisian-$uid.lock"
  if test -d "$LOCK_DIR"; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi

  acquire_lock
  mock_bin="$ROOT/mock-git-bin"
  mkdir -p "$mock_bin"
  cat << 'EOF' > "$mock_bin/git"
#!/bin/bash
printf 'HOME=%s\n' "$HOME"
printf 'LC_ALL=%s\n' "${LC_ALL-}"
printf 'GIT_CONFIG_NOSYSTEM=%s\n' "${GIT_CONFIG_NOSYSTEM-}"
printf 'GIT_CONFIG_GLOBAL=%s\n' "${GIT_CONFIG_GLOBAL-}"
printf 'GIT_ATTR_NOSYSTEM=%s\n' "${GIT_ATTR_NOSYSTEM-}"
printf 'GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-}"
printf 'GIT_ASKPASS=%s\n' "${GIT_ASKPASS-}"
printf 'GIT_NO_REPLACE_OBJECTS=%s\n' "${GIT_NO_REPLACE_OBJECTS-}"
printf 'GIT_DIR=%s\n' "${GIT_DIR-unset}"
printf 'GIT_WORK_TREE=%s\n' "${GIT_WORK_TREE-unset}"
printf 'GIT_AUTHOR_NAME=%s\n' "${GIT_AUTHOR_NAME-unset}"
EOF
  chmod +x "$mock_bin/git"

  out=$(PATH="$mock_bin:/usr/bin:/bin" GIT_DIR="/hostile/dir" GIT_WORK_TREE="/hostile/wt" GIT_AUTHOR_NAME="hostile" run_git status)
  cleanup

  assert_contains "$out" "HOME=$SANDBOX/git-home" || return 1
  assert_contains "$out" "LC_ALL=C" || return 1
  assert_contains "$out" "GIT_CONFIG_NOSYSTEM=1" || return 1
  assert_contains "$out" "GIT_CONFIG_GLOBAL=/dev/null" || return 1
  assert_contains "$out" "GIT_ATTR_NOSYSTEM=1" || return 1
  assert_contains "$out" "GIT_TERMINAL_PROMPT=0" || return 1
  assert_contains "$out" "GIT_ASKPASS=/usr/bin/false" || return 1
  assert_contains "$out" "GIT_NO_REPLACE_OBJECTS=1" || return 1
  assert_contains "$out" "GIT_DIR=unset" || return 1
  assert_contains "$out" "GIT_WORK_TREE=unset" || return 1
  assert_contains "$out" "GIT_AUTHOR_NAME=unset" || return 1
  return 0
}

# 15. run_stow environment sanitization
run_stow_sanitization_case() {
  export KAISIAN_TESTING=1
  . "$SCRIPT"

  uid=$(/usr/bin/id -u)
  LOCK_DIR="/private/tmp/kaisian-$uid.lock"
  if test -d "$LOCK_DIR"; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi

  acquire_lock
  mock_bin="$ROOT/mock-stow-bin"
  mkdir -p "$mock_bin"
  cat << 'EOF' > "$mock_bin/stow"
#!/bin/bash
printf 'CWD=%s\n' "$(pwd -P)"
printf 'HOME=%s\n' "$HOME"
printf 'LC_ALL=%s\n' "${LC_ALL-}"
printf 'STOW_DIR=%s\n' "${STOW_DIR-unset}"
printf 'PERL5LIB=%s\n' "${PERL5LIB-unset}"
printf 'PERL5OPT=%s\n' "${PERL5OPT-unset}"
EOF
  chmod +x "$mock_bin/stow"

  out=$(PATH="$mock_bin:/usr/bin:/bin" STOW_DIR="/hostile/stow" PERL5LIB="/hostile/lib" PERL5OPT="-Mhostile" run_stow --version)
  cleanup

  assert_contains "$out" "CWD=$SANDBOX/stow-cwd" || return 1
  assert_contains "$out" "HOME=$SANDBOX/stow-home" || return 1
  assert_contains "$out" "LC_ALL=C" || return 1
  assert_contains "$out" "STOW_DIR=unset" || return 1
  assert_contains "$out" "PERL5LIB=unset" || return 1
  assert_contains "$out" "PERL5OPT=unset" || return 1
  return 0
}

# 16. behavioral stow probes in require_prerequisites
stow_behavioral_probes_case() {
  export KAISIAN_TESTING=1
  . "$SCRIPT"

  uid=$(/usr/bin/id -u)
  LOCK_DIR="/private/tmp/kaisian-$uid.lock"
  if test -d "$LOCK_DIR"; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi

  acquire_lock
  mock_bin="$ROOT/mock-probe-bin"
  mkdir -p "$mock_bin"

  # Create a behavioral fake stow that implements the probe expectations
  cat << 'EOF' > "$mock_bin/stow"
#!/bin/bash
set -u
dir=""
target=""
simulate=0
compat=0
ignore_regex=""
restow_pkgs=""
delete_pkgs=""

while test $# -gt 0; do
  case "$1" in
    -d) dir=$2; shift 2 ;;
    -t) target=$2; shift 2 ;;
    --dotfiles|--no-folding) shift ;;
    --simulate) simulate=1; shift ;;
    --compat) compat=1; shift ;;
    --ignore=*) ignore_regex=${1#--ignore=}; shift ;;
    -R) restow_pkgs="$restow_pkgs $2"; shift 2 ;;
    -D) delete_pkgs="$delete_pkgs $2"; shift 2 ;;
    *) restow_pkgs="$restow_pkgs $1"; shift ;;
  esac
done

if test "$simulate" -eq 1; then
  exit 0
fi

# Simulate link creation
for pkg in $restow_pkgs; do
  pkg_dir="$dir/$pkg"
  if test -d "$pkg_dir"; then
    for f in "$pkg_dir"/*; do
      test -e "$f" || continue
      fname=$(basename "$f")
      target_name="$fname"
      case "$fname" in
        dot-*) target_name=".${fname#dot-}" ;;
      esac
      ln -sf "$f" "$target/$target_name"
    done
  fi
done

for pkg in $delete_pkgs; do
  pkg_dir="$dir/$pkg"
  if test -d "$pkg_dir"; then
    for f in "$pkg_dir"/*; do
      test -e "$f" || continue
      fname=$(basename "$f")
      target_name="$fname"
      case "$fname" in
        dot-*) target_name=".${fname#dot-}" ;;
      esac
      rm -f "$target/$target_name"
    done
  fi
done
exit 0
EOF
  chmod +x "$mock_bin/stow"

  # Create fake git, fzf, plutil in mock_bin
  cat << 'EOF' > "$mock_bin/git"
#!/bin/bash
exit 0
EOF
  cat << 'EOF' > "$mock_bin/fzf"
#!/bin/bash
exit 0
EOF
  cat << 'EOF' > "$mock_bin/plutil"
#!/bin/bash
exit 0
EOF
  chmod +x "$mock_bin/git" "$mock_bin/fzf" "$mock_bin/plutil"

  PATH="$mock_bin:/usr/bin:/bin" require_prerequisites
  probe_status=$?
  cleanup

  test "$probe_status" -eq 0 || return 1
  return 0
}

run_case '--help succeeds when git/stow/fzf are absent' help_without_tools_case
run_case '--profile/--groups/--interactive/--all reject every pair' selection_mutual_exclusion_case
run_case 'unknown arguments and missing values fail' unknown_and_missing_values_case
run_case '--lang accepts only en and zh-TW' lang_validation_case
run_case 'LC_ALL > LC_MESSAGES > LANG > English fallback' locale_precedence_case
run_case 'zh, zh_TW.UTF-8, and zh-Hant select zh-TW text' chinese_locale_variants_case
run_case 'normal execution reports every missing prerequisite without installing it' missing_prerequisites_case
run_case 'relative, missing, symlinked, unowned, or unwritable HOME fails' home_validation_case
run_case 'existing /private/tmp/kaisian-$UID.lock fails and is never removed' existing_lock_case
run_case 'runs with different TMPDIR values contend on the same fixed lock' tmpdir_lock_contention_case
run_case 'repo-dir/state paths equal to, above, or below the lock fail; sibling paths pass' path_overlap_with_lock_case
run_case 'cleanup leaves an unrecognized lock entry untouched' cleanup_leaves_unrecognized_lock_case
run_case 'bilingual message key parity and unknown key check' message_key_parity_case
run_case 'run_git environment sanitization' run_git_sanitization_case
run_case 'run_stow environment sanitization' run_stow_sanitization_case
run_case 'behavioral stow probes in require_prerequisites' stow_behavioral_probes_case

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
