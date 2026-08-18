#!/bin/bash
set -u

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kaisian-test.XXXXXX") || exit 1
ROOT=$(cd -P "$ROOT" && pwd -P)
trap 'rm -rf -- "$ROOT"' EXIT HUP INT TERM
SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/setup.sh
TRACE_LOG="$(cd "$(dirname "$0")" && pwd -P)/tmp/last-command-trace.log"
/bin/mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
: > "$TRACE_LOG"
export KAISIAN_GIT_TRACE_LOG="$TRACE_LOG"
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
make_behavioral_mock_stow() {
  local mock_bin="$1"
  /bin/mkdir -p "$mock_bin"
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
builtin_ignore=0
if test -z "${HOME-}" || test ! -f "$ignore_file"; then
  builtin_ignore=1
elif test -s "$ignore_file"; then
  printf 'Non-empty .stow-global-ignore is unsupported in fake stow\n' >&2
  exit 1
fi

for pkg in $restow_pkgs; do
  pkg_dir="$dir/$pkg"
  test -d "$pkg_dir" || continue

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

for pkg in $delete_pkgs; do
  pkg_dir="$dir/$pkg"
  if test "$compat" -eq 1; then
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
      "invalid_repository"
      "custom_repo_requires_ref"
      "invalid_ref"
      "ambiguous_ref"
      "ref_not_found"
      "invalid_git_config"
      "invalid_git_admin"
      "dirty_checkout"
      "invalid_submodule"
      "submodule_failed"
      "git_operation_failed"
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

    # 39. Path required error in en and zh-TW
    out_path_en=$(LANGUAGE='en' parse_manifest "" "$checkout" 2>&1)
    assert_contains "$out_path_en" "manifest path is required" || exit 1
    out_path_zh=$(LANGUAGE='zh-TW' parse_manifest "" "$checkout" 2>&1)
    assert_contains "$out_path_zh" "必須提供 manifest 路徑" || exit 1
    ! assert_contains "$out_path_zh" "required" || exit 1

    # 40. Checkout directory not found error in en and zh-TW
    echo '{"schema": 1, "groups": []}' > "$checkout/.kaisian.json"
    out_dir_zh=$(LANGUAGE='zh-TW' parse_manifest "$checkout/.kaisian.json" "/nonexistent_dir_999" 2>&1)
    assert_contains "$out_dir_zh" "找不到檢出目錄「/nonexistent_dir_999」。" || exit 1
    ! assert_contains "$out_dir_zh" "checkout directory" || exit 1
    rm -f "$checkout/.kaisian.json"
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

    # 6. Bogus unknown record in fzf output (no tab) => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_unknown"
#!/bin/bash
printf 'nonexistent_package\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_unknown"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_unknown" resolve_selection 2>&1)
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
    # 8. Space-separated record 'shell git' in fzf output => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_space_separated"
#!/bin/bash
printf 'shell git\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_space_separated"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_space_separated" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 9. Padded leading/trailing whitespace record in fzf output => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_padded"
#!/bin/bash
printf '  shell\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_padded"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_padded" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 10. Tab-malformed record in fzf output => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_tab_malformed"
#!/bin/bash
printf '\tmalformed_tab\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_tab_malformed"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_tab_malformed" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 11. Wrong description in fzf output => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_wrong_desc"
#!/bin/bash
printf 'shell\tbogus description\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_wrong_desc"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_wrong_desc" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 12. Empty description suffix 'shell\t' in fzf output => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_empty_suffix"
#!/bin/bash
printf 'shell\t\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_empty_suffix"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_empty_suffix" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 13. Extra tab in fzf output record => nonzero
    cat << 'EOF' > "$fzf_mock_dir/fzf_extra_tab"
#!/bin/bash
printf 'shell\tShell configuration\textra\n'
exit 0
EOF
    chmod +x "$fzf_mock_dir/fzf_extra_tab"

    out=$(SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_extra_tab" resolve_selection 2>&1)
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "fzf interactive selection failed" || exit 1

    # 14. Localized zh-TW fzf unknown record diagnostic without English words
    out_fzf_zh=$(LANGUAGE='zh-TW' SELECTION_MODE='interactive' KAISIAN_TESTING_TTY=1 KAISIAN_FZF_EXEC="$fzf_mock_dir/fzf_unknown" resolve_selection 2>&1)
    test $? -ne 0 || exit 1
    assert_contains "$out_fzf_zh" "fzf 互動選取失敗：輸出包含未知的紀錄「nonexistent_package」。" || exit 1
    ! assert_contains "$out_fzf_zh" "failed" || exit 1
    ! assert_contains "$out_fzf_zh" "unknown record" || exit 1
    # 12. Non-TTY interactive => localized nonzero
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

# -----------------------------------------------------------------------------
# Task 4 Test Cases: Source & Ref Acquisition, Config/Admin & Submodules
# -----------------------------------------------------------------------------

FIXTURES_DIR="$(cd "$(dirname "$SCRIPT")/tests/fixtures" && pwd -P)"
FAKE_GIT="$FIXTURES_DIR/fake-git"

make_remote_repo() {
  repo_dir=$(mktemp -d "$ROOT/remote.XXXXXX")
  (
    cd -P "$repo_dir" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    mkdir -p shell git mise .vendor/helper
    printf 'zshrc\n' > shell/dot-zshrc
    printf 'gitconfig\n' > git/dot-gitconfig
    printf 'miseconfig\n' > mise/dot-config
    cat << 'JSON' > .kaisian.json
{
  "schema": 1,
  "groups": [
    { "name": "shell", "description": { "en": "Shell", "zh-TW": "Shell" } },
    { "name": "git", "description": { "en": "Git", "zh-TW": "Git" } },
    { "name": "mise", "description": { "en": "Mise", "zh-TW": "Mise" } }
  ],
  "profiles": { "minimal": ["shell", "git", "mise"] }
}
JSON
    git add .
    git commit -q -m "initial commit"
    git branch -M main
  )
  (cd -P "$repo_dir" && pwd -P)
}

source_canonicalization_matrix_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    # Valid normalizations
    test "$(canonicalize_repository 'taiansu/dotfiles')" = "https://github.com/taiansu/dotfiles" || exit 1
    test "$(canonicalize_repository 'https://github.com/taiansu/dotfiles')" = "https://github.com/taiansu/dotfiles" || exit 1
    test "$(canonicalize_repository 'https://github.com/taiansu/dotfiles.git')" = "https://github.com/taiansu/dotfiles" || exit 1
    test "$(canonicalize_repository 'https://github.com/taiansu/dotfiles/')" = "https://github.com/taiansu/dotfiles" || exit 1
    test "$(canonicalize_repository 'https://github.com/taiansu/dotfiles.git/')" = "https://github.com/taiansu/dotfiles" || exit 1
    test "$(canonicalize_repository 'https://GITHUB.COM/taiansu/dotfiles')" = "https://github.com/taiansu/dotfiles" || exit 1
    test "$(canonicalize_repository 'https://gitlab.com/group/subgroup/repo.git')" = "https://gitlab.com/group/subgroup/repo" || exit 1

    # Invalid sources that must be rejected
    invalid_sources=(
      "https://user:pass@github.com/repo"
      "https://user@github.com/repo"
      "git@github.com:user/repo"
      "ssh://git@github.com/user/repo"
      "file:///path/to/repo"
      "ext::sh -c evil"
      "/path/to/repo"
      "https://github.com/user/測試"
      "https://github.com:443/user/repo"
      "https://github.com/user/%20"
      "https://github.com/user/repo?foo=bar"
      "https://github.com/user/repo#main"
      "https://github.com//user/repo"
      "https://github.com/user/../repo"
      "https://github.com/user/./repo"
      "https://github.com/-option"
      "-oOption"
      "https://github.com/user/repo:refs/heads/main"
      "https://github.com/"
      "owner"
      "owner/"
      "/repo"
      ""
    )
    for src in "${invalid_sources[@]}"; do
      if ( canonicalize_repository "$src" ) >/dev/null 2>&1; then
        printf 'Failed to reject invalid repository source: %s\n' "$src" >&2
        exit 1
      fi
    done
    exit 0
  ) || return 1
  return 0
}

custom_repo_requires_ref_case() {
  test_home=$(make_home)
  fake_bin=$(make_fake_bin)

  # 1. Custom repo without --ref fails
  out=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --repo someone/dotfiles 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out" "specifying a custom --repo requires an explicit --ref" || return 1

  # 2. Localized zh-TW failure
  out_zh=$(env -i HOME="$test_home" PATH="$fake_bin" /bin/bash "$SCRIPT" --lang zh-TW --repo someone/dotfiles 2>&1)
  test $? -ne 0 || return 1
  assert_contains "$out_zh" "指定自訂 --repo 時必須一併指定明確的 --ref" || return 1

  return 0
}

origin_ref_resolution_and_ambiguity_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    (
      cd "$remote_repo" || exit 1
      git checkout -q -b feature
      printf 'feature\n' > feature.txt
      git add feature.txt
      git commit -q -m "feature commit"
      git tag -a -m "annotated tag v2.0" v2.0
      git tag v1.0
      # Create ambiguity: release is both a branch and a tag
      git branch release
      git tag release
      git checkout -q main
    )

    trace_log="$TRACE_LOG"
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_GIT_TRACE_LOG="$trace_log"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock

    # 1. Remote HEAD resolves
    REQUESTED_REF="HEAD"
    resolve_remote_ref
    test "$RESOLVED_FETCH_REF" = "HEAD" || exit 1
    test -n "$EXPECTED_COMMIT_SHA" || exit 1

    # 2. Full branch ref
    REQUESTED_REF="refs/heads/feature"
    resolve_remote_ref
    test "$RESOLVED_FETCH_REF" = "refs/heads/feature" || exit 1

    # 3. Full tag ref (annotated tag peels to commit)
    REQUESTED_REF="refs/tags/v2.0"
    resolve_remote_ref
    test "$RESOLVED_FETCH_REF" = "refs/tags/v2.0" || exit 1
    peeled_sha=$(git -C "$remote_repo" rev-parse "refs/tags/v2.0^{commit}")
    test "$EXPECTED_COMMIT_SHA" = "$peeled_sha" || exit 1

    # 4. Unambiguous shorthand branch
    REQUESTED_REF="feature"
    resolve_remote_ref
    test "$RESOLVED_FETCH_REF" = "refs/heads/feature" || exit 1

    # 5. Unambiguous shorthand tag
    REQUESTED_REF="v1.0"
    resolve_remote_ref
    test "$RESOLVED_FETCH_REF" = "refs/tags/v1.0" || exit 1

    # 6. Ambiguous shorthand (exists as branch AND tag) MUST reject
    REQUESTED_REF="release"
    if ( resolve_remote_ref ) >/dev/null 2>&1; then
      printf 'Expected resolve_remote_ref to fail on ambiguous shorthand\n' >&2
      exit 1
    fi

    # 7. Nonexistent ref MUST reject
    REQUESTED_REF="nonexistent_branch_xyz"
    if ( resolve_remote_ref ) >/dev/null 2>&1; then
      printf 'Expected resolve_remote_ref to fail on nonexistent ref\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

fetched_object_pinning_beats_malicious_local_refs_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    origin_commit=$(git -C "$remote_repo" rev-parse HEAD)

    checkout_dir=$(mktemp -d "$ROOT/checkout.XXXXXX")
    (
      cd "$checkout_dir" || exit 1
      git init -q
      git config remote.origin.url "https://github.com/taiansu/dotfiles"
      git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
      printf 'evil\n' > evil.txt
      git add evil.txt
      git -c user.email="attacker@example.com" -c user.name="Attacker" commit -q -m "malicious local commit"
      # Malicious local branch and tag named main
      git branch -M main
      git tag -f main
    )

    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"
    trace_log="$TRACE_LOG"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    CHECKOUT_DIR="$checkout_dir"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_GIT_TRACE_LOG="$trace_log"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref
    (cd "$checkout_dir" && rm -f evil.txt && git -c user.email="attacker@example.com" -c user.name="Attacker" commit -q -a -m "clean")
    update_repository "$checkout_dir"

    # Assert checkout is at origin_commit, not malicious local commit
    actual_head=$(git -C "$checkout_dir" rev-parse HEAD)
    test "$actual_head" = "$origin_commit" || exit 1

    cleanup
    exit 0
  ) || return 1
  return 0
}

new_checkout_uses_init_and_single_fetch_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    origin_commit=$(git -C "$remote_repo" rev-parse HEAD)

    checkout_dir="$ROOT/new-checkout-$(date +%s)-$RANDOM"
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"
    trace_log="$TRACE_LOG"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    CHECKOUT_DIR="$checkout_dir"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_GIT_TRACE_LOG="$trace_log"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref
    initialize_repository "$checkout_dir"

    test -d "$checkout_dir/.git" || exit 1
    actual_head=$(git -C "$checkout_dir" rev-parse HEAD)
    test "$actual_head" = "$origin_commit" || exit 1

    # No local branch created (HEAD is detached)
    local_branches=$(git -C "$checkout_dir" for-each-ref --format='%(refname)' refs/heads/)
    test -z "$local_branches" || exit 1

    cleanup
    exit 0
  ) || return 1
  return 0
}

existing_checkout_cleanliness_and_origin_mismatch_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. Origin URL mismatch
    checkout_mismatch=$(mktemp -d "$ROOT/chk-mismatch.XXXXXX")
    initialize_repository "$checkout_mismatch" || exit 1
    git -C "$checkout_mismatch" config remote.origin.url "https://github.com/other/repo"
    if ( validate_git_config "$checkout_mismatch" ) >/dev/null 2>&1; then
      printf 'Expected origin mismatch to fail\n' >&2
      exit 1
    fi

    # 2. Dirty tracked file
    checkout_dirty=$(mktemp -d "$ROOT/chk-dirty.XXXXXX")
    initialize_repository "$checkout_dirty" || exit 1
    printf 'modified\n' >> "$checkout_dirty/shell/dot-zshrc"
    if ( verify_clean_tree "$checkout_dirty" ) >/dev/null 2>&1; then
      printf 'Expected dirty tracked file to fail clean tree check\n' >&2
      exit 1
    fi

    # 3. Untracked file
    checkout_untracked=$(mktemp -d "$ROOT/chk-untracked.XXXXXX")
    initialize_repository "$checkout_untracked" || exit 1
    printf 'untracked\n' > "$checkout_untracked/untracked.txt"
    if ( verify_clean_tree "$checkout_untracked" ) >/dev/null 2>&1; then
      printf 'Expected untracked file to fail clean tree check\n' >&2
      exit 1
    fi

    # 4. Ignored file
    checkout_ignored=$(mktemp -d "$ROOT/chk-ignored.XXXXXX")
    initialize_repository "$checkout_ignored" || exit 1
    printf '.ignored\n' > "$checkout_ignored/.gitignore"
    (cd "$checkout_ignored" && git add .gitignore && git commit -q -m "add gitignore")
    printf 'ignored\n' > "$checkout_ignored/.ignored"
    if ( verify_clean_tree "$checkout_ignored" ) >/dev/null 2>&1; then
      printf 'Expected ignored file to fail clean tree check\n' >&2
      exit 1
    fi

    # 5. In-progress operation markers
    checkout_op=$(mktemp -d "$ROOT/chk-op.XXXXXX")
    initialize_repository "$checkout_op" || exit 1
    touch "$checkout_op/.git/MERGE_HEAD"
    if ( validate_git_admin "$checkout_op" ) >/dev/null 2>&1; then
      printf 'Expected MERGE_HEAD to fail admin validation\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

git_config_allowlist_and_hostile_configs_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    checkout_base=$(mktemp -d "$ROOT/chk-cfg.XXXXXX")
    initialize_repository "$checkout_base" || exit 1

    # Allowed config passes
    validate_git_config "$checkout_base" || exit 1

    # Test hostile config keys:
    hostile_configs=(
      "core.worktree=/tmp"
      "core.symlinks=false"
      "core.hookspath=/tmp/hooks"
      "core.fsmonitor=true"
      "core.unknownkey=value"
      "include.path=/tmp/evil.inc"
      "url.git@github.com:.insteadOf=https://github.com/"
      "filter.evil.clean=cat"
      "diff.evil.command=sh"
      "remote.upstream.url=https://github.com/other/repo"
      "remote.origin.fetch=+refs/heads/*:refs/remotes/evil/*"
      "branch.main.rebase=true"
    )

    for cfg in "${hostile_configs[@]}"; do
      key="${cfg%%=*}"
      val="${cfg#*=}"
      chk=$(mktemp -d "$ROOT/chk-cfg-sub.XXXXXX")
      initialize_repository "$chk" || exit 1
      git -C "$chk" config --local "$key" "$val" 2>/dev/null || printf '\n[%s]\n\t%s = %s\n' "${key%%.*}" "${key#*.}" "$val" >> "$chk/.git/config"
      if ( validate_git_config "$chk" ) >/dev/null 2>&1; then
        printf 'Failed to reject hostile git config: %s\n' "$cfg" >&2
        exit 1
      fi
    done

    cleanup
    exit 0
  ) || return 1
  return 0
}

git_admin_boundaries_and_replacements_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. Replacement refs
    chk_replace=$(mktemp -d "$ROOT/chk-rep.XXXXXX")
    initialize_repository "$chk_replace" || exit 1
    mkdir -p "$chk_replace/.git/refs/replace"
    touch "$chk_replace/.git/refs/replace/1234567890123456789012345678901234567890"
    if ( validate_git_admin "$chk_replace" ) >/dev/null 2>&1; then
      printf 'Expected replace refs to fail admin validation\n' >&2
      exit 1
    fi

    # 2. Grafts
    chk_graft=$(mktemp -d "$ROOT/chk-graft.XXXXXX")
    initialize_repository "$chk_graft" || exit 1
    mkdir -p "$chk_graft/.git/info"
    touch "$chk_graft/.git/info/grafts"
    if ( validate_git_admin "$chk_graft" ) >/dev/null 2>&1; then
      printf 'Expected info/grafts to fail admin validation\n' >&2
      exit 1
    fi

    # 3. Info attributes
    chk_attr=$(mktemp -d "$ROOT/chk-attr.XXXXXX")
    initialize_repository "$chk_attr" || exit 1
    mkdir -p "$chk_attr/.git/info"
    touch "$chk_attr/.git/info/attributes"
    if ( validate_git_admin "$chk_attr" ) >/dev/null 2>&1; then
      printf 'Expected info/attributes to fail admin validation\n' >&2
      exit 1
    fi

    # 4. Alternates
    chk_alt=$(mktemp -d "$ROOT/chk-alt.XXXXXX")
    initialize_repository "$chk_alt" || exit 1
    mkdir -p "$chk_alt/.git/objects/info"
    touch "$chk_alt/.git/objects/info/alternates"
    if ( validate_git_admin "$chk_alt" ) >/dev/null 2>&1; then
      printf 'Expected alternates to fail admin validation\n' >&2
      exit 1
    fi

    # 5. Linked worktree (.git is a file)
    chk_wt=$(mktemp -d "$ROOT/chk-wt.XXXXXX")
    mkdir -p "$chk_wt"
    printf 'gitdir: /tmp/other.git\n' > "$chk_wt/.git"
    if ( validate_git_admin "$chk_wt" ) >/dev/null 2>&1; then
      printf 'Expected linked worktree (.git file) to fail admin validation\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

fresh_index_defeats_hidden_worktree_modifications_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. assume-unchanged modified file
    chk_assume=$(mktemp -d "$ROOT/chk-assume.XXXXXX")
    initialize_repository "$chk_assume" || exit 1
    printf 'tampered\n' >> "$chk_assume/shell/dot-zshrc"
    git -C "$chk_assume" update-index --assume-unchanged shell/dot-zshrc
    if ( verify_clean_tree "$chk_assume" ) >/dev/null 2>&1; then
      printf 'Expected assume-unchanged modification to be caught by fresh index verification\n' >&2
      exit 1
    fi

    # 2. skip-worktree modified file
    chk_skip=$(mktemp -d "$ROOT/chk-skip.XXXXXX")
    initialize_repository "$chk_skip" || exit 1
    printf 'tampered\n' >> "$chk_skip/shell/dot-zshrc"
    git -C "$chk_skip" update-index --skip-worktree shell/dot-zshrc
    if ( verify_clean_tree "$chk_skip" ) >/dev/null 2>&1; then
      printf 'Expected skip-worktree modification to be caught by fresh index verification\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

staged_submodules_validation_and_containment_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    subm_repo=$(make_remote_repo)
    subm_commit=$(git -C "$subm_repo" rev-parse HEAD)

    remote_repo=$(make_remote_repo)
    (
      cd "$remote_repo" || exit 1
      git config -f .gitmodules submodule.helper.path ".vendor/helper"
      git config -f .gitmodules submodule.helper.url "https://github.com/taiansu/helper"
      git update-index --add --cacheinfo 160000,"$subm_commit",.vendor/helper
      git add .gitmodules
      git commit -q -m "add submodule helper"
    )

    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"
    printf 'https://github.com/taiansu/helper=%s\n' "$subm_repo" >> "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. Valid submodule initializes into embedded child .git
    chk_valid=$(mktemp -d "$ROOT/chk-subm-valid.XXXXXX")
    initialize_repository "$chk_valid" || exit 1

    test -d "$chk_valid/.vendor/helper/.git" || exit 1
    test ! -L "$chk_valid/.vendor/helper/.git" || exit 1
    test ! -f "$chk_valid/.vendor/helper/.git" || exit 1
    sub_head=$(git -C "$chk_valid/.vendor/helper" rev-parse HEAD)
    test "$sub_head" = "$subm_commit" || exit 1

    # 2. Hostile submodule definitions
    # 2a. Relative URL
    repo_rel=$(make_remote_repo)
    (
      cd "$repo_rel" || exit 1
      git config -f .gitmodules submodule.evil.path ".vendor/evil"
      git config -f .gitmodules submodule.evil.url "../evil.git"
      git update-index --add --cacheinfo 160000,"$subm_commit",.vendor/evil
      git add .gitmodules && git commit -q -m "bad sub"
    )
    printf 'https://github.com/taiansu/rel=%s\n' "$repo_rel" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/rel"
    resolve_remote_ref
    chk_bad=$(mktemp -d "$ROOT/chk-bad-rel.XXXXXX")
    if ( initialize_repository "$chk_bad" ) >/dev/null 2>&1; then
      printf 'Expected relative submodule URL to fail\n' >&2
      exit 1
    fi

    # 2b. Submodule inside selectable package (e.g. shell/sub)
    repo_pkg=$(make_remote_repo)
    (
      cd "$repo_pkg" || exit 1
      git config -f .gitmodules submodule.evil.path "shell/sub"
      git config -f .gitmodules submodule.evil.url "https://github.com/taiansu/helper"
      git update-index --add --cacheinfo 160000,"$subm_commit",shell/sub
      git add .gitmodules && git commit -q -m "bad sub inside package"
    )
    printf 'https://github.com/taiansu/pkg=%s\n' "$repo_pkg" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/pkg"
    resolve_remote_ref
    chk_bad_pkg=$(mktemp -d "$ROOT/chk-bad-pkg.XXXXXX")
    if ( initialize_repository "$chk_bad_pkg" ) >/dev/null 2>&1; then
      printf 'Expected submodule inside package directory to fail\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

command_trace_forbidden_operations_case() {
  local trace_log="tests/tmp/last-command-trace.log"
  test -f "$trace_log" || return 1
  test -s "$trace_log" || return 1
  if /usr/bin/grep -Eq -- 'reset --hard|clean -f|stash|submodule update --recursive' "$trace_log"; then
    printf 'Forbidden destructive command found in trace log!\n' >&2
    return 1
  fi
  return 0
}

unadvertised_40_hex_sha_rejection_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    trace_log="$TRACE_LOG"
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_GIT_TRACE_LOG="$trace_log"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    # Unadvertised valid 40-hex SHA must be rejected before fetch
    REQUESTED_REF="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    if ( resolve_remote_ref ) >/dev/null 2>&1; then
      printf 'Expected unadvertised 40-hex SHA to be rejected\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

existing_non_repo_and_origin_fetch_counts_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. Existing non-repo directory (no .git)
    chk_nonrepo=$(mktemp -d "$ROOT/chk-nonrepo.XXXXXX")
    if ( validate_git_admin "$chk_nonrepo" ) >/dev/null 2>&1; then
      printf 'Expected existing non-repo directory to fail admin validation\n' >&2
      exit 1
    fi

    # 2. Missing remote.origin.fetch
    chk_nofetch=$(mktemp -d "$ROOT/chk-nofetch.XXXXXX")
    initialize_repository "$chk_nofetch" || exit 1
    git -C "$chk_nofetch" config --local --unset remote.origin.fetch
    if ( validate_git_config "$chk_nofetch" ) >/dev/null 2>&1; then
      printf 'Expected missing remote.origin.fetch to fail\n' >&2
      exit 1
    fi

    # 3. Duplicate remote.origin.url
    chk_dupurl=$(mktemp -d "$ROOT/chk-dupurl.XXXXXX")
    initialize_repository "$chk_dupurl" || exit 1
    git -C "$chk_dupurl" config --local --add remote.origin.url "https://github.com/taiansu/dotfiles"
    if ( validate_git_config "$chk_dupurl" ) >/dev/null 2>&1; then
      printf 'Expected duplicate remote.origin.url to fail\n' >&2
      exit 1
    fi

    # 4. Duplicate remote.origin.fetch
    chk_dupfetch=$(mktemp -d "$ROOT/chk-dupfetch.XXXXXX")
    initialize_repository "$chk_dupfetch" || exit 1
    git -C "$chk_dupfetch" config --local --add remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    if ( validate_git_config "$chk_dupfetch" ) >/dev/null 2>&1; then
      printf 'Expected duplicate remote.origin.fetch to fail\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

admin_nested_symlinks_and_active_hooks_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. Nested symlink in .git/objects/pack
    chk_sym_obj=$(mktemp -d "$ROOT/chk-symobj.XXXXXX")
    initialize_repository "$chk_sym_obj" || exit 1
    mkdir -p "$chk_sym_obj/.git/objects/pack"
    ln -s "/tmp" "$chk_sym_obj/.git/objects/pack/evil_link"
    if ( validate_git_admin "$chk_sym_obj" ) >/dev/null 2>&1; then
      printf 'Expected nested symlink in objects/pack to fail admin validation\n' >&2
      exit 1
    fi

    # 2. Nested symlink in .git/refs/heads/foo
    chk_sym_ref=$(mktemp -d "$ROOT/chk-symref.XXXXXX")
    initialize_repository "$chk_sym_ref" || exit 1
    mkdir -p "$chk_sym_ref/.git/refs/heads"
    ln -s "/tmp" "$chk_sym_ref/.git/refs/heads/evil_ref"
    if ( validate_git_admin "$chk_sym_ref" ) >/dev/null 2>&1; then
      printf 'Expected nested symlink in refs/heads to fail admin validation\n' >&2
      exit 1
    fi

    # 3. Active non-sample hook in .git/hooks/pre-commit
    chk_hook=$(mktemp -d "$ROOT/chk-hook.XXXXXX")
    initialize_repository "$chk_hook" || exit 1
    mkdir -p "$chk_hook/.git/hooks"
    printf '#!/bin/sh\nexit 0\n' > "$chk_hook/.git/hooks/pre-commit"
    chmod +x "$chk_hook/.git/hooks/pre-commit"
    if ( validate_git_admin "$chk_hook" ) >/dev/null 2>&1; then
      printf 'Expected active git hook to fail admin validation\n' >&2
      exit 1
    fi

    # 4. Sample hook passes
    rm -f "$chk_hook/.git/hooks/pre-commit"
    printf '#!/bin/sh\nexit 0\n' > "$chk_hook/.git/hooks/pre-commit.sample"
    validate_git_admin "$chk_hook" || exit 1

    cleanup
    exit 0
  ) || return 1
  return 0
}

worktree_leaf_hash_and_crlf_attribute_hiding_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. Attribute hiding CRLF tampering
    chk_crlf=$(mktemp -d "$ROOT/chk-crlf.XXXXXX")
    initialize_repository "$chk_crlf" || exit 1
    # Add .gitattributes text=auto and rewrite shell/dot-zshrc with CRLF
    printf '* text=auto\n' > "$chk_crlf/.gitattributes"
    (cd "$chk_crlf" && git add .gitattributes && git -c user.email="t@e.com" -c user.name="T" commit -q -m "attrs")
    printf 'zshrc\r\n' > "$chk_crlf/shell/dot-zshrc"
    if ( verify_clean_tree "$chk_crlf" ) >/dev/null 2>&1; then
      printf 'Expected CRLF modified leaf to be caught by direct blob hash comparison\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

submodule_matrix_and_nested_levels_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    subm_lvl2=$(make_remote_repo)
    subm_lvl2_sha=$(git -C "$subm_lvl2" rev-parse HEAD)

    subm_lvl1=$(make_remote_repo)
    (
      cd "$subm_lvl1" || exit 1
      git config -f .gitmodules submodule.nested.path ".vendor/nested"
      git config -f .gitmodules submodule.nested.url "https://github.com/taiansu/nested"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/nested
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "nested subm"
    )
    subm_lvl1_sha=$(git -C "$subm_lvl1" rev-parse HEAD)

    remote_repo=$(make_remote_repo)
    (
      cd "$remote_repo" || exit 1
      git config -f .gitmodules submodule.helper.path ".vendor/helper"
      git config -f .gitmodules submodule.helper.url "https://github.com/taiansu/helper"
      git update-index --add --cacheinfo 160000,"$subm_lvl1_sha",.vendor/helper
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "subm lvl1"
    )

    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"
    printf 'https://github.com/taiansu/helper=%s\n' "$subm_lvl1" >> "$map_file"
    printf 'https://github.com/taiansu/nested=%s\n' "$subm_lvl2" >> "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. Multi-level nested submodule initialization
    chk_nested=$(mktemp -d "$ROOT/chk-nested.XXXXXX")
    initialize_repository "$chk_nested" || exit 1

    test -d "$chk_nested/.vendor/helper/.git" || exit 1
    test -d "$chk_nested/.vendor/helper/.vendor/nested/.git" || exit 1
    lvl2_head=$(git -C "$chk_nested/.vendor/helper/.vendor/nested" rev-parse HEAD)
    test "$lvl2_head" = "$subm_lvl2_sha" || exit 1

    # 2. Hostile submodule definitions:
    # 2a. SSH URL
    repo_ssh=$(make_remote_repo)
    (
      cd "$repo_ssh" || exit 1
      git config -f .gitmodules submodule.bad.path ".vendor/bad"
      git config -f .gitmodules submodule.bad.url "git@github.com:bad/bad.git"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/bad
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad ssh"
    )
    printf 'https://github.com/taiansu/ssh=%s\n' "$repo_ssh" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/ssh"
    resolve_remote_ref
    chk_bad=$(mktemp -d "$ROOT/chk-bad-ssh.XXXXXX")
    if ( initialize_repository "$chk_bad" ) >/dev/null 2>&1; then
      printf 'Expected SSH submodule URL to fail\n' >&2
      exit 1
    fi

    # 2b. Overlapping submodule paths (.vendor/a and .vendor/a/b)
    repo_overlap=$(make_remote_repo)
    (
      cd "$repo_overlap" || exit 1
      git config -f .gitmodules submodule.a.path ".vendor/a"
      git config -f .gitmodules submodule.a.url "https://github.com/taiansu/nested"
      git config -f .gitmodules submodule.ab.path ".vendor/a/b"
      git config -f .gitmodules submodule.ab.url "https://github.com/taiansu/nested"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/a
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad overlap"
    )
    printf 'https://github.com/taiansu/overlap=%s\n' "$repo_overlap" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/overlap"
    resolve_remote_ref
    chk_bad_ov=$(mktemp -d "$ROOT/chk-bad-ov.XXXXXX")
    if ( initialize_repository "$chk_bad_ov" ) >/dev/null 2>&1; then
      printf 'Expected overlapping submodule paths to fail\n' >&2
      exit 1
    fi

    # 2c. Command update mode
    repo_cmd=$(make_remote_repo)
    (
      cd "$repo_cmd" || exit 1
      git config -f .gitmodules submodule.cmd.path ".vendor/cmd"
      git config -f .gitmodules submodule.cmd.url "https://github.com/taiansu/nested"
      git config -f .gitmodules submodule.cmd.update "!calc"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/cmd
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad cmd"
    )
    printf 'https://github.com/taiansu/cmd=%s\n' "$repo_cmd" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/cmd"
    resolve_remote_ref
    chk_bad_cmd=$(mktemp -d "$ROOT/chk-bad-cmd.XXXXXX")
    if ( initialize_repository "$chk_bad_cmd" ) >/dev/null 2>&1; then
      printf 'Expected command update mode to fail\n' >&2
      exit 1
    fi

    # 2d. Non-checkout update mode (e.g. merge)
    repo_merge=$(make_remote_repo)
    (
      cd "$repo_merge" || exit 1
      git config -f .gitmodules submodule.merge.path ".vendor/merge"
      git config -f .gitmodules submodule.merge.url "https://github.com/taiansu/nested"
      git config -f .gitmodules submodule.merge.update "merge"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/merge
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad update merge"
    )
    printf 'https://github.com/taiansu/merge=%s\n' "$repo_merge" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/merge"
    resolve_remote_ref
    chk_bad_merge=$(mktemp -d "$ROOT/chk-bad-merge.XXXXXX")
    if ( initialize_repository "$chk_bad_merge" ) >/dev/null 2>&1; then
      printf 'Expected non-checkout update mode to fail\n' >&2
      exit 1
    fi

    # 2e. Duplicate submodule paths
    repo_dup=$(make_remote_repo)
    (
      cd "$repo_dup" || exit 1
      git config -f .gitmodules submodule.sub1.path ".vendor/dup"
      git config -f .gitmodules submodule.sub1.url "https://github.com/taiansu/nested"
      git config -f .gitmodules submodule.sub2.path ".vendor/dup"
      git config -f .gitmodules submodule.sub2.url "https://github.com/taiansu/nested"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/dup
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad duplicate path"
    )
    printf 'https://github.com/taiansu/dup=%s\n' "$repo_dup" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/dup"
    resolve_remote_ref
    chk_bad_dup=$(mktemp -d "$ROOT/chk-bad-dup.XXXXXX")
    if ( initialize_repository "$chk_bad_dup" ) >/dev/null 2>&1; then
      printf 'Expected duplicate submodule path to fail\n' >&2
      exit 1
    fi
    # 2f. File submodule URL
    repo_file=$(make_remote_repo)
    (
      cd "$repo_file" || exit 1
      git config -f .gitmodules submodule.f.path ".vendor/file"
      git config -f .gitmodules submodule.f.url "file:///path/to/repo"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/file
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad file url"
    )
    printf 'https://github.com/taiansu/file=%s\n' "$repo_file" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/file"
    resolve_remote_ref
    chk_bad_file=$(mktemp -d "$ROOT/chk-bad-file.XXXXXX")
    if ( initialize_repository "$chk_bad_file" ) >/dev/null 2>&1; then
      printf 'Expected file:// submodule URL to fail\n' >&2
      exit 1
    fi

    # 2g. Ext submodule URL
    repo_ext=$(make_remote_repo)
    (
      cd "$repo_ext" || exit 1
      git config -f .gitmodules submodule.e.path ".vendor/ext"
      git config -f .gitmodules submodule.e.url "ext::sh -c evil"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/ext
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad ext url"
    )
    printf 'https://github.com/taiansu/ext=%s\n' "$repo_ext" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/ext"
    resolve_remote_ref
    chk_bad_ext=$(mktemp -d "$ROOT/chk-bad-ext.XXXXXX")
    if ( initialize_repository "$chk_bad_ext" ) >/dev/null 2>&1; then
      printf 'Expected ext:: submodule URL to fail\n' >&2
      exit 1
    fi

    # 2h. Unknown submodule key (e.g. branch)
    repo_unk=$(make_remote_repo)
    (
      cd "$repo_unk" || exit 1
      git config -f .gitmodules submodule.u.path ".vendor/u"
      git config -f .gitmodules submodule.u.url "https://github.com/taiansu/nested"
      git config -f .gitmodules submodule.u.branch "main"
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/u
      git add .gitmodules && git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad unknown key"
    )
    printf 'https://github.com/taiansu/unk=%s\n' "$repo_unk" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/unk"
    resolve_remote_ref
    chk_bad_unk=$(mktemp -d "$ROOT/chk-bad-unk.XXXXXX")
    if ( initialize_repository "$chk_bad_unk" ) >/dev/null 2>&1; then
      printf 'Expected unknown submodule key to fail\n' >&2
      exit 1
    fi

    # 2i. Pre-existing non-repo child path with sentinel file
    chk_sentinel=$(mktemp -d "$ROOT/chk-sentinel.XXXXXX")
    mkdir -p "$chk_sentinel/.vendor/helper"
    printf 'sentinel_data\n' > "$chk_sentinel/.vendor/helper/sentinel.txt"
    REPOSITORY="taiansu/dotfiles"
    resolve_remote_ref
    if ( initialize_repository "$chk_sentinel" ) >/dev/null 2>&1; then
      printf 'Expected pre-existing non-repo child path to fail\n' >&2
      exit 1
    fi
    test -f "$chk_sentinel/.vendor/helper/sentinel.txt" || exit 1
    test "$(/bin/cat "$chk_sentinel/.vendor/helper/sentinel.txt")" = "sentinel_data" || exit 1

    # 2j. Wrong existing child submodule commit rejected without mutation
    chk_wrong_child=$(mktemp -d "$ROOT/chk-wrongchild.XXXXXX")
    initialize_repository "$chk_wrong_child" || exit 1
    (
      cd "$chk_wrong_child/.vendor/helper" || exit 1
      printf 'wrong\n' > wrong.txt
      git add wrong.txt
      git -c user.email="t@e.com" -c user.name="T" commit -q -m "wrong commit"
    )
    tampered_child_sha=$(git -C "$chk_wrong_child/.vendor/helper" rev-parse HEAD)
    if ( update_repository "$chk_wrong_child" ) >/dev/null 2>&1; then
      printf 'Expected wrong child commit to fail update\n' >&2
      exit 1
    fi
    # Assert child HEAD and files are unchanged
    test "$(git -C "$chk_wrong_child/.vendor/helper" rev-parse HEAD)" = "$tampered_child_sha" || exit 1
    test -f "$chk_wrong_child/.vendor/helper/wrong.txt" || exit 1

    # 2k. Gitlink in tree without .gitmodules
    repo_nogm=$(make_remote_repo)
    (
      cd "$repo_nogm" || exit 1
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/helper
      git -c user.email="t@e.com" -c user.name="T" commit -q -m "gitlink without .gitmodules"
    )
    printf 'https://github.com/taiansu/nogm=%s\n' "$repo_nogm" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/nogm"
    resolve_remote_ref
    chk_nogm=$(mktemp -d "$ROOT/chk-nogm.XXXXXX")
    if ( initialize_repository "$chk_nogm" ) >/dev/null 2>&1; then
      printf 'Expected gitlink without .gitmodules to fail\n' >&2
      exit 1
    fi

    # 2l. Orphan definition in .gitmodules without gitlink in tree
    repo_orphan=$(make_remote_repo)
    (
      cd "$repo_orphan" || exit 1
      git config -f .gitmodules submodule.orphan.path ".vendor/orphan"
      git config -f .gitmodules submodule.orphan.url "https://github.com/taiansu/nested"
      git add .gitmodules
      git -c user.email="t@e.com" -c user.name="T" commit -q -m "orphan .gitmodules definition"
    )
    printf 'https://github.com/taiansu/orphan=%s\n' "$repo_orphan" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/orphan"
    resolve_remote_ref
    chk_orphan=$(mktemp -d "$ROOT/chk-orphan.XXXXXX")
    if ( initialize_repository "$chk_orphan" ) >/dev/null 2>&1; then
      printf 'Expected orphan .gitmodules definition without gitlink to fail\n' >&2
      exit 1
    fi

    # 2m. Bad submodule path grammar cases
    bad_paths=(
      ".vendor/my sub"
      $'.vendor/my\tsub'
      $'.vendor/my\nsub'
      '.vendor\helper'
      '.vendor/helper*'
      '.vendor/helper?'
      '.vendor/[a]'
      '.vendor/./helper'
      '.vendor/helper/'
      '/.vendor/helper'
      '.vendor//helper'
      '.vendor/hel:per'
    )
    for bp in "${bad_paths[@]}"; do
      repo_bp=$(make_remote_repo)
      (
        cd "$repo_bp" || exit 1
        git config -f .gitmodules submodule.badp.path "$bp"
        git config -f .gitmodules submodule.badp.url "https://github.com/taiansu/nested"
        git add .gitmodules
        git -c user.email="t@e.com" -c user.name="T" commit -q -m "bad path"
      )
      printf 'https://github.com/taiansu/badp=%s\n' "$repo_bp" >> "$map_file"
      REPOSITORY="https://github.com/taiansu/badp"
      resolve_remote_ref
      chk_badp=$(mktemp -d "$ROOT/chk-badp.XXXXXX")
      if ( initialize_repository "$chk_badp" ) >/dev/null 2>&1; then
        printf 'Expected bad submodule path grammar to fail: %q\n' "$bp" >&2
        exit 1
      fi
    done

    cleanup
    exit 0
  ) || return 1
  return 0
}

fetch_head_substituted_mismatch_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # Tamper EXPECTED_COMMIT_SHA to simulate remote branch moving / substitution
    EXPECTED_COMMIT_SHA="1111111111111111111111111111111111111111"
    chk_subst=$(mktemp -d "$ROOT/chk-subst.XXXXXX")
    if ( initialize_repository "$chk_subst" ) >/dev/null 2>&1; then
      printf 'Expected FETCH_HEAD mismatch against EXPECTED_COMMIT_SHA to fail\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

worktree_bidirectional_mode_check_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    (
      cd "$remote_repo" || exit 1
      printf '#!/bin/sh\nexit 0\n' > exec_script.sh
      chmod +x exec_script.sh
      printf 'text\n' > normal_text.txt
      chmod -x normal_text.txt
      git add exec_script.sh normal_text.txt
      git -c user.email="t@e.com" -c user.name="T" commit -q -m "modes test"
    )

    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    # 1. 100644 mode tampered to 755 (chmod +x)
    chk_tamper_exec=$(mktemp -d "$ROOT/chk-tamper1.XXXXXX")
    initialize_repository "$chk_tamper_exec" || exit 1
    chmod +x "$chk_tamper_exec/normal_text.txt"
    if ( verify_clean_tree "$chk_tamper_exec" ) >/dev/null 2>&1; then
      printf 'Expected 100644 leaf with chmod +x to fail bidirectional mode check\n' >&2
      exit 1
    fi

    # 2. 100755 mode tampered to 644 (chmod -x)
    chk_tamper_noexec=$(mktemp -d "$ROOT/chk-tamper2.XXXXXX")
    initialize_repository "$chk_tamper_noexec" || exit 1
    chmod -x "$chk_tamper_noexec/exec_script.sh"
    if ( verify_clean_tree "$chk_tamper_noexec" ) >/dev/null 2>&1; then
      printf 'Expected 100755 leaf with chmod -x to fail bidirectional mode check\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}

single_fetch_and_trace_assertions_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    trace_log="$ROOT/trace-single-fetch.log"
    : > "$trace_log"
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_GIT_TRACE_LOG="$trace_log"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref
    chk_single=$(mktemp -d "$ROOT/chk-single.XXXXXX")
    initialize_repository "$chk_single" || exit 1

    # Assert trace log is non-empty
    test -s "$trace_log" || exit 1

    # Assert trace log contains complete escaped environment boundary
    /usr/bin/grep -Fq 'ENV: HOME=' "$trace_log" || exit 1
    /usr/bin/grep -Fq 'GIT_CONFIG_NOSYSTEM=1' "$trace_log" || exit 1
    /usr/bin/grep -Fq 'GIT_CONFIG_GLOBAL=' "$trace_log" || exit 1
    /usr/bin/grep -Fq 'GIT_ATTR_NOSYSTEM=1' "$trace_log" || exit 1
    /usr/bin/grep -Fq 'GIT_TERMINAL_PROMPT=0' "$trace_log" || exit 1
    /usr/bin/grep -Fq 'GIT_ASKPASS=' "$trace_log" || exit 1
    /usr/bin/grep -Fq 'GIT_NO_REPLACE_OBJECTS=1' "$trace_log" || exit 1
    /usr/bin/grep -Fq 'GIT_ALLOW_PROTOCOL=https' "$trace_log" || exit 1

    # Assert exactly ONE fetch command was executed
    fetch_lines=$(/usr/bin/grep -E '^git (-C [^ ]+ )?fetch ' "$trace_log" || true)
    fetch_count=$(printf '%s\n' "$fetch_lines" | /usr/bin/grep -c '^git ' || true)
    test "$fetch_count" -eq 1 || exit 1

    # Assert fetch line has exact canonical URL and resolved ref
    assert_contains "$fetch_lines" "$CANONICAL_REPO" || exit 1
    assert_contains "$fetch_lines" "$RESOLVED_FETCH_REF" || exit 1

    # Assert no refs/heads or refs/remotes created
    test -z "$(git -C "$chk_single" for-each-ref refs/heads/ refs/remotes/ 2>/dev/null)" || exit 1

    cleanup
    exit 0
  ) || return 1
  return 0
}

legitimate_submodule_advancement_c1_to_c2_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    subm_repo=$(make_remote_repo)
    c1_sha=$(git -C "$subm_repo" rev-parse HEAD)

    remote_repo=$(make_remote_repo)
    (
      cd "$remote_repo" || exit 1
      git config -f .gitmodules submodule.helper.path ".vendor/helper"
      git config -f .gitmodules submodule.helper.url "https://github.com/taiansu/helper"
      git update-index --add --cacheinfo 160000,"$c1_sha",.vendor/helper
      git add .gitmodules
      git -c user.email="t@e.com" -c user.name="T" commit -q -m "parent with C1"
    )

    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"
    printf 'https://github.com/taiansu/helper=%s\n' "$subm_repo" >> "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    chk_advance=$(mktemp -d "$ROOT/chk-advance.XXXXXX")
    initialize_repository "$chk_advance" || exit 1

    # Verify initial checkout has C1
    c1_actual=$(git -C "$chk_advance/.vendor/helper" rev-parse HEAD)
    test "$c1_actual" = "$c1_sha" || exit 1

    # Now advance submodule in remote to C2
    (
      cd "$subm_repo" || exit 1
      printf 'feature2\n' > feature2.txt
      git add feature2.txt
      git -c user.email="t@e.com" -c user.name="T" commit -q -m "commit C2"
    )
    c2_sha=$(git -C "$subm_repo" rev-parse HEAD)

    # In parent remote, advance gitlink to C2 and commit
    (
      cd "$remote_repo" || exit 1
      git update-index --add --cacheinfo 160000,"$c2_sha",.vendor/helper
      git -c user.email="t@e.com" -c user.name="T" commit -q -a -m "parent with C2"
    )

    # Update checkout: must legitimately advance child submodule to C2
    resolve_remote_ref
    update_repository "$chk_advance" || exit 1

    c2_actual=$(git -C "$chk_advance/.vendor/helper" rev-parse HEAD)
    test "$c2_actual" = "$c2_sha" || exit 1

    cleanup
    exit 0
  ) || return 1
  return 0
}

config_lock_failure_suppresses_stderr_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    chk_lock=$(mktemp -d "$ROOT/chk-cfglock.XXXXXX")
    mkdir -p "$chk_lock/.git"
    touch "$chk_lock/.git/config.lock"
    out=$( ( initialize_repository "$chk_lock" ) 2>&1 )
    status=$?
    test "$status" -ne 0 || exit 1
    assert_contains "$out" "Git operation failed" || exit 1
    # Raw stderr from git should be suppressed
    ! assert_contains "$out" "fatal:" || exit 1

    cleanup
    exit 0
  ) || return 1
  return 0
}

path_poison_ambient_utility_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    test_home=$(make_home)
    fake_tools=$(make_fake_bin)
    make_behavioral_mock_stow "$fake_tools"
    cat << 'EOF' > "$fake_tools/fzf"
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_tools/fzf"

    remote_repo=$(make_remote_repo)
    chk_dir="$test_home/.dotfiles"
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    poison_bin=$(mktemp -d "$ROOT/poison.XXXXXX")
    for tool in stat uname id find readlink awk tr cp rm dirname basename which plutil git stow fzf; do
      cat << EOF > "$poison_bin/$tool"
#!/bin/sh
touch "$ROOT/poison_triggered_$tool"
exit 99
EOF
      chmod +x "$poison_bin/$tool"
    done

    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"
    export KAISIAN_GIT_TRACE_LOG="$TRACE_LOG"
    export KAISIAN_STOW_EXEC="$fake_tools/stow"
    export KAISIAN_FZF_EXEC="$fake_tools/fzf"
    export KAISIAN_PLUTIL_EXEC="/usr/bin/plutil"

    # Must succeed using literal /usr/bin and /bin paths without invoking poisoned tools
    (
      HOME="$test_home"
      PATH="$poison_bin"
      main --repo taiansu/dotfiles --ref main
    ) || exit 1

    # Assert no poison sentinels were created
    for tool in stat uname id find readlink awk tr cp rm dirname basename which plutil git stow fzf; do
      test ! -e "$ROOT/poison_triggered_$tool" || exit 1
    done

    test -d "$chk_dir/.git" || exit 1
    exit 0
  ) || return 1
  return 0
}

core_config_pairs_matrix_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    remote_repo=$(make_remote_repo)
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"

    acquire_lock
    resolve_remote_ref

    chk=$(mktemp -d "$ROOT/chk-core.XXXXXX")
    initialize_repository "$chk" || exit 1

    # 1. Allowed boolean pairs pass
    for val in true false; do
      git -C "$chk" config --local core.filemode "$val"
      git -C "$chk" config --local core.ignorecase "$val"
      git -C "$chk" config --local core.precomposeunicode "$val"
      validate_git_config "$chk" || exit 1
    done

    # 2. Allowed absent/true pairs pass
    git -C "$chk" config --local core.symlinks true
    git -C "$chk" config --local core.protectHFS true
    git -C "$chk" config --local core.protectNTFS true
    validate_git_config "$chk" || exit 1

    # 3. Invalid core.symlinks
    for bad in false 0 1 foo; do
      git -C "$chk" config --local core.symlinks "$bad"
      if ( validate_git_config "$chk" ) >/dev/null 2>&1; then
        printf 'Expected core.symlinks=%s to fail\n' "$bad" >&2
        exit 1
      fi
    done
    git -C "$chk" config --local --unset core.symlinks

    # 4. Invalid core.protectHFS / protectNTFS
    for bad in false 0 1 foo; do
      git -C "$chk" config --local core.protectHFS "$bad"
      if ( validate_git_config "$chk" ) >/dev/null 2>&1; then
        printf 'Expected core.protectHFS=%s to fail\n' "$bad" >&2
        exit 1
      fi
    done
    git -C "$chk" config --local --unset core.protectHFS

    for bad in false 0 1 foo; do
      git -C "$chk" config --local core.protectNTFS "$bad"
      if ( validate_git_config "$chk" ) >/dev/null 2>&1; then
        printf 'Expected core.protectNTFS=%s to fail\n' "$bad" >&2
        exit 1
      fi
    done
    git -C "$chk" config --local --unset core.protectNTFS

    # 5. Invalid core.repositoryformatversion / bare / logallrefupdates
    git -C "$chk" config --local core.repositoryformatversion 1
    if ( validate_git_config "$chk" ) >/dev/null 2>&1; then
      printf 'Expected core.repositoryformatversion=1 to fail\n' >&2
      exit 1
    fi
    git -C "$chk" config --local core.repositoryformatversion 0

    git -C "$chk" config --local core.bare true
    if ( validate_git_config "$chk" ) >/dev/null 2>&1; then
      printf 'Expected core.bare=true to fail\n' >&2
      exit 1
    fi
    git -C "$chk" config --local core.bare false

    git -C "$chk" config --local core.logallrefupdates false
    if ( validate_git_config "$chk" ) >/dev/null 2>&1; then
      printf 'Expected core.logallrefupdates=false to fail\n' >&2
      exit 1
    fi

    cleanup
    exit 0
  ) || return 1
  return 0
}


production_main_integration_case() {
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"

    test_home=$(make_home)
    fake_tools=$(make_fake_bin)
    make_behavioral_mock_stow "$fake_tools"
    cat << 'EOF' > "$fake_tools/fzf"
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_tools/fzf"

    remote_repo=$(make_remote_repo)
    origin_commit=$(git -C "$remote_repo" rev-parse HEAD)

    chk_dir="$test_home/.dotfiles"
    map_file="$ROOT/fake-map.txt"
    printf 'https://github.com/taiansu/dotfiles=%s\n' "$remote_repo" > "$map_file"

    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"
    export KAISIAN_GIT_TRACE_LOG="$TRACE_LOG"
    export KAISIAN_STOW_EXEC="$fake_tools/stow"
    export KAISIAN_FZF_EXEC="$fake_tools/fzf"

    # 1. First run on absent checkout -> acquires checkout and resolves selection
    (
      HOME="$test_home"
      PATH="$fake_tools:/usr/bin:/bin"
      main --repo taiansu/dotfiles --ref main
    ) || exit 1

    # Assert no target HOME mutation (no links created in HOME root)
    test ! -L "$test_home/.zshrc" || exit 1
    test ! -L "$test_home/.gitconfig" || exit 1

    # 2. Second run on existing checkout -> updates cleanly
    (
      HOME="$test_home"
      PATH="$fake_tools:/usr/bin:/bin"
      main --repo taiansu/dotfiles --ref main
    ) || exit 1

    head_sha2=$(git -C "$chk_dir" rev-parse HEAD)
    test "$head_sha2" = "$origin_commit" || exit 1

    exit 0
  ) || return 1
  return 0
}

run_case 'source repository URL and slug canonicalization matrix' source_canonicalization_matrix_case
run_case 'custom --repo requires explicit --ref' custom_repo_requires_ref_case
run_case 'origin ref resolution and branch/tag ambiguity' origin_ref_resolution_and_ambiguity_case
run_case 'unadvertised 40-hex SHA is rejected before fetch' unadvertised_40_hex_sha_rejection_case
run_case 'FETCH_HEAD mismatch against EXPECTED_COMMIT_SHA rejection' fetch_head_substituted_mismatch_case
run_case 'fetched object pinning beats same-named malicious local refs' fetched_object_pinning_beats_malicious_local_refs_case
run_case 'new checkout uses git init and single fetch without local/tracking branches' new_checkout_uses_init_and_single_fetch_case
run_case 'single fetch count and trace log sanitized environment assertions' single_fetch_and_trace_assertions_case
run_case 'existing checkout cleanliness, untracked/ignored files, and origin mismatch' existing_checkout_cleanliness_and_origin_mismatch_case
run_case 'existing non-repo directory and exact origin/fetch counts' existing_non_repo_and_origin_fetch_counts_case
run_case 'git config strict allowlist and hostile config rejection' git_config_allowlist_and_hostile_configs_case
run_case 'core config allowed pairs and symlinks boolean validation' core_config_pairs_matrix_case
run_case 'git admin boundaries, replacements, grafts, and linked worktrees' git_admin_boundaries_and_replacements_case
run_case 'git admin nested symlinks and active hook rejection' admin_nested_symlinks_and_active_hooks_case
run_case 'fresh index verification defeats assume-unchanged and skip-worktree' fresh_index_defeats_hidden_worktree_modifications_case
run_case 'direct worktree leaf hash comparison catches attribute CRLF hiding' worktree_leaf_hash_and_crlf_attribute_hiding_case
run_case 'worktree leaf bidirectional mode check and CRLF attribute hiding' worktree_bidirectional_mode_check_case
run_case 'staged submodules validation, containment, and non-package isolation' staged_submodules_validation_and_containment_case
run_case 'submodule matrix, nested levels, and hostile definition rejection' submodule_matrix_and_nested_levels_case
run_case 'legitimate submodule advancement C1 to C2 during parent update' legitimate_submodule_advancement_c1_to_c2_case
run_case 'config lock failure suppresses raw stderr and emits localized error' config_lock_failure_suppresses_stderr_case
run_case 'poisoned PATH ambient utility immunity' path_poison_ambient_utility_case
run_case 'production main wiring through acquisition and manifest selection' production_main_integration_case
run_case 'executed command trace contains no forbidden destructive operations' command_trace_forbidden_operations_case
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
