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

make_fake_bin() {
  dir=$(mktemp -d "$ROOT/fakebin.XXXXXX")
  dir=$(cd -P "$dir" && pwd -P)
  cat << 'EOF' > "$dir/uname"
#!/bin/bash
printf 'Darwin\n'
EOF
  chmod +x "$dir/uname"
  printf '%s\n' "$dir"
}

# 1. --help succeeds when git/stow/fzf are absent
help_without_tools_case() {
  fake_bin=$(make_fake_bin)
  test_home=$(make_home)
  output=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --help 2>&1) || return 1
  assert_contains "$output" 'setup.sh [OPTIONS]' || return 1
  assert_contains "$output" '--interactive'
}

# 2. --profile/--groups/--interactive/--all reject every pair
selection_mutual_exclusion_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)
  pairs=(
    "--profile minimal --groups shell"
    "--profile minimal --interactive"
    "--profile minimal --all"
    "--groups shell --interactive"
    "--groups shell --all"
    "--interactive --all"
  )
  for pair in "${pairs[@]}"; do
    output=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" $pair 2>&1)
    status=$?
    test "$status" -ne 0 || return 1
    assert_contains "$output" 'Selection flags (--profile, --groups, --interactive, --all) are mutually exclusive.' || return 1
  done
  return 0
}

# 3. unknown arguments and missing values fail with exact diagnostics
unknown_and_missing_values_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)

  # Unknown arguments
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --unknown 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "Unknown argument: --unknown" || return 1

  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" -x 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "Unknown argument: -x" || return 1

  # Missing values
  missing_val_pairs=(
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
  for opt in "${missing_val_pairs[@]}"; do
    out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" $opt 2>&1)
    test $? -ne 0 || return 1
    opt_name=${opt%=*}
    assert_contains "$out" "Option '$opt_name' requires a non-empty value." || return 1
  done
  return 0
}

# 4. --lang accepts only en and zh-TW
lang_validation_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)

  # Invalid explicit languages
  for invalid_lang in "fr" "zh" "de" "en-US" "zh-CN"; do
    out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --lang "$invalid_lang" 2>&1)
    test $? -ne 0 || return 1
    assert_contains "$out" "Invalid language '$invalid_lang'. Supported: en, zh-TW." || return 1

    out_eq=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" "--lang=$invalid_lang" 2>&1)
    test $? -ne 0 || return 1
    assert_contains "$out_eq" "Invalid language '$invalid_lang'. Supported: en, zh-TW." || return 1
  done

  # Valid explicit languages without --help short-circuit:
  out_en=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --lang en --unknown 2>&1)
  assert_contains "$out_en" "Error: Unknown argument: --unknown" || return 1

  out_zh=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --lang zh-TW --unknown 2>&1)
  assert_contains "$out_zh" "錯誤: 未知的參數：--unknown" || return 1

  out_en_eq=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --lang=en --unknown 2>&1)
  assert_contains "$out_en_eq" "Error: Unknown argument: --unknown" || return 1

  out_zh_eq=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --lang=zh-TW --unknown 2>&1)
  assert_contains "$out_zh_eq" "錯誤: 未知的參數：--unknown" || return 1
  return 0
}

# 5. LC_ALL > LC_MESSAGES > LANG > English fallback
locale_precedence_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)

  # Explicit --lang en overrides zh_TW environment
  out=$(env -i HOME="$test_home" PATH="$fake_bin" LC_ALL="zh_TW.UTF-8" /bin/bash "$SCRIPT" --lang en --unknown 2>&1)
  assert_contains "$out" "Error" || return 1

  # Explicit --lang zh-TW overrides English environment
  out=$(env -i HOME="$test_home" PATH="$fake_bin" LC_ALL="C" /bin/bash "$SCRIPT" --lang zh-TW --unknown 2>&1)
  assert_contains "$out" "錯誤" || return 1

  # LC_ALL overrides LC_MESSAGES and LANG
  out=$(env -i HOME="$test_home" PATH="$fake_bin" LC_ALL="C" LC_MESSAGES="zh_TW.UTF-8" LANG="zh_TW.UTF-8" /bin/bash "$SCRIPT" --unknown 2>&1)
  assert_contains "$out" "Error" || return 1

  # LC_MESSAGES overrides LANG
  out=$(env -i HOME="$test_home" PATH="$fake_bin" LC_ALL="" LC_MESSAGES="zh_TW.UTF-8" LANG="C" /bin/bash "$SCRIPT" --unknown 2>&1)
  assert_contains "$out" "錯誤" || return 1

  # LANG takes effect when LC_ALL and LC_MESSAGES are empty
  out=$(env -i HOME="$test_home" PATH="$fake_bin" LC_ALL="" LC_MESSAGES="" LANG="zh_TW.UTF-8" /bin/bash "$SCRIPT" --unknown 2>&1)
  assert_contains "$out" "錯誤" || return 1

  # Default fallback is English
  out=$(env -i HOME="$test_home" PATH="$fake_bin" LC_ALL="" LC_MESSAGES="" LANG="" /bin/bash "$SCRIPT" --unknown 2>&1)
  assert_contains "$out" "Error" || return 1
  return 0
}

# 6. zh, zh_TW.UTF-8, and zh-Hant select zh-TW text
chinese_locale_variants_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)
  variants=("zh" "zh_TW.UTF-8" "zh-Hant" "zh_CN.UTF-8" "zh_HK")
  for var in "${variants[@]}"; do
    out=$(env -i HOME="$test_home" PATH="$fake_bin" LC_ALL="$var" /bin/bash "$SCRIPT" --unknown 2>&1)
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
  fake_bin=$(make_fake_bin)
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  status=$?
  test "$status" -ne 0 || return 1
  assert_contains "$out" "git" || return 1
  assert_contains "$out" "stow" || return 1
  assert_contains "$out" "fzf" || return 1
  assert_contains "$out" "plutil" || return 1
  return 0
}

# 8. relative, missing, symlinked, unowned, or unwritable HOME fails
home_validation_case() {
  fake_bin=$(make_fake_bin)

  # Relative HOME
  out=$(env -i HOME="relative/home" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "HOME directory is invalid" || return 1

  # Missing HOME
  out=$(env -i HOME="$ROOT/nonexistent_home" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "HOME directory is invalid" || return 1

  # Symlinked HOME
  real_h=$(make_home)
  sym_h="$ROOT/sym_home"
  ln -s "$real_h" "$sym_h"
  out=$(env -i HOME="$sym_h" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "HOME directory is invalid" || return 1

  # Unwritable HOME
  unwritable_h=$(make_home)
  chmod 500 "$unwritable_h"
  out=$(env -i HOME="$unwritable_h" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "HOME directory is invalid" || return 1
  chmod 700 "$unwritable_h"

  # Unowned HOME using root-owned, readable/writable/searchable sticky /private/tmp (reaches owner UID check)
  out=$(env -i HOME="/private/tmp" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "HOME directory is invalid" || return 1
  return 0
}

# 9. existing /private/tmp/kaisian-$UID.lock fails and is never removed
existing_lock_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"

  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    mkdir -m 0700 "$lock_dir" || exit 1
    test_lock_ino=$(/usr/bin/stat -f '%d %i' "$lock_dir" 2>/dev/null)
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_lock_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

    touch "$lock_dir/existing_marker"

    out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "Failed to acquire lock at" || exit 1

    # Verify lock directory and marker are still intact
    test -d "$lock_dir" || exit 1
    test -f "$lock_dir/existing_marker" || exit 1
    exit 0
  ) || return 1
  return 0
}

# 10. runs with different TMPDIR values contend on the same fixed lock
tmpdir_lock_contention_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"

  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    mkdir -m 0700 "$lock_dir" || exit 1
    test_lock_ino=$(/usr/bin/stat -f '%d %i' "$lock_dir" 2>/dev/null)
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_lock_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

    out=$(env -i TMPDIR="$ROOT/custom_tmp" HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "Failed to acquire lock at /private/tmp/kaisian-$uid.lock" || exit 1
    exit 0
  ) || return 1
  return 0
}

# 11. repo-dir/state paths equal to, above, or below the lock fail; sibling paths pass
path_overlap_with_lock_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"

  # Equals lock
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo-dir "$lock_dir" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  # Ancestor of lock (/private/tmp)
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo-dir "/private/tmp" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  # Descendant of lock
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo-dir "$lock_dir/sub" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  # Dot, dotdot, and doubled-slash aliases of lock
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo-dir "/private/tmp/./kaisian-$uid.lock" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo-dir "/private/tmp/kaisian-$uid.lock/../kaisian-$uid.lock" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo-dir "/private/tmp//kaisian-$uid.lock" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  # Symlink + .. alias pointing into sandbox/lock
  symlink_target="$lock_dir/sandbox"
  symlink_path="$ROOT/to-sandbox"
  ln -s "$symlink_target" "$symlink_path"
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo-dir "$symlink_path/.." 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  # State root descendant of lock
  out=$(env -i HOME="$test_home" XDG_STATE_HOME="$lock_dir" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  out=$(env -i HOME="$test_home" XDG_STATE_HOME="$lock_dir/state" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "overlaps with lock or sandbox directory" || return 1

  # Safe sibling state root (XDG_STATE_HOME=/private/tmp -> STATE_ROOT=/private/tmp/kaisian) reaches prerequisite check
  out=$(env -i HOME="$test_home" XDG_STATE_HOME="/private/tmp" PATH="$fake_bin" /bin/bash "$SCRIPT" 2>&1)
  test $? -ne 0 || return 1
  case "$out" in
    *"overlaps with lock"*)
      printf 'Safe XDG_STATE_HOME=/private/tmp incorrectly failed with path overlap: %s\n' "$out" >&2
      return 1
      ;;
  esac
  assert_contains "$out" "Missing required commands" || return 1

  # Sibling repo-dir is valid: reaches prerequisite check without path overlap failure
  sibling_dir="$ROOT/sibling-repo"
  mkdir -p "$sibling_dir"
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo-dir "$sibling_dir" 2>&1)
  test $? -ne 0 || return 1
  case "$out" in
    *"overlaps with lock"*)
      printf 'Sibling repo-dir incorrectly failed with path overlap: %s\n' "$out" >&2
      return 1
      ;;
  esac
  assert_contains "$out" "Missing required commands" || return 1
  return 0
}

# 12. cleanup leaves an unrecognized lock entry untouched
cleanup_leaves_unrecognized_lock_case() {
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"

  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    LOCK_DIR="/private/tmp/kaisian-$uid.lock"
    mkdir -m 0700 "$LOCK_DIR" || exit 1
    test_ino=$(/usr/bin/stat -f '%d %i' "$LOCK_DIR" 2>/dev/null)
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$LOCK_DIR"'" 2>/dev/null || true); if test "$curr" = "'"$test_ino"'"; then rm -rf "'"$LOCK_DIR"'"; fi' EXIT

    SANDBOX="$LOCK_DIR/sandbox"
    mkdir -m 0700 "$SANDBOX" || exit 1
    RECORDED_LOCK_DEV_INO=$(/usr/bin/stat -f '%d %i' "$LOCK_DIR")
    RECORDED_SANDBOX_DEV_INO=$(/usr/bin/stat -f '%d %i' "$SANDBOX")
    touch "$LOCK_DIR/pid"
    touch "$LOCK_DIR/unrecognized_file"

    cleanup

    assert_not_exists "$SANDBOX" || exit 1
    assert_not_exists "$LOCK_DIR/pid" || exit 1
    test -f "$LOCK_DIR/unrecognized_file" || exit 1
    test -d "$LOCK_DIR" || exit 1
    exit 0
  ) || return 1
  return 0
}

# 13. Bilingual message key parity test
message_key_parity_case() {
  (
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
      "invalid_manifest"
      "unknown_profile"
      "unknown_group"
      "empty_group_selection"
      "empty_selection"
      "fzf_failed"
    )
    for key in "${keys[@]}"; do
      en_msg=$(LANGUAGE=en message "$key" "test_arg" "test_arg2") || {
        printf 'message_en failed for key: %s\n' "$key" >&2
        exit 1
      }
      zh_msg=$(LANGUAGE=zh-TW message "$key" "test_arg" "test_arg2") || {
        printf 'message_zh_tw failed for key: %s\n' "$key" >&2
        exit 1
      }
      test -n "$en_msg" || exit 1
      test -n "$zh_msg" || exit 1
    done

    LANGUAGE=en message "unknown_test_key" >/dev/null 2>&1
    test $? -eq 64 || exit 1
    LANGUAGE=zh-TW message "unknown_test_key" >/dev/null 2>&1
    test $? -eq 64 || exit 1
    exit 0
  ) || return 1
  return 0
}

# 14. run_git environment sanitization
run_git_sanitization_case() {
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"
  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    acquire_lock
    test_ino="$RECORDED_LOCK_DEV_INO"
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

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

    # Hostile env script to verify /usr/bin/env immunity
    cat << 'EOF' > "$mock_bin/env"
#!/bin/bash
printf 'HOSTILE_ENV_EXECUTED\n'
exit 1
EOF
    chmod +x "$mock_bin/env"

    out=$(KAISIAN_GIT_EXEC="$mock_bin/git" PATH="$mock_bin:$PATH" GIT_DIR="/hostile/dir" GIT_WORK_TREE="/hostile/wt" GIT_AUTHOR_NAME="hostile" run_git status)
    cleanup

    assert_contains "$out" "HOME=$SANDBOX/git-home" || exit 1
    assert_contains "$out" "LC_ALL=C" || exit 1
    assert_contains "$out" "GIT_CONFIG_NOSYSTEM=1" || exit 1
    assert_contains "$out" "GIT_CONFIG_GLOBAL=/dev/null" || exit 1
    assert_contains "$out" "GIT_ATTR_NOSYSTEM=1" || exit 1
    assert_contains "$out" "GIT_TERMINAL_PROMPT=0" || exit 1
    assert_contains "$out" "GIT_ASKPASS=/usr/bin/false" || exit 1
    assert_contains "$out" "GIT_NO_REPLACE_OBJECTS=1" || exit 1
    assert_contains "$out" "GIT_DIR=unset" || exit 1
    assert_contains "$out" "GIT_WORK_TREE=unset" || exit 1
    assert_contains "$out" "GIT_AUTHOR_NAME=unset" || exit 1

    case "$out" in
      *"HOSTILE_ENV_EXECUTED"*)
        printf 'run_git invoked shadowed bare env!\n' >&2
        exit 1
        ;;
    esac
    exit 0
  ) || return 1
  return 0
}

# 15. run_stow environment sanitization
run_stow_sanitization_case() {
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"
  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    acquire_lock
    test_ino="$RECORDED_LOCK_DEV_INO"
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

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

    out=$(KAISIAN_STOW_EXEC="$mock_bin/stow" STOW_DIR="/hostile/stow" PERL5LIB="/hostile/lib" PERL5OPT="-Mhostile" run_stow --version)
    cleanup

    assert_contains "$out" "CWD=$SANDBOX/stow-cwd" || exit 1
    assert_contains "$out" "HOME=$SANDBOX/stow-home" || exit 1
    assert_contains "$out" "LC_ALL=C" || exit 1
    assert_contains "$out" "STOW_DIR=unset" || exit 1
    assert_contains "$out" "PERL5LIB=unset" || exit 1
    assert_contains "$out" "PERL5OPT=unset" || exit 1
    exit 0
  ) || return 1
  return 0
}

# 16. behavioral stow probes in require_prerequisites and flag enforcement
stow_behavioral_probes_case() {
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"
  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    acquire_lock
    test_ino="$RECORDED_LOCK_DEV_INO"
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

    mock_bin="$ROOT/mock-probe-bin"
    mkdir -p "$mock_bin"

    # Create a behavioral fake stow enforcing --dotfiles, --no-folding, --compat, built-in ignores, --simulate
    cat << 'EOF' > "$mock_bin/stow"
#!/bin/bash
set -u
dir=""
target=""
simulate=0
compat=0
dotfiles=0
no_folding=0
ignore_regex=""
restow_pkgs=""
delete_pkgs=""

while test $# -gt 0; do
  case "$1" in
    -d) dir=$2; shift 2 ;;
    -t) target=$2; shift 2 ;;
    --dotfiles) dotfiles=1; shift ;;
    --no-folding) no_folding=1; shift ;;
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

# Built-in ignores are active when $HOME/.stow-global-ignore is absent;
# empty file disables built-in ignores; nonempty file fails in fake stow.
ignore_file="${HOME-}/.stow-global-ignore"
builtin_ignore=0
if test -z "${HOME-}" || test ! -f "$ignore_file"; then
  builtin_ignore=1
elif test -s "$ignore_file"; then
  printf 'Non-empty .stow-global-ignore is unsupported in fake stow\n' >&2
  exit 1
fi

# Link creation
for pkg in $restow_pkgs; do
  pkg_dir="$dir/$pkg"
  test -d "$pkg_dir" || continue

  # Folding behavior (when no_folding=0)
  if test "$no_folding" -eq 0; then
    for item in "$pkg_dir"/*; do
      test -e "$item" || continue
      iname=${item##*/}
      if test "$builtin_ignore" -eq 1; then
        case "$iname" in
          README*|LICENSE*|COPYING*|'*~'|'#*#') continue ;;
        esac
      fi
      tname="$iname"
      if test "$dotfiles" -eq 1; then
        case "$iname" in
          dot-*) tname=".${iname#dot-}" ;;
        esac
      fi
      ln -sf "$item" "$target/$tname"
    done
  else
    # Non-folding: create directory hierarchy and symlink leaf files
    (
      cd "$pkg_dir"
      find . -type f | while read -r file; do
        rel="${file#./}"
        fname=${rel##*/}
        if test "$builtin_ignore" -eq 1; then
          case "$fname" in
            README*|LICENSE*|COPYING*|'*~'|'#*#') continue ;;
          esac
        fi
        if test -n "$ignore_regex"; then
          if printf '%s\n' "$rel" | grep -Eq "$ignore_regex"; then
            continue
          fi
        fi
        old_ifs=$IFS
        IFS='/'
        set -f
        set -- $rel
        set +f
        IFS=$old_ifs
        transformed=""
        for comp in "$@"; do
          c="$comp"
          if test "$dotfiles" -eq 1; then
            case "$comp" in
              dot-*) c=".${comp#dot-}" ;;
            esac
          fi
          transformed="$transformed/$c"
        done
        tgt_file="$target$transformed"
        mkdir -p "$(dirname "$tgt_file")"
        ln -sf "$pkg_dir/$rel" "$tgt_file"
      done
    )
  fi
done

# Deletion
for pkg in $delete_pkgs; do
  pkg_dir="$dir/$pkg"
  if test "$compat" -eq 1; then
    # Compat deletion: remove all links in target that point to pkg_dir
    if test -d "$target"; then
      (
        cd "$target"
        find . -type l | while read -r link; do
          dest=$(readlink "$link" 2>/dev/null || true)
          case "$dest" in
            "$pkg_dir"/*|"$pkg_dir")
              rm -f "$link"
              ;;
          esac
        done
      )
    fi
  else
    # Non-compat mode: only deletes links for files currently existing in pkg_dir
    if test -d "$pkg_dir"; then
      (
        cd "$pkg_dir"
        find . -type f | while read -r file; do
          rel="${file#./}"
          old_ifs=$IFS
          IFS='/'
          set -f
          set -- $rel
          set +f
          IFS=$old_ifs
          transformed=""
          for comp in "$@"; do
            c="$comp"
            if test "$dotfiles" -eq 1; then
              case "$comp" in
                dot-*) c=".${comp#dot-}" ;;
              esac
            fi
            transformed="$transformed/$c"
          done
          tgt_file="$target$transformed"
          rm -f "$tgt_file"
        done
      )
    fi
  fi
done
exit 0
EOF
    chmod +x "$mock_bin/stow"

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

    KAISIAN_GIT_EXEC="$mock_bin/git" \
    KAISIAN_STOW_EXEC="$mock_bin/stow" \
    PATH="$mock_bin:/usr/bin:/bin" require_prerequisites
    probe_status=$?
    cleanup

    test "$probe_status" -eq 0 || exit 1
    exit 0
  ) || return 1
  return 0
}

# 17. production hook immunity: KAISIAN_* variables and bare env shadowing are ignored in production mode
production_hook_immunity_case() {
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"
  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    acquire_lock
    test_ino="$RECORDED_LOCK_DEV_INO"
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

    mock_bin="$ROOT/mock-evil-bin"
    mkdir -p "$mock_bin"

    # Malicious git, stow, and bare env
    cat << 'EOF' > "$mock_bin/evil_git"
#!/bin/bash
printf 'EVIL_GIT_RAN\n'
exit 1
EOF
    cat << 'EOF' > "$mock_bin/evil_stow"
#!/bin/bash
printf 'EVIL_STOW_RAN\n'
exit 1
EOF
    # Malicious bare env
    cat << 'EOF' > "$mock_bin/env"
#!/bin/bash
printf 'HOSTILE_ENV_EXECUTED\n'
exit 1
EOF
    chmod +x "$mock_bin/evil_git" "$mock_bin/evil_stow" "$mock_bin/env"

    safe_bin="$ROOT/mock-safe-bin"
    mkdir -p "$safe_bin"
    cat << 'EOF' > "$safe_bin/safe_git"
#!/bin/bash
printf 'SAFE_GIT_EXECUTED: %s\n' "$*"
printf 'SAFE_GIT_PATH: %s\n' "$PATH"
exit 0
EOF
    cat << 'EOF' > "$safe_bin/safe_stow"
#!/bin/bash
printf 'SAFE_STOW_EXECUTED: %s\n' "$*"
printf 'SAFE_STOW_PATH: %s\n' "$PATH"
exit 0
EOF
    chmod +x "$safe_bin/safe_git" "$safe_bin/safe_stow"
    GIT_EXEC="$safe_bin/safe_git"
    STOW_EXEC="$safe_bin/safe_stow"

    # Invoke run_git with KAISIAN_TESTING=0 inline
    out_git=$(KAISIAN_TESTING=0 KAISIAN_GIT_EXEC="$mock_bin/evil_git" KAISIAN_RUNNER_PATH="$mock_bin" PATH="$mock_bin:$PATH" run_git status --short)
    assert_contains "$out_git" "SAFE_GIT_EXECUTED: status --short" || exit 1
    assert_contains "$out_git" "SAFE_GIT_PATH: /usr/bin:/bin:/usr/sbin:/sbin" || exit 1
    case "$out_git" in
      *"EVIL_GIT_RAN"*)
        printf 'Production run_git executed KAISIAN_GIT_EXEC override!\n' >&2
        exit 1
        ;;
      *"HOSTILE_ENV_EXECUTED"*)
        printf 'Production run_git invoked shadowed bare env!\n' >&2
        exit 1
        ;;
    esac

    # Invoke run_stow with KAISIAN_TESTING=0 inline
    out_stow=$(KAISIAN_TESTING=0 KAISIAN_STOW_EXEC="$mock_bin/evil_stow" KAISIAN_RUNNER_PATH="$mock_bin" PATH="$mock_bin:$PATH" run_stow --version)
    assert_contains "$out_stow" "SAFE_STOW_EXECUTED: --version" || exit 1
    assert_contains "$out_stow" "SAFE_STOW_PATH: /usr/bin:/bin:/usr/sbin:/sbin" || exit 1
    case "$out_stow" in
      *"EVIL_STOW_RAN"*)
        printf 'Production run_stow executed KAISIAN_STOW_EXEC override!\n' >&2
        exit 1
        ;;
      *"HOSTILE_ENV_EXECUTED"*)
        printf 'Production run_stow invoked shadowed bare env!\n' >&2
        exit 1
        ;;
    esac

    cleanup
    exit 0
  ) || return 1
  return 0
}

# 18. compat probe failure on ignored compat behavior
compat_probe_failure_on_ignored_compat_case() {
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"
  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    acquire_lock
    test_ino="$RECORDED_LOCK_DEV_INO"
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

    mock_bin="$ROOT/mock-nocompat-bin"
    mkdir -p "$mock_bin"

    # Fake stow that IGNORES --compat (does not clean up obsolete source links on -D)
    cat << 'EOF' > "$mock_bin/stow"
#!/bin/bash
set -u
dir=""
target=""
simulate=0
dotfiles=0
no_folding=0
restow_pkgs=""
delete_pkgs=""

while test $# -gt 0; do
  case "$1" in
    -d) dir=$2; shift 2 ;;
    -t) target=$2; shift 2 ;;
    --dotfiles) dotfiles=1; shift ;;
    --no-folding) no_folding=1; shift ;;
    --compat) shift ;;
    --simulate) simulate=1; shift ;;
    --ignore=*) shift ;;
    -R) restow_pkgs="$restow_pkgs $2"; shift 2 ;;
    -D) delete_pkgs="$delete_pkgs $2"; shift 2 ;;
    *) restow_pkgs="$restow_pkgs $1"; shift ;;
  esac
done

if test "$simulate" -eq 1; then
  exit 0
fi

for pkg in $restow_pkgs; do
  pkg_dir="$dir/$pkg"
  test -d "$pkg_dir" || continue
  (
    cd "$pkg_dir"
    find . -type f | while read -r file; do
      rel="${file#./}"
      old_ifs=$IFS
      IFS='/'
      set -f
      set -- $rel
      set +f
      IFS=$old_ifs
      transformed=""
      for comp in "$@"; do
        c="$comp"
        if test "$dotfiles" -eq 1; then
          case "$comp" in
            dot-*) c=".${comp#dot-}" ;;
          esac
        fi
        transformed="$transformed/$c"
      done
      tgt_file="$target$transformed"
      mkdir -p "$(dirname "$tgt_file")"
      ln -sf "$pkg_dir/$rel" "$tgt_file"
    done
  )
done

# Non-compat deletion: leaves deleted files in target untouched
for pkg in $delete_pkgs; do
  pkg_dir="$dir/$pkg"
  if test -d "$pkg_dir"; then
    (
      cd "$pkg_dir"
      find . -type f | while read -r file; do
        rel="${file#./}"
        old_ifs=$IFS
        IFS='/'
        set -f
        set -- $rel
        set +f
        IFS=$old_ifs
        transformed=""
        for comp in "$@"; do
          c="$comp"
          if test "$dotfiles" -eq 1; then
            case "$comp" in
              dot-*) c=".${comp#dot-}" ;;
            esac
          fi
          transformed="$transformed/$c"
        done
        tgt_file="$target$transformed"
        rm -f "$tgt_file"
      done
    )
  fi
done
exit 0
EOF
    chmod +x "$mock_bin/stow"

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

    out=$(KAISIAN_GIT_EXEC="$mock_bin/git" KAISIAN_STOW_EXEC="$mock_bin/stow" PATH="$mock_bin:/usr/bin:/bin" require_prerequisites 2>&1)
    status=$?
    cleanup

    test "$status" -ne 0 || exit 1
    assert_contains "$out" "GNU Stow does not support required behavior" || exit 1
    exit 0
  ) || return 1
  return 0
}

# 19. subshell lock cleanup safety on assertion failure
lock_cleanup_on_subshell_failure_case() {
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"
  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    acquire_lock
    test_ino="$RECORDED_LOCK_DEV_INO"
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

    # Force a test failure / non-zero exit
    exit 1
  ) || true

  # Assert that the lock was cleaned up by the trap and no stale lock was left behind
  test ! -e "$lock_dir" || return 1
  return 0
}

# 20. discover_executable resolves real relative path without calling external which, dirname, or basename
discover_executable_purity_case() {
  test_dir=$(mktemp -d "$ROOT/purity-test.XXXXXX")
  test_dir=$(cd -P "$test_dir" && pwd -P)
  mkdir -p "$test_dir/rel_bin" "$test_dir/rel_evil" "$test_dir/markers"

  # Create real executable probe
  cat << 'EOF' > "$test_dir/rel_bin/probe"
#!/bin/bash
exit 0
EOF
  chmod +x "$test_dir/rel_bin/probe"

  for tool in which dirname basename; do
    cat << EOF > "$test_dir/rel_evil/$tool"
#!/bin/bash
: > "$test_dir/markers/${tool}_ran"
exit 1
EOF
    chmod +x "$test_dir/rel_evil/$tool"
  done

  (
    cd "$test_dir"
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    # Invoke discover_executable with only relative PATH entries
    out=$(PATH="rel_evil:rel_bin" discover_executable probe 2>&1) || exit 1
    test -n "$out" || exit 1
    case "$out" in
      /*) ;;
      *) exit 1 ;;
    esac
    test "$out" = "$test_dir/rel_bin/probe" || exit 1
    test -f "$out" || exit 1
    test -x "$out" || exit 1
    exit 0
  ) || return 1

  # Assert that no hostile marker was created
  assert_not_exists "$test_dir/markers/which_ran" || return 1
  assert_not_exists "$test_dir/markers/dirname_ran" || return 1
  assert_not_exists "$test_dir/markers/basename_ran" || return 1
  return 0
}

# 21. nonempty .stow-global-ignore makes probe fail while empty succeeds
stow_nonempty_ignore_probe_failure_case() {
  uid=$(/usr/bin/id -u)
  lock_dir="/private/tmp/kaisian-$uid.lock"
  if test -e "$lock_dir"; then
    printf 'FAIL: Pre-existing external lock at %s\n' "$lock_dir" >&2
    return 1
  fi

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    acquire_lock
    test_ino="$RECORDED_LOCK_DEV_INO"
    trap 'curr=$(/usr/bin/stat -f "%d %i" "'"$lock_dir"'" 2>/dev/null || true); if test "$curr" = "'"$test_ino"'"; then rm -rf "'"$lock_dir"'"; fi' EXIT

    mock_bin="$ROOT/mock-nonempty-ignore-bin"
    mkdir -p "$mock_bin"

    # Self-contained fake stow enforcing empty global ignore
    cat << 'EOF' > "$mock_bin/stow"
#!/bin/bash
set -u
dir=""
target=""
simulate=0
compat=0
dotfiles=0
no_folding=0
ignore_regex=""
restow_pkgs=""
delete_pkgs=""

while test $# -gt 0; do
  case "$1" in
    -d) dir=$2; shift 2 ;;
    -t) target=$2; shift 2 ;;
    --dotfiles) dotfiles=1; shift ;;
    --no-folding) no_folding=1; shift ;;
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

ignore_file="${HOME-}/.stow-global-ignore"
if test -z "${HOME-}" || test ! -f "$ignore_file"; then
  builtin_ignore=1
elif test -s "$ignore_file"; then
  printf 'Non-empty global ignore is unsupported in fake stow\n' >&2
  exit 1
fi

for pkg in $restow_pkgs; do
  pkg_dir="$dir/$pkg"
  test -d "$pkg_dir" || continue
  (
    cd "$pkg_dir"
    find . -type f | while read -r file; do
      rel="${file#./}"
      old_ifs=$IFS
      IFS='/'
      set -f
      set -- $rel
      set +f
      IFS=$old_ifs
      transformed=""
      for comp in "$@"; do
        c="$comp"
        if test "$dotfiles" -eq 1; then
          case "$comp" in
            dot-*) c=".${comp#dot-}" ;;
          esac
        fi
        transformed="$transformed/$c"
      done
      tgt_file="$target$transformed"
      mkdir -p "$(dirname "$tgt_file")"
      ln -sf "$pkg_dir/$rel" "$tgt_file"
    done
  )
done
exit 0
EOF
    chmod +x "$mock_bin/stow"

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

    # Make .stow-global-ignore non-empty to prove probe fails
    echo "custom_pattern" > "$SANDBOX/stow-home/.stow-global-ignore"

    out=$(KAISIAN_GIT_EXEC="$mock_bin/git" KAISIAN_STOW_EXEC="$mock_bin/stow" PATH="$mock_bin:/usr/bin:/bin" require_prerequisites 2>&1)
    status=$?
    cleanup

    test "$status" -ne 0 || exit 1
    assert_contains "$out" "GNU Stow does not support required behavior" || exit 1
    exit 0
  ) || return 1
  return 0
}

# 22. Valid manifest parsing produces exact groups.tsv and profiles.tsv inside sandbox
manifest_valid_and_tsv_output_case() {
  checkout="$ROOT/checkout_valid"
  mkdir -p "$checkout/shell" "$checkout/git" "$checkout/mise" "$checkout/terminal"
  cp "$(dirname "$SCRIPT")/tests/fixtures/manifest-valid.json" "$checkout/.kaisian.json"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    test -f "$SANDBOX/groups.tsv" || exit 1
    test -f "$SANDBOX/profiles.tsv" || exit 1

    # Test one-argument interface where checkout directory is inferred as '.'
    (
      cd "$checkout" || exit 1
      parse_manifest .kaisian.json || exit 1
      test -f "$SANDBOX/groups.tsv" || exit 1
    ) || exit 1

    expected_groups=$(printf 'shell\tShell configuration\tShell 設定\ngit\tGit configuration\tGit 設定\nmise\tRuntime and tool version management\t執行環境與工具版本管理\nterminal\tTerminal emulator configuration\t終端機模擬器設定\n')
    actual_groups=$(cat "$SANDBOX/groups.tsv")
    test "$actual_groups" = "$expected_groups" || exit 1

    actual_profiles=$(cat "$SANDBOX/profiles.tsv")
    assert_contains "$actual_profiles" "$(printf 'minimal\tshell git')" || exit 1
    assert_contains "$actual_profiles" "$(printf 'default\tshell git mise')" || exit 1
    cleanup
    trap - EXIT
    exit 0
  ) || return 1
  return 0
}

# 23. Invalid manifest syntax, types, schema, and unknown keys fail with localized diagnostic
manifest_invalid_syntax_and_types_case() {
  checkout="$ROOT/checkout_invalid_test"
  mkdir -p "$checkout/shell" "$checkout/git" "$checkout/mise" "$checkout/terminal"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    assert_manifest_fails() {
      json_content=$1
      label=$2
      printf '%s\n' "$json_content" > "$SANDBOX/test_manifest.json"
      out=$(parse_manifest "$SANDBOX/test_manifest.json" "$checkout" 2>&1)
      status=$?
      if test "$status" -eq 0; then
        printf 'Expected manifest to fail for %s but it passed\n' "$label" >&2
        return 1
      fi
      assert_contains "$out" "Invalid manifest" || {
        printf 'Output missing "Invalid manifest" for %s: %s\n' "$label" "$out" >&2
        return 1
      }
      return 0
    }

    # 1. Malformed JSON syntax
    assert_manifest_fails '{ "schema": 1, ' 'malformed json' || exit 1

    # 2. Root not object
    assert_manifest_fails '[1, 2, 3]' 'root array' || exit 1

    # 3. Schema string
    assert_manifest_fails '{"schema": "1", "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}]}' 'schema string' || exit 1

    # 4. Schema float
    assert_manifest_fails '{"schema": 1.5, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}]}' 'schema float' || exit 1

    # 5. Schema unsupported version
    assert_manifest_fails '{"schema": 2, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}]}' 'schema version 2' || exit 1

    # 6. Groups not array
    assert_manifest_fails '{"schema": 1, "groups": {}}' 'groups object' || exit 1

    # 7. Groups empty array
    assert_manifest_fails '{"schema": 1, "groups": []}' 'groups empty array' || exit 1

    # 8. Group item not object
    assert_manifest_fails '{"schema": 1, "groups": ["shell"]}' 'group item string' || exit 1

    # 9. Group missing name
    assert_manifest_fails '{"schema": 1, "groups": [{"description": {"en": "e", "zh-TW": "z"}}]}' 'group missing name' || exit 1

    # 10. Group missing description
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell"}]}' 'group missing description' || exit 1

    # 11. Group invalid name uppercase
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "Shell", "description": {"en": "e", "zh-TW": "z"}}]}' 'group name uppercase' || exit 1

    # 12. Group invalid name leading digit
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "1shell", "description": {"en": "e", "zh-TW": "z"}}]}' 'group name leading digit' || exit 1

    # 13. Group invalid name leading dash
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "-shell", "description": {"en": "e", "zh-TW": "z"}}]}' 'group name leading dash' || exit 1

    # 14. Group invalid name with space
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell group", "description": {"en": "e", "zh-TW": "z"}}]}' 'group name with space' || exit 1

    # 15. Duplicate group name
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e1", "zh-TW": "z1"}}, {"name": "shell", "description": {"en": "e2", "zh-TW": "z2"}}]}' 'duplicate group name' || exit 1

    # 16. Unknown group key
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}, "extra_key": true}]}' 'unknown group key' || exit 1

    # 17. Group description not object
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": "some text"}]}' 'description string' || exit 1

    # 18. Group description missing en
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"zh-TW": "z"}}]}' 'description missing en' || exit 1

    # 19. Group description missing zh-TW
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e"}}]}' 'description missing zh-TW' || exit 1

    # 20. Group description unknown key
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z", "fr": "f"}}]}' 'description unknown key' || exit 1

    # 21. Group description empty en
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "", "zh-TW": "z"}}]}' 'description empty en' || exit 1

    # 22. Group description empty zh-TW
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": ""}}]}' 'description empty zh-TW' || exit 1

    # 23. Group description with tab
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "has\ttab", "zh-TW": "z"}}]}' 'description with tab' || exit 1

    # 24. Group description with newline
    assert_manifest_fails "{\"schema\": 1, \"groups\": [{\"name\": \"shell\", \"description\": {\"en\": \"has\nnewline\", \"zh-TW\": \"z\"}}]}" 'description with newline' || exit 1

    # 25. Group description with control character
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "has\u0007bell", "zh-TW": "z"}}]}' 'description with control char' || exit 1

    # 26. Unknown top-level key
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}], "unknown_key": 123}' 'unknown top key' || exit 1

    # 27. Profiles not object
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}], "profiles": ["shell"]}' 'profiles array' || exit 1

    # 28. Profile item not array
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}], "profiles": {"minimal": "shell"}}' 'profile item string' || exit 1

    # 29. Profile item empty array
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}], "profiles": {"minimal": []}}' 'profile item empty' || exit 1

    # 30. Profile item invalid name
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}], "profiles": {"Profile1": ["shell"]}}' 'profile item uppercase' || exit 1

    # 31. Profile references unknown group
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}], "profiles": {"minimal": ["unknown_pkg"]}}' 'profile unknown group' || exit 1

    # 32. Profile contains duplicate group
    assert_manifest_fails '{"schema": 1, "groups": [{"name": "shell", "description": {"en": "e", "zh-TW": "z"}}], "profiles": {"minimal": ["shell", "shell"]}}' 'profile duplicate group' || exit 1

    # 33. Trailing newline in description
    assert_manifest_fails "{\"schema\": 1, \"groups\": [{\"name\": \"shell\", \"description\": {\"en\": \"trailing\\n\", \"zh-TW\": \"z\"}}]}" 'trailing newline in description' || exit 1

    # 34. Delimiter-bearing top key
    assert_manifest_fails "{\"schema\": 1, \"groups\": [{\"name\": \"shell\", \"description\": {\"en\": \"e\", \"zh-TW\": \"z\"}}], \"schema\\ngroups\": true}" 'newline in top key' || exit 1

    # 35. Delimiter-bearing group key
    assert_manifest_fails "{\"schema\": 1, \"groups\": [{\"name\": \"shell\", \"description\": {\"en\": \"e\", \"zh-TW\": \"z\"}, \"name\\ndescription\": true}]}" 'newline in group key' || exit 1

    # 36. Delimiter-bearing description key
    assert_manifest_fails "{\"schema\": 1, \"groups\": [{\"name\": \"shell\", \"description\": {\"en\": \"e\", \"zh-TW\": \"z\", \"en\\nzh-TW\": true}}]}" 'newline in desc key' || exit 1

    # 37. Delimiter-bearing profile key
    assert_manifest_fails "{\"schema\": 1, \"groups\": [{\"name\": \"shell\", \"description\": {\"en\": \"e\", \"zh-TW\": \"z\"}}], \"profiles\": {\"minimal\\ndefault\": [\"shell\"]}}" 'newline in profile key' || exit 1

    # 38. Localized zh-TW failure reason contains no hardcoded English reason
    printf '{"schema": 1, "groups": {}}\n' > "$SANDBOX/test_manifest_zh.json"
    out_zh=$(LANGUAGE='zh-TW' parse_manifest "$SANDBOX/test_manifest_zh.json" "$checkout" 2>&1)
    assert_contains "$out_zh" "無效的 manifest：「groups」必須是陣列。" || exit 1
    ! assert_contains "$out_zh" "array" || exit 1
    ! assert_contains "$out_zh" "Invalid" || exit 1
    cleanup
    trap - EXIT
    exit 0
  ) || return 1
  return 0
}

# 24. Package directory alignment: non-hidden root directories must match declared groups exactly
manifest_package_directory_alignment_case() {
  checkout="$ROOT/checkout_alignment_test"
  mkdir -p "$checkout/shell" "$checkout/git"

  cat << 'EOF' > "$checkout/.kaisian.json"
{
  "schema": 1,
  "groups": [
    {
      "name": "shell",
      "description": { "en": "Shell", "zh-TW": "Shell" }
    },
    {
      "name": "git",
      "description": { "en": "Git", "zh-TW": "Git" }
    }
  ]
}
EOF

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    # 1. Matching directories pass
    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # 2. Regular non-hidden files like README.md and hidden dirs like .git pass
    echo 'hello' > "$checkout/README.md"
    mkdir -p "$checkout/.git"
    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # 3. Missing package directory fails
    rmdir "$checkout/git"
    out=$(parse_manifest "$checkout/.kaisian.json" "$checkout" 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "Invalid manifest" || exit 1
    mkdir -p "$checkout/git"

    # 4. Undeclared non-hidden package directory fails
    mkdir -p "$checkout/extra_pkg"
    out=$(parse_manifest "$checkout/.kaisian.json" "$checkout" 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "Invalid manifest" || exit 1
    rmdir "$checkout/extra_pkg"

    # 5. Symlinked package directory fails
    rmdir "$checkout/git"
    ln -s "$checkout/shell" "$checkout/git"
    out=$(parse_manifest "$checkout/.kaisian.json" "$checkout" 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "Invalid manifest" || exit 1

    cleanup
    trap - EXIT
    exit 0
  ) || return 1
  return 0
}

# 25. Documented plutil last-duplicate-key behavior
manifest_plutil_duplicate_key_behavior_case() {
  checkout="$ROOT/checkout_dup_key_test"
  mkdir -p "$checkout/shell"

  # Duplicate schema key: plutil collapses to last value
  cat << 'EOF' > "$checkout/.kaisian.json"
{
  "schema": 2,
  "schema": 1,
  "groups": [
    {
      "name": "shell",
      "description": {
        "en": "Old description",
        "en": "New description",
        "zh-TW": "Shell 設定"
      }
    }
  ]
}
EOF

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # Description should be the last collapsed value "New description"
    expected_groups=$(printf 'shell\tNew description\tShell 設定\n')
    actual_groups=$(cat "$SANDBOX/groups.tsv")
    test "$actual_groups" = "$expected_groups" || exit 1

    cleanup
    trap - EXIT
    exit 0
  ) || return 1
  return 0
}

# 26. Default (no flag) and --all resolve all packages in manifest order
selection_default_and_all_case() {
  checkout="$ROOT/checkout_sel_all"
  mkdir -p "$checkout/shell" "$checkout/git" "$checkout/mise" "$checkout/terminal"
  cp "$(dirname "$SCRIPT")/tests/fixtures/manifest-valid.json" "$checkout/.kaisian.json"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # 1. No flag (SELECTION_MODE='none')
    SELECTION_MODE='none' SELECTION_VALUE='' resolve_selection || exit 1
    expected_selected=$(printf 'shell\ngit\nmise\nterminal\n')
    actual_selected=$(cat "$SANDBOX/selected.txt")
    test "$actual_selected" = "$expected_selected" || exit 1
    test ! -s "$SANDBOX/unselected.txt" || exit 1

    # 2. --all (SELECTION_MODE='all')
    SELECTION_MODE='all' SELECTION_VALUE='' resolve_selection || exit 1
    actual_selected=$(cat "$SANDBOX/selected.txt")
    test "$actual_selected" = "$expected_selected" || exit 1
    test ! -s "$SANDBOX/unselected.txt" || exit 1

    cleanup
    trap - EXIT
    exit 0
  ) || return 1
  return 0
}

# 27. --profile selects profile packages in manifest order; unknown profile fails
selection_profile_case() {
  checkout="$ROOT/checkout_sel_prof"
  mkdir -p "$checkout/shell" "$checkout/git" "$checkout/mise" "$checkout/terminal"
  cp "$(dirname "$SCRIPT")/tests/fixtures/manifest-valid.json" "$checkout/.kaisian.json"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # 1. --profile minimal => shell git
    SELECTION_MODE='profile' SELECTION_VALUE='minimal' resolve_selection || exit 1
    expected_selected=$(printf 'shell\ngit\n')
    expected_unselected=$(printf 'mise\nterminal\n')
    test "$(cat "$SANDBOX/selected.txt")" = "$expected_selected" || exit 1
    test "$(cat "$SANDBOX/unselected.txt")" = "$expected_unselected" || exit 1

    # 2. --profile default => shell git mise
    SELECTION_MODE='profile' SELECTION_VALUE='default' resolve_selection || exit 1
    expected_selected=$(printf 'shell\ngit\nmise\n')
    expected_unselected=$(printf 'terminal\n')
    test "$(cat "$SANDBOX/selected.txt")" = "$expected_selected" || exit 1
    test "$(cat "$SANDBOX/unselected.txt")" = "$expected_unselected" || exit 1

    # 3. Unknown profile fails with diagnostic
    out=$(SELECTION_MODE='profile' SELECTION_VALUE='nonexistent' resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "Unknown profile" || exit 1

    cleanup
    trap - EXIT
    exit 0
  ) || return 1
  return 0
}

# 28. --groups parses comma list, trims whitespace, deduplicates, and resolves in manifest order
selection_groups_case() {
  checkout="$ROOT/checkout_sel_grp"
  mkdir -p "$checkout/shell" "$checkout/git" "$checkout/mise" "$checkout/terminal"
  cp "$(dirname "$SCRIPT")/tests/fixtures/manifest-valid.json" "$checkout/.kaisian.json"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # 1. 'terminal, shell,terminal' => shell terminal (manifest order)
    SELECTION_MODE='groups' SELECTION_VALUE='terminal, shell,terminal' resolve_selection || exit 1
    expected_selected=$(printf 'shell\nterminal\n')
    expected_unselected=$(printf 'git\nmise\n')
    test "$(cat "$SANDBOX/selected.txt")" = "$expected_selected" || exit 1
    test "$(cat "$SANDBOX/unselected.txt")" = "$expected_unselected" || exit 1

    # 2. 'git, mise' => git mise
    SELECTION_MODE='groups' SELECTION_VALUE='git, mise' resolve_selection || exit 1
    expected_selected=$(printf 'git\nmise\n')
    expected_unselected=$(printf 'shell\nterminal\n')
    test "$(cat "$SANDBOX/selected.txt")" = "$expected_selected" || exit 1
    test "$(cat "$SANDBOX/unselected.txt")" = "$expected_unselected" || exit 1

    # 3. Trailing comma fails
    out=$(SELECTION_MODE='groups' SELECTION_VALUE='terminal,' resolve_selection 2>&1)
    test $? -ne 0 || exit 1
    assert_contains "$out" "Group selection cannot be empty" || exit 1

    # 4. Leading comma fails
    out=$(SELECTION_MODE='groups' SELECTION_VALUE=',shell' resolve_selection 2>&1)
    test $? -ne 0 || exit 1
    assert_contains "$out" "Group selection cannot be empty" || exit 1

    # 5. Empty / whitespace fails
    out=$(SELECTION_MODE='groups' SELECTION_VALUE='   ' resolve_selection 2>&1)
    test $? -ne 0 || exit 1
    assert_contains "$out" "Group selection cannot be empty" || exit 1

    # 6. Unknown group fails
    out=$(SELECTION_MODE='groups' SELECTION_VALUE='shell, nonexistent' resolve_selection 2>&1)
    test $? -ne 0 || exit 1
    assert_contains "$out" "Unknown group" || exit 1

    cleanup
    trap - EXIT
    exit 0
  ) || return 1
  return 0
}

# 29. Interactive fzf selection, cancellation, localization, and error semantics
selection_interactive_fzf_case() {
  checkout="$ROOT/checkout_sel_fzf"
  mkdir -p "$checkout/shell" "$checkout/git" "$checkout/mise" "$checkout/terminal"
  cp "$(dirname "$SCRIPT")/tests/fixtures/manifest-valid.json" "$checkout/.kaisian.json"

  fzf_mock_dir=$(mktemp -d "$ROOT/fzfmock.XXXXXX")

  # 1 & 2. Normal selection and localized candidate checks
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # 1. Normal fzf output 'git\nterminal' => git terminal (in manifest order)
    cat << 'EOF' > "$fzf_mock_dir/fzf_normal"
#!/bin/bash
test "$1" = '--multi' || exit 1
test "$2" = '--with-nth=1,2' || exit 1
cat > /dev/null
printf 'git\tGit configuration\nterminal\tTerminal emulator configuration\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_normal"

    SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_normal" resolve_selection || exit 1
    expected_selected=$(printf 'git\nterminal\n')
    expected_unselected=$(printf 'shell\nmise\n')
    test "$(cat "$SANDBOX/selected.txt")" = "$expected_selected" || exit 1
    test "$(cat "$SANDBOX/unselected.txt")" = "$expected_unselected" || exit 1

    # 2. Localized candidates check for zh-TW
    cat << EOF > "$fzf_mock_dir/fzf_capture"
#!/bin/bash
cat > "$SANDBOX/captured_candidates.txt"
printf 'shell\tShell 設定\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_capture"

    LANGUAGE='zh-TW' SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_capture" resolve_selection || exit 1
    captured=$(cat "$SANDBOX/captured_candidates.txt")
    assert_contains "$captured" "Shell 設定" || exit 1
    assert_contains "$captured" "Git 設定" || exit 1
    assert_contains "$captured" "執行環境與工具版本管理" || exit 1

    cleanup
    trap - EXIT
    exit 0
  ) || return 1

  # 3. fzf Esc / Ctrl-C (exit 130) => clean zero exit before target mutation in nested subshell
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # Preseed sentinels outside sandbox in test root / home
    echo 'sentinel_selected' > "$test_home/sentinel_selected.txt"
    echo 'sentinel_unselected' > "$test_home/sentinel_unselected.txt"
    echo 'sentinel_target' > "$test_home/target_leaf"

    cat << 'EOF' > "$fzf_mock_dir/fzf_130"
#!/bin/bash
exit 130
EOF
    chmod +x "$fzf_mock_dir/fzf_130"

    # Invoke in nested subshell
    (
      SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_130" resolve_selection
    )
    cancellation_status=$?

    # Assert status is 0 from enclosing test process
    test "$cancellation_status" -eq 0 || exit 1

    # Assert lock cleanup ran
    test ! -d "$LOCK_DIR" || exit 1

    # Assert sentinels outside sandbox are intact and unchanged
    test "$(cat "$test_home/sentinel_selected.txt")" = 'sentinel_selected' || exit 1
    test "$(cat "$test_home/sentinel_unselected.txt")" = 'sentinel_unselected' || exit 1
    test "$(cat "$test_home/target_leaf")" = 'sentinel_target' || exit 1
    exit 0
  ) || return 1

  # 4, 5, 6, 7, 8. Empty selection, error status, bogus records, and non-TTY error checks
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    test_home=$(make_home)
    HOME="$test_home"
    acquire_lock || exit 1
    trap 'cleanup' EXIT

    parse_manifest "$checkout/.kaisian.json" "$checkout" || exit 1

    # 4. Confirmed empty selection => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_empty"
#!/bin/bash
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_empty"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_empty" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "No packages selected" || exit 1

    # 5. Unexpected fzf failure (e.g. exit 2) => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_err"
#!/bin/bash
exit 2
EOF
    chmod +x "$fzf_mock_dir/fzf_err"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_err" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 6. Bogus unknown record in fzf output => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_bogus"
#!/bin/bash
printf 'nonexistent_package\tSome desc\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_bogus"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_bogus" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 7. Mixed valid + bogus record in fzf output => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_mixed"
#!/bin/bash
printf 'shell\tShell config\nunknown_pkg\tUnknown\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_mixed"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_mixed" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 8. Non-TTY interactive => localized nonzero
    out=$(LANGUAGE='en' SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=0 resolve_selection 2>&1)
    test $? -ne 0 || exit 1
    assert_contains "$out" "A controlling terminal is required" || exit 1

    out_zh=$(LANGUAGE='zh-TW' SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=0 resolve_selection 2>&1)
    test $? -ne 0 || exit 1
    assert_contains "$out_zh" "此操作需要可控制的終端機" || exit 1

    cleanup
    trap - EXIT
    exit 0
  ) || return 1
  return 0
}

run_case 'valid manifest parsing produces exact groups.tsv and profiles.tsv' manifest_valid_and_tsv_output_case
run_case 'invalid manifest syntax, types, schema, and unknown keys fail' manifest_invalid_syntax_and_types_case
run_case 'package directory alignment matches declared groups exactly' manifest_package_directory_alignment_case
run_case 'documented plutil last-duplicate-key behavior' manifest_plutil_duplicate_key_behavior_case
run_case 'default (no flag) and --all resolve all packages in manifest order' selection_default_and_all_case
run_case '--profile selects profile packages in manifest order' selection_profile_case
run_case '--groups parses comma list, trims whitespace, deduplicates, and resolves in manifest order' selection_groups_case
run_case 'interactive fzf selection, cancellation, localization, and error semantics' selection_interactive_fzf_case

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
run_case 'production runner hook immunity' production_hook_immunity_case
run_case 'compat probe failure on ignored compat behavior' compat_probe_failure_on_ignored_compat_case
run_case 'subshell lock cleanup safety on assertion failure' lock_cleanup_on_subshell_failure_case
run_case 'discover_executable does not execute external which, dirname, or basename from PATH' discover_executable_purity_case
run_case 'nonempty .stow-global-ignore makes probe fail while empty succeeds' stow_nonempty_ignore_probe_failure_case

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
