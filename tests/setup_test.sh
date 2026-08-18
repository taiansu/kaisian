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

# Built-in ignores are active when $HOME/.stow-global-ignore is absent
ignore_file="${HOME-}/.stow-global-ignore"
builtin_ignore=0
has_custom_ignores=0
if test -z "${HOME-}" || test ! -f "$ignore_file"; then
  builtin_ignore=1
elif test -s "$ignore_file"; then
  has_custom_ignores=1
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
      if test "$has_custom_ignores" -eq 1; then
        matched=0
        while read -r pattern; do
          test -n "$pattern" || continue
          case "$pattern" in
            \#*) continue ;;
          esac
          case "$iname" in
            $pattern) matched=1; break ;;
          esac
        done < "$ignore_file"
        if test "$matched" -eq 1; then
          continue
        fi
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
        if test "$has_custom_ignores" -eq 1; then
          matched=0
          while read -r pattern; do
            test -n "$pattern" || continue
            case "$pattern" in
              \#*) continue ;;
            esac
            case "$fname" in
              $pattern) matched=1; break ;;
            esac
          done < "$ignore_file"
          if test "$matched" -eq 1; then
            continue
          fi
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

# 20. discover_executable does not execute external which, dirname, or basename from PATH
discover_executable_purity_case() {
  test_dir=$(mktemp -d "$ROOT/purity-test.XXXXXX")
  test_dir=$(cd -P "$test_dir" && pwd -P)
  mkdir -p "$test_dir/rel_evil" "$test_dir/markers"

  for tool in which dirname basename; do
    cat << EOF > "$test_dir/rel_evil/$tool"
#!/bin/bash
touch "$test_dir/markers/${tool}_ran"
exit 1
EOF
    chmod +x "$test_dir/rel_evil/$tool"
  done

  (
    cd "$test_dir"
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    out=$(PATH="rel_evil:$PATH" discover_executable git 2>&1) || exit 1
    test -n "$out" || exit 1
    case "$out" in
      /*) ;;
      *) exit 1 ;;
    esac
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

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
