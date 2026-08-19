#!/bin/bash
set -u

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kaisian-test.XXXXXX") || exit 1
ROOT=$(cd -P "$ROOT" && pwd -P)
trap 'rm -rf -- "$ROOT"' EXIT HUP INT TERM
SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/setup.sh
TRACE_LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/tmp/last-command-trace.log"
/bin/mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
: > "$TRACE_LOG"
export KAISIAN_GIT_TRACE_LOG="$TRACE_LOG"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test User"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test User"
export GIT_COMMITTER_EMAIL="test@example.com"
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
      "invalid_package_tree"
      "invalid_targets"
      "backup_root"
      "manual_restore"
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
  local trace_log="$TRACE_LOG"
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
    root_head_before=$(git -C "$chk_wrong_child" rev-parse HEAD)
    root_status_before=$(git -C "$chk_wrong_child" status --porcelain=v1)
    child_status_before=$(git -C "$chk_wrong_child/.vendor/helper" status --porcelain=v1)
    root_files_before=$(cd "$chk_wrong_child" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)
    child_files_before=$(cd "$chk_wrong_child/.vendor/helper" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)
    wrong_trace="$ROOT/wrong-child.trace"
    : > "$wrong_trace"
    export KAISIAN_GIT_TRACE_LOG="$wrong_trace"
    if ( update_repository "$chk_wrong_child" ) >/dev/null 2>&1; then
      printf 'Expected wrong child commit to fail update\n' >&2
      exit 1
    fi
    test "$(git -C "$chk_wrong_child" rev-parse HEAD)" = "$root_head_before" || exit 1
    test "$(git -C "$chk_wrong_child" status --porcelain=v1)" = "$root_status_before" || exit 1
    test "$(git -C "$chk_wrong_child/.vendor/helper" rev-parse HEAD)" = "$tampered_child_sha" || exit 1
    test "$(git -C "$chk_wrong_child/.vendor/helper" status --porcelain=v1)" = "$child_status_before" || exit 1
    test "$(cd "$chk_wrong_child" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)" = "$root_files_before" || exit 1
    test "$(cd "$chk_wrong_child/.vendor/helper" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)" = "$child_files_before" || exit 1
    ! /usr/bin/grep -Eq ' (fetch|checkout) ' "$wrong_trace" || exit 1

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
    nogm_trace="$ROOT/nogm.trace"
    : > "$nogm_trace"
    export KAISIAN_GIT_TRACE_LOG="$nogm_trace"
    nogm_payload_before=""
    if test -d "$chk_nogm"; then
      nogm_payload_before=$(cd "$chk_nogm" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)
    fi
    if ( initialize_repository "$chk_nogm" ) >/dev/null 2>&1; then
      printf 'Expected gitlink without .gitmodules to fail\n' >&2
      exit 1
    fi
    nogm_payload_after=$(cd "$chk_nogm" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)
    test "$nogm_payload_after" = "$nogm_payload_before" || exit 1
    ! /usr/bin/grep -Eq ' checkout ' "$nogm_trace" || exit 1

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
    orphan_trace="$ROOT/orphan.trace"
    : > "$orphan_trace"
    export KAISIAN_GIT_TRACE_LOG="$orphan_trace"
    orphan_payload_before=""
    if test -d "$chk_orphan"; then
      orphan_payload_before=$(cd "$chk_orphan" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)
    fi
    if ( initialize_repository "$chk_orphan" ) >/dev/null 2>&1; then
      printf 'Expected orphan .gitmodules definition without gitlink to fail\n' >&2
      exit 1
    fi
    orphan_payload_after=$(cd "$chk_orphan" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)
    test "$orphan_payload_after" = "$orphan_payload_before" || exit 1
    ! /usr/bin/grep -Eq ' checkout ' "$orphan_trace" || exit 1

    # 2m. Valid declaration set with an extra unlisted gitlink rejects pre-checkout
    repo_extra=$(make_remote_repo)
    (
      cd "$repo_extra" || exit 1
      git config -f .gitmodules submodule.helper.path ".vendor/helper"
      git config -f .gitmodules submodule.helper.url "https://github.com/taiansu/nested"
      git add .gitmodules
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/helper
      git update-index --add --cacheinfo 160000,"$subm_lvl2_sha",.vendor/unlisted
      git -c user.email="t@e.com" -c user.name="T" commit -q -m "extra unlisted gitlink"
    )
    printf 'https://github.com/taiansu/extra=%s\n' "$repo_extra" >> "$map_file"
    REPOSITORY="https://github.com/taiansu/extra"
    resolve_remote_ref
    chk_extra=$(mktemp -d "$ROOT/chk-extra.XXXXXX")
    extra_trace="$ROOT/extra.trace"
    : > "$extra_trace"
    export KAISIAN_GIT_TRACE_LOG="$extra_trace"
    extra_payload_before=""
    if ( initialize_repository "$chk_extra" ) >/dev/null 2>&1; then
      printf 'Expected extra unlisted gitlink to fail\n' >&2
      exit 1
    fi
    extra_payload_after=$(cd "$chk_extra" && /usr/bin/find . -path './.git' -prune -o -type f -print | /usr/bin/sort)
    test "$extra_payload_after" = "$extra_payload_before" || exit 1
    ! /usr/bin/grep -Eq ' checkout ' "$extra_trace" || exit 1

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

    test -s "$trace_log" || exit 1
    base_env=$(printf 'ENV: HOME=%q PATH=%q LC_ALL=%q GIT_CONFIG_NOSYSTEM=%q GIT_CONFIG_GLOBAL=%q GIT_ATTR_NOSYSTEM=%q GIT_TERMINAL_PROMPT=%q GIT_ASKPASS=%q GIT_NO_REPLACE_OBJECTS=%q GIT_ALLOW_PROTOCOL=%q' "$SANDBOX/git-home" "/usr/bin:/bin:/usr/sbin:/sbin" "C" "1" "/dev/null" "1" "0" "/usr/bin/false" "1" "https")
    index_env="$base_env GIT_INDEX_FILE=$(printf '%q' "$SANDBOX/verify-index-$$")"
    expected_cmd[0]="git ls-remote $(printf '%q' "$CANONICAL_REPO")"
    expected_cmd[1]="git init $(printf '%q' "$chk_single")"
    expected_cmd[2]="git -C $(printf '%q' "$chk_single") config --local remote.origin.url $(printf '%q' "$CANONICAL_REPO")"
    expected_cmd[3]="git -C $(printf '%q' "$chk_single") config --local remote.origin.fetch $(printf '%q' '+refs/heads/*:refs/remotes/origin/*')"
    expected_cmd[4]="git -C $(printf '%q' "$chk_single") fetch --no-tags --depth=1 $(printf '%q' "$CANONICAL_REPO") $(printf '%q' "$RESOLVED_FETCH_REF")"
    expected_cmd[5]="git -C $(printf '%q' "$chk_single") rev-parse --verify $(printf '%q' 'FETCH_HEAD^{commit}')"
    expected_cmd[6]="git -C $(printf '%q' "$chk_single") ls-tree -r $(printf '%q' "$RESOLVED_COMMIT")"
    expected_cmd[7]="git -C $(printf '%q' "$chk_single") cat-file -e $(printf '%q' "$RESOLVED_COMMIT:.gitmodules")"
    expected_cmd[8]="git -C $(printf '%q' "$chk_single") rev-parse --is-bare-repository"
    expected_cmd[9]="git -C $(printf '%q' "$chk_single") rev-parse --absolute-git-dir"
    expected_cmd[10]="git -C $(printf '%q' "$chk_single") rev-parse --git-common-dir"
    expected_cmd[11]="git -C $(printf '%q' "$chk_single") config --local --list"
    expected_cmd[12]="git -C $(printf '%q' "$chk_single") checkout --detach $(printf '%q' "$RESOLVED_COMMIT") --"
    expected_cmd[13]="git -C $(printf '%q' "$chk_single") cat-file -e $(printf '%q' 'HEAD:.gitmodules')"
    expected_cmd[14]="${expected_cmd[8]}"
    expected_cmd[15]="${expected_cmd[9]}"
    expected_cmd[16]="${expected_cmd[10]}"
    expected_cmd[17]="${expected_cmd[11]}"
    expected_cmd[18]="git -C $(printf '%q' "$chk_single") diff-index --quiet HEAD --"
    expected_cmd[19]="git -C $(printf '%q' "$chk_single") read-tree HEAD"
    expected_cmd[20]="git -C $(printf '%q' "$chk_single") update-index -q --refresh"
    expected_cmd[21]="${expected_cmd[18]}"
    expected_cmd[22]="git -C $(printf '%q' "$chk_single") ls-tree -r HEAD"
    expected_cmd[23]="git -C $(printf '%q' "$chk_single") hash-object $(printf '%q' "$chk_single/.kaisian.json")"
    expected_cmd[24]="git -C $(printf '%q' "$chk_single") hash-object $(printf '%q' "$chk_single/git/dot-gitconfig")"
    expected_cmd[25]="git -C $(printf '%q' "$chk_single") hash-object $(printf '%q' "$chk_single/mise/dot-config")"
    expected_cmd[26]="git -C $(printf '%q' "$chk_single") hash-object $(printf '%q' "$chk_single/shell/dot-zshrc")"
    expected_cmd[27]="git -C $(printf '%q' "$chk_single") status --porcelain=v1 --untracked-files=all --ignored=matching --ignore-submodules=none"
    pair_index=0
    actual_env=""
    # Four tracked-file probes above are preceded by one ls-tree; this fixture has no extra payload.
    while IFS= read -r trace_line; do
      test -n "$trace_line" || exit 1
      case "$trace_line" in
        ENV:*) test -z "$actual_env" || exit 1; actual_env="$trace_line" ;;
        git\ *)
          test "$actual_env" = "$base_env" || test "$actual_env" = "$index_env" || exit 1
          test "$trace_line" = "${expected_cmd[$pair_index]}" || exit 1
          case "$pair_index" in 19|20|21) test "$actual_env" = "$index_env" ;; *) test "$actual_env" = "$base_env" ;; esac
          pair_index=$((pair_index + 1)); actual_env=""
          ;;
        *) exit 1 ;;
      esac
    done < "$trace_log"
    test "$pair_index" -eq 28 || exit 1
    test -z "$actual_env" || exit 1
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
    fail_marker="$ROOT/fake-config-failed"
    trace_log="$ROOT/config-failure.trace"
    : > "$trace_log"
    export KAISIAN_GIT_EXEC="$FAKE_GIT"
    export KAISIAN_FAKE_GIT_MAP="$map_file"
    export KAISIAN_GIT_TRACE_LOG="$trace_log"
    export KAISIAN_FAKE_GIT_FAIL_ON_CONFIG_ORIGIN=1
    export KAISIAN_FAKE_GIT_FAIL_MARKER="$fail_marker"

    CANONICAL_REPO="https://github.com/taiansu/dotfiles"
    REPOSITORY="taiansu/dotfiles"
    REQUESTED_REF="main"
    acquire_lock
    EXPECTED_COMMIT_SHA=$(git -C "$remote_repo" rev-parse HEAD)
    RESOLVED_FETCH_REF="refs/heads/main"
    chk_lock=$(mktemp -d "$ROOT/chk-cfglock.XXXXXX")
    out=$( ( initialize_repository "$chk_lock" ) 2>&1 )
    status=$?
    test "$status" -ne 0 || exit 1
    test -e "$fail_marker" || exit 1
    assert_contains "$out" "Git operation failed (failed to set origin url)." || exit 1
    ! assert_contains "$out" "fake-git:" || exit 1
    ! assert_contains "$out" "fatal:" || exit 1

    # The hook fails exactly once at origin.url; init succeeds and later calls never run.
    test "$(/usr/bin/grep -c '^git init ' "$trace_log")" -eq 1 || exit 1
    test "$(/usr/bin/grep -c ' config --local remote.origin.url ' "$trace_log")" -eq 1 || exit 1
    test "$(/usr/bin/grep -c ' config --local remote.origin.fetch ' "$trace_log")" -eq 0 || exit 1
    test "$(/usr/bin/grep -c ' fetch ' "$trace_log")" -eq 0 || exit 1
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

    poison_marker="$ROOT/poison_triggered"
    poison_bin=$(mktemp -d "$ROOT/poison.XXXXXX")
    for tool in stat uname id find readlink awk tr cp rm dirname basename which plutil git stow fzf; do
      cat << EOF > "$poison_bin/$tool"
#!/bin/sh
: > "$ROOT/poison_triggered_$tool"
exit 99
EOF
      chmod +x "$poison_bin/$tool"
    done
    # Prove the poison fixture itself is live under the restricted PATH.
    if ( PATH="$poison_bin" "$poison_bin/stat" ) >/dev/null 2>&1; then
      exit 1
    fi
    test -e "$ROOT/poison_triggered_stat" || exit 1
    for tool in stat uname id find readlink awk tr cp rm dirname basename which plutil git stow fzf; do
      /bin/rm -f "$ROOT/poison_triggered_$tool"
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
task5_mapping_fixture_case() {
  t=$(mktemp -d "$ROOT/task5.XXXXXX") || return 1
  /bin/mkdir -p "$t/checkout/shell/dot-config/zsh" "$t/home" "$t/sandbox" || return 1
  printf x > "$t/checkout/shell/dot-config/zsh/aliasrc" || return 1
  GIT_CONFIG_NOSYSTEM=1 git -C "$t/checkout" init -q || return 1
  GIT_CONFIG_NOSYSTEM=1 git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid || return 1
  GIT_CONFIG_NOSYSTEM=1 git -C "$t/checkout" -c commit.gpgSign=false config user.name test || return 1
  GIT_CONFIG_NOSYSTEM=1 git -C "$t/checkout" add . || return 1
  GIT_CONFIG_NOSYSTEM=1 git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || return 1
  printf 'shell\tShell\tShell\n' > "$t/sandbox/groups.tsv" || return 1
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    CHECKOUT_DIR="$t/checkout"
    SANDBOX="$t/sandbox"
    build_package_map || exit 1
    validate_typed_tree || exit 1
    test "$(wc -l < "$SANDBOX/mapping.tsv" | tr -d ' ')" = 3 || exit 1
    test "$(sed -n '1p' "$SANDBOX/mapping.tsv")" = "$(printf 'dir\tshell\tdot-config\t.config\t.config')" || exit 1
    test "$(sed -n '2p' "$SANDBOX/mapping.tsv")" = "$(printf 'dir\tshell\tdot-config/zsh\t.config/zsh\t.config/zsh')" || exit 1
    test "$(sed -n '3p' "$SANDBOX/mapping.tsv")" = "$(printf 'file\tshell\tdot-config/zsh/aliasrc\t.config/zsh/aliasrc\t.config/zsh/aliasrc')" || exit 1
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}
task5_shared_directory_coalescing_case() {
  t=$(mktemp -d "$ROOT/task5-shared.XXXXXX") || return 1
  /bin/mkdir -p "$t/checkout/pkg1/dot-config" "$t/checkout/pkg2/dot-config" "$t/sandbox"
  printf a > "$t/checkout/pkg1/dot-config/a"; printf b > "$t/checkout/pkg2/dot-config/b"
  git -C "$t/checkout" init -q
  git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid
  git -C "$t/checkout" -c commit.gpgSign=false config user.name test
  git -C "$t/checkout" add . && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture
  printf 'pkg1\tone\tone\npkg2\ttwo\ttwo\n' > "$t/sandbox/groups.tsv"
  printf 'pkg1\npkg2\n' > "$t/sandbox/selected.txt"
  ( export KAISIAN_TESTING=1; . "$SCRIPT"; CHECKOUT_DIR="$t/checkout"; SANDBOX="$t/sandbox"; build_package_map && validate_typed_tree && test "$(grep -c '^dir.*\.config' "$SANDBOX/mapping.tsv")" = 1 )
  status=$?; /bin/rm -rf "$t"; return "$status"
}

task5_prefix_collision_case() {
  t=$(mktemp -d "$ROOT/task5-prefix.XXXXXX") || return 1
  /bin/mkdir -p "$t/checkout/pkg/-q" "$t/checkout/normal" "$t/sandbox"
  printf x > "$t/checkout/pkg/-q/file"; printf y > "$t/checkout/normal/file"
  git -C "$t/checkout" init -q
  git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid
  git -C "$t/checkout" -c commit.gpgSign=false config user.name test
  git -C "$t/checkout" add . && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || { /bin/rm -rf "$t"; return 1; }
  printf 'pkg\tq\tq\nnormal\tn\tn\n' > "$t/sandbox/groups.tsv"; printf 'pkg\nnormal\n' > "$t/sandbox/selected.txt"
  (
    export KAISIAN_TESTING=1; . "$SCRIPT"; CHECKOUT_DIR="$t/checkout"; SANDBOX="$t/sandbox"
    build_package_map && validate_typed_tree || exit 1
    expected_files=$(printf 'file\tpkg\t-q/file\t-q/file\t-q/file\nfile\tnormal\tfile\tfile\tfile')
    test "$(grep '^file	' "$SANDBOX/mapping.tsv")" = "$expected_files" || exit 1
    expected_full=$(printf 'dir\tpkg\t-q\t-q\t-q\nfile\tpkg\t-q/file\t-q/file\t-q/file\nfile\tnormal\tfile\tfile\tfile')
    test "$(cat "$SANDBOX/mapping.tsv")" = "$expected_full" || exit 1
  )
  status=$?; /bin/rm -rf "$t"; return "$status"
}

task5_unselected_declared_rejection_case() {
  t=$(mktemp -d "$ROOT/task5-declared.XXXXXX") || return 1
  /bin/mkdir -p "$t/checkout/good" "$t/checkout/bad/dot-config" "$t/sandbox"
  printf g > "$t/checkout/good/file"; printf x > "$t/checkout/bad/dot-config/x"
  git -C "$t/checkout" init -q
  git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid
  git -C "$t/checkout" -c commit.gpgSign=false config user.name test
  git -C "$t/checkout" add . && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm baseline || { /bin/rm -rf "$t"; return 1; }
  printf 'good\tgood\tgood\nbad\tbad\tbad\n' > "$t/sandbox/groups.tsv"; printf 'good\n' > "$t/sandbox/selected.txt"
  (
    export KAISIAN_TESTING=1; . "$SCRIPT"; CHECKOUT_DIR="$t/checkout"; SANDBOX="$t/sandbox"
    build_package_map && validate_typed_tree || exit 1
    test "$(wc -l < "$SANDBOX/mapping.tsv" | tr -d ' ')" = 3 || exit 1
    test "$(sed -n '1p' "$SANDBOX/mapping.tsv")" = "$(printf 'file\tgood\tfile\tfile\tfile')" || exit 1
    test "$(sed -n '2p' "$SANDBOX/mapping.tsv")" = "$(printf 'dir\tbad\tdot-config\t.config\t.config')" || exit 1
    test "$(sed -n '3p' "$SANDBOX/mapping.tsv")" = "$(printf 'file\tbad\tdot-config/x\t.config/x\t.config/x')" || exit 1
  ) || { /bin/rm -rf "$t"; return 1; }
  printf h > "$t/checkout/bad/.hidden"
  git -C "$t/checkout" add . && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm invalid || { /bin/rm -rf "$t"; return 1; }
  (
    export KAISIAN_TESTING=1; . "$SCRIPT"; CHECKOUT_DIR="$t/checkout"; SANDBOX="$t/sandbox"
    ! build_package_map && grep -F -q -e $'file\tgood\tfile\tfile\tfile' "$SANDBOX/mapping.tsv"
  )
  status=$?; /bin/rm -rf "$t"; return "$status"
}

task5_nonascii_locale_rejection_case() {
  t=$(mktemp -d "$ROOT/task5-locale.XXXXXX") || return 1
  /bin/mkdir -p "$t/sandbox"
  printf 'file\tpkg\tbad-é\tbad-é\tbad-é\n' > "$t/sandbox/mapping.tsv"
  ( export KAISIAN_TESTING=1; export LC_ALL=en_US.UTF-8; . "$SCRIPT"; SANDBOX="$t/sandbox"; MAPPING_FILE="$t/sandbox/mapping.tsv"; ! validate_typed_tree )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

task5_all_node_boundary_rejection_case() {
  for kind in clean empty hidden nonascii control symlink nestedgit gitlink untracked ignored; do
    t=$(mktemp -d "$ROOT/task5-nodes.XXXXXX") || return 1
    /bin/mkdir -p "$t/checkout/pkg/dot-config" "$t/sandbox"
    printf x > "$t/checkout/pkg/dot-config/x"
    git -C "$t/checkout" init -q
    git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid
    git -C "$t/checkout" -c commit.gpgSign=false config user.name test
    printf 'pkg\tpkg\tpkg\n' > "$t/sandbox/groups.tsv"; printf 'pkg\n' > "$t/sandbox/selected.txt"
    expect=0
    git -C "$t/checkout" add pkg/dot-config/x
    git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm base || { /bin/rm -rf "$t"; return 1; }
    case "$kind" in
      clean) ;;
      empty) mkdir "$t/checkout/pkg/empty"; expect=1 ;;
      hidden)
        printf h > "$t/checkout/pkg/.hidden"
        git -C "$t/checkout" add -A && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm hidden || { /bin/rm -rf "$t"; return 1; }
        expect=1
        ;;
      nonascii)
        printf n > "$t/checkout/pkg/dot-é"
        git -C "$t/checkout" add -A && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm nonascii || { /bin/rm -rf "$t"; return 1; }
        expect=1
        ;;
      control)
        bad=$(printf 'bad\001')
        printf c > "$t/checkout/pkg/$bad"
        git -C "$t/checkout" add -A && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm control || { /bin/rm -rf "$t"; return 1; }
        expect=1
        ;;
      symlink)
        ln -s dot-config/x "$t/checkout/pkg/link"
        git -C "$t/checkout" add -A && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm symlink || { /bin/rm -rf "$t"; return 1; }
        expect=1
        ;;
      nestedgit)
        mkdir -p "$t/checkout/pkg/nested/.git"
        expect=1
        ;;
      gitlink)
        sha=$(git -C "$t/checkout" rev-parse HEAD)
        mkdir -p "$t/checkout/pkg/gitlink"
        printf g > "$t/checkout/pkg/gitlink/file"
        git -C "$t/checkout" update-index --add --cacheinfo 160000,"$sha",pkg/gitlink
        git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm gitlink || { /bin/rm -rf "$t"; return 1; }
        expect=1
        ;;
      untracked)
        printf u > "$t/checkout/pkg/untracked"
        expect=1
        ;;
      ignored)
        printf 'pkg/ignored\n' > "$t/checkout/.gitignore"
        git -C "$t/checkout" add .gitignore && git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm ignore || { /bin/rm -rf "$t"; return 1; }
        printf i > "$t/checkout/pkg/ignored"
        expect=1
        ;;
    esac
    case "$kind" in
      clean|hidden|nonascii|control|symlink|gitlink)
        test -z "$(git -C "$t/checkout" status --porcelain)" || { /bin/rm -rf "$t"; return 1; }
        ;;
    esac
    ( export KAISIAN_TESTING=1; . "$SCRIPT"; CHECKOUT_DIR="$t/checkout"; SANDBOX="$t/sandbox"; build_package_map )
    actual=$?
    test "$actual" -eq "$expect" || { /bin/rm -rf "$t"; return 1; }
    /bin/rm -rf "$t"
  done
  return 0
}

run_case 'Task 5 shared directory coalescing' task5_shared_directory_coalescing_case
run_case 'Task 5 prefix collision rejection' task5_prefix_collision_case
run_case 'Task 5 declared unselected rejection' task5_unselected_declared_rejection_case
run_case 'Task 5 non-C locale non-ASCII rejection' task5_nonascii_locale_rejection_case
run_case 'Task 5 all-node boundary rejection' task5_all_node_boundary_rejection_case

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
run_case 'Task 5 normalized package mapping fixture' task5_mapping_fixture_case

task5_preflight_targets_classification_case() {
  t=$(mktemp -d "$ROOT/task5-preflight-class.XXXXXX") || return 1
  chk="$t/checkout/pkg"
  hm="$t/home"
  sb="$t/sandbox"
  mkdir -p "$chk/dot-config" "$hm/.config" "$sb"

  printf 'absent\n' > "$chk/dot-config/absent_file"
  printf 'exact_abs\n' > "$chk/dot-zshrc"
  printf 'exact_rel\n' > "$chk/dot-gitconfig"
  printf 'exact_chain\n' > "$chk/dot-config/chain_target"
  printf 'regular\n' > "$chk/dot-config/regular_file"
  printf 'dir_as_file\n' > "$chk/dot-config/dir_target"
  printf 'broken_sym\n' > "$chk/dot-config/broken_sym"
  printf 'wrong_sym\n' > "$chk/dot-config/wrong_sym"

  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" init -q || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.name test || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" add . || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || { /bin/rm -rf "$t"; return 1; }

  ln -s "$chk/dot-zshrc" "$hm/.zshrc"
  ln -s "../checkout/pkg/dot-gitconfig" "$hm/.gitconfig"
  ln -s "$chk/dot-config/chain_target" "$hm/.config/chain_alias"
  ln -s "$hm/.config/chain_alias" "$hm/.config/chain_target"
  printf 'existing_regular\n' > "$hm/.config/regular_file"
  mkdir -p "$hm/.config/dir_target"
  ln -s "$t/nonexistent_dest" "$hm/.config/broken_sym"
  printf 'other\n' > "$hm/other_file"
  ln -s "$hm/other_file" "$hm/.config/wrong_sym"

  zshrc_target=$(/usr/bin/readlink "$hm/.zshrc")
  gitconfig_target=$(/usr/bin/readlink "$hm/.gitconfig")
  chain_target=$(/usr/bin/readlink "$hm/.config/chain_target")
  regular_ino=$(/usr/bin/stat -f '%i' "$hm/.config/regular_file")
  dir_ino=$(/usr/bin/stat -f '%i' "$hm/.config/dir_target")
  broken_target=$(/usr/bin/readlink "$hm/.config/broken_sym")
  wrong_target=$(/usr/bin/readlink "$hm/.config/wrong_sym")

  # Precreate collision candidate root
  fixed_time="20260819T000000Z"
  precreated_candidate="$hm/.local/state/kaisian/backups/$fixed_time-$$"
  mkdir -p "$precreated_candidate"

  printf 'pkg\tpkg\tpkg\n' > "$sb/groups.tsv"
  printf 'pkg\n' > "$sb/selected.txt"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    CHECKOUT_DIR="$t/checkout"
    SANDBOX="$sb"
    PHYSICAL_HOME="$hm"
    STATE_ROOT="$hm/.local/state/kaisian"
    KAISIAN_TEST_TIME="$fixed_time"

    build_package_map || exit 1
    validate_typed_tree || exit 1
    preflight_targets || exit 1

    # Assert deterministic collision resolution suffix -1
    expected_candidate="$hm/.local/state/kaisian/backups/$fixed_time-$$-1"
    test "$BACKUP_ROOT" = "$expected_candidate" || exit 1

    conflicts_content=$(cat "$sb/conflicts.tsv")

    # Absent, exact absolute, exact relative, and exact chained must NOT be in conflicts
    case "$conflicts_content" in
      *"$hm/.config/absent_file"*) exit 1 ;;
      *"$hm/.zshrc"*) exit 1 ;;
      *"$hm/.gitconfig"*) exit 1 ;;
      *"$hm/.config/chain_target"*) exit 1 ;;
    esac

    # Assert exact two-field format per line
    while IFS= read -r line || test -n "$line"; do
      field1=${line%%$'\t'*}
      field2=${line#*$'\t'}
      test -n "$field1" || exit 1
      test -n "$field2" || exit 1
      case "$field2" in *$'\t'*) exit 1 ;; esac
    done < "$sb/conflicts.tsv"

    # Exact planned paths in conflicts.tsv in deterministic mapping order
    expected_conflicts=$(printf '%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s' \
      "$hm/.config/broken_sym" "$expected_candidate/files/.config/broken_sym" \
      "$hm/.config/dir_target" "$expected_candidate/files/.config/dir_target" \
      "$hm/.config/regular_file" "$expected_candidate/files/.config/regular_file" \
      "$hm/.config/wrong_sym" "$expected_candidate/files/.config/wrong_sym")
    test "$conflicts_content" = "$expected_conflicts" || exit 1

    # Invariant snapshots
    test ! -e "$hm/.config/absent_file" || exit 1
    test "$(/usr/bin/readlink "$hm/.zshrc")" = "$zshrc_target" || exit 1
    test "$(/usr/bin/readlink "$hm/.gitconfig")" = "$gitconfig_target" || exit 1
    test "$(/usr/bin/readlink "$hm/.config/chain_target")" = "$chain_target" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.config/regular_file")" = "$regular_ino" || exit 1
    test "$(cat "$hm/.config/regular_file")" = "existing_regular" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.config/dir_target")" = "$dir_ino" || exit 1
    test "$(/usr/bin/readlink "$hm/.config/broken_sym")" = "$broken_target" || exit 1
    test "$(/usr/bin/readlink "$hm/.config/wrong_sym")" = "$wrong_target" || exit 1

    # Candidate BACKUP_ROOT must NOT be created by preflight
    test ! -e "$expected_candidate" || exit 1
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

task5_preflight_targets_rejection_case() {
  for kind in symlink_parent file_parent fifo_node socket_node char_device control_byte_home control_byte_state escape_home; do
    t=$(mktemp -d "$ROOT/task5-preflight-rej.XXXXXX") || return 1
    chk="$t/checkout/pkg"
    hm="$t/home"
    sb="$t/sandbox"
    mkdir -p "$chk/dot-config/app" "$chk/dev" "$hm/.config" "$sb"

    printf 'leaf\n' > "$chk/dot-config/app/leaf"
    printf 'null\n' > "$chk/dev/null"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" init -q || { /bin/rm -rf "$t"; return 1; }
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid || { /bin/rm -rf "$t"; return 1; }
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.name test || { /bin/rm -rf "$t"; return 1; }
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" add . || { /bin/rm -rf "$t"; return 1; }
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || { /bin/rm -rf "$t"; return 1; }

    printf 'pkg\tpkg\tpkg\n' > "$sb/groups.tsv"
    printf 'pkg\n' > "$sb/selected.txt"

    case "$kind" in
      symlink_parent)
        mkdir -p "$t/real_app"
        ln -s "$t/real_app" "$hm/.config/app"
        ;;
      file_parent)
        printf 'file_parent\n' > "$hm/.config/app"
        ;;
      fifo_node)
        mkdir -p "$hm/.config/app"
        mkfifo "$hm/.config/app/leaf"
        test -p "$hm/.config/app/leaf" || { /bin/rm -rf "$t"; return 1; }
        ;;
      socket_node)
        mkdir -p "$hm/.config/app"
        ( cd "$hm/.config/app" && python3 -c "import socket as s; sock = s.socket(s.AF_UNIX); sock.bind('leaf')" ) || { /bin/rm -rf "$t"; return 1; }
        test -S "$hm/.config/app/leaf" || { /bin/rm -rf "$t"; return 1; }
        ;;
      char_device)
        ;;
      control_byte_home)
        ;;
      control_byte_state)
        ;;
      escape_home)
        ;;
    esac

    (
      export KAISIAN_TESTING=1
      . "$SCRIPT"
      CHECKOUT_DIR="$t/checkout"
      SANDBOX="$sb"
      PHYSICAL_HOME="$hm"
      STATE_ROOT="$hm/.local/state/kaisian"

      build_package_map || exit 1
      validate_typed_tree || exit 1

      if test "$kind" = "char_device"; then
        PHYSICAL_HOME="/"
        test -c "/dev/null" || exit 1
      elif test "$kind" = "control_byte_home"; then
        tab_char=$'\t'
        PHYSICAL_HOME="$hm/bad${tab_char}home"
      elif test "$kind" = "control_byte_state"; then
        nl_char=$'\n'
        XDG_STATE_HOME="$hm/bad${nl_char}state"
      elif test "$kind" = "escape_home"; then
        PHYSICAL_HOME="/nonexistent/escaped/home"
      fi

      ! preflight_targets
    )
    actual=$?
    test "$actual" -eq 0 || { /bin/rm -rf "$t"; return 1; }
    /bin/rm -rf "$t"
  done
  return 0
}

task5_preflight_selection_filtering_case() {
  t=$(mktemp -d "$ROOT/task5-preflight-filter.XXXXXX") || return 1
  chk="$t/checkout"
  hm="$t/home"
  sb="$t/sandbox"
  mkdir -p "$chk/pkg_sel" "$chk/pkg_unsel" "$hm" "$sb"

  printf 'sel\n' > "$chk/pkg_sel/dot-selected"
  printf 'unsel\n' > "$chk/pkg_unsel/dot-unselected"

  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" init -q || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false config user.email test@example.invalid || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false config user.name test || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" add . || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || { /bin/rm -rf "$t"; return 1; }

  mkdir -p "$t/other_dir"
  ln -s "$t/other_dir" "$hm/.unselected"

  printf 'pkg_sel\tsel\tsel\npkg_unsel\tunsel\tunsel\n' > "$sb/groups.tsv"
  printf 'pkg_sel\n' > "$sb/selected.txt"
  printf 'pkg_unsel\n' > "$sb/unselected.txt"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    CHECKOUT_DIR="$chk"
    SANDBOX="$sb"
    PHYSICAL_HOME="$hm"
    STATE_ROOT="$hm/.local/state/kaisian"

    build_package_map || exit 1
    validate_typed_tree || exit 1
    preflight_targets || exit 1
    test ! -s "$sb/conflicts.tsv" || exit 1
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

task5_preflight_state_root_validation_case() {
  t=$(mktemp -d "$ROOT/task5-preflight-state.XXXXXX") || return 1
  chk="$t/checkout/pkg"
  hm="$t/home"
  sb="$t/sandbox"
  mkdir -p "$chk" "$hm" "$sb"

  printf 'x\n' > "$chk/dot-zshrc"
  printf 'conflict\n' > "$hm/.zshrc"

  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" init -q || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.name test || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" add . || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || { /bin/rm -rf "$t"; return 1; }

  printf 'pkg\tpkg\tpkg\n' > "$sb/groups.tsv"
  printf 'pkg\n' > "$sb/selected.txt"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    CHECKOUT_DIR="$t/checkout"
    SANDBOX="$sb"
    PHYSICAL_HOME="$hm"

    build_package_map || exit 1
    validate_typed_tree || exit 1

    # 1. Absolute XDG_STATE_HOME succeeds and computes exact custom backup path under candidate BACKUP_ROOT
    XDG_STATE_HOME="$t/custom_state" preflight_targets || exit 1
    conflicts=$(cat "$sb/conflicts.tsv")
    case "$conflicts" in
      *"$BACKUP_ROOT/files/.zshrc"*) ;;
      *) exit 1 ;;
    esac

    # 2. Relative XDG_STATE_HOME fails
    ! XDG_STATE_HOME="relative/state" preflight_targets || exit 1

    # 3. Raw symlink ancestor in STATE_ROOT fails
    mkdir -p "$t/real_sym_ancestor"
    ln -s "$t/real_sym_ancestor" "$t/sym_ancestor_dir"
    ! XDG_STATE_HOME="$t/sym_ancestor_dir/state" preflight_targets || exit 1

    # 4. Non-directory ancestor in STATE_ROOT fails
    touch "$t/file_state"
    ! XDG_STATE_HOME="$t/file_state/sub" preflight_targets || exit 1

    # 5. Symlink in backup base tree fails
    mkdir -p "$t/sym_backup_target"
    mkdir -p "$t/state_with_sym_backup/kaisian"
    ln -s "$t/sym_backup_target" "$t/state_with_sym_backup/kaisian/backups"
    ! XDG_STATE_HOME="$t/state_with_sym_backup" preflight_targets || exit 1

    # 6. Non-directory in backup base tree fails
    mkdir -p "$t/state_with_file_backup/kaisian"
    touch "$t/state_with_file_backup/kaisian/backups"
    ! XDG_STATE_HOME="$t/state_with_file_backup" preflight_targets || exit 1
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

task5_preflight_overlap_matrix_case() {
  t=$(mktemp -d "$ROOT/task5-preflight-overlap.XXXXXX") || return 1
  chk="$t/checkout/pkg"
  hm="$t/home"
  sb_base="$t/sandboxes"
  lk_base="$t/locks"
  mkdir -p "$chk/dot-config" "$hm/.config" "$sb_base" "$lk_base"

  printf 'file\n' > "$chk/dot-config/file"
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" init -q || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.name test || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" add . || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || { /bin/rm -rf "$t"; return 1; }

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    make_valid_sb() {
      sb_dir=$1
      mkdir -p "$sb_dir"
      printf 'pkg\tpkg\tpkg\n' > "$sb_dir/groups.tsv"
      printf 'file\tpkg\tdot-config/file\t.config/file\t.config/file\n' > "$sb_dir/mapping.tsv"
      printf 'pkg\n' > "$sb_dir/selected.txt"
    }

    # 1. Target vs Sandbox (equality, ancestor, descendant)
    target_eq_sb="$hm/.config/file"
    make_valid_sb "$target_eq_sb"
    (
      CHECKOUT_DIR="$t/checkout"
      SANDBOX="$target_eq_sb"
      LOCK_DIR="$lk_base/lock1"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      STATE_ROOT="$hm/.local/state/kaisian"
      ! preflight_targets
    ) || exit 1
    rm -rf "$target_eq_sb"

    sb_ancestor="$hm/.config"
    make_valid_sb "$sb_ancestor"
    (
      CHECKOUT_DIR="$t/checkout"
      SANDBOX="$sb_ancestor"
      LOCK_DIR="$lk_base/lock2"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      STATE_ROOT="$hm/.local/state/kaisian"
      ! preflight_targets
    ) || exit 1
    rm -rf "$sb_ancestor"
    mkdir -p "$hm/.config"

    sb_descendant="$hm/.config/file/sub_sb"
    make_valid_sb "$sb_descendant"
    (
      CHECKOUT_DIR="$t/checkout"
      SANDBOX="$sb_descendant"
      LOCK_DIR="$lk_base/lock3"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      STATE_ROOT="$hm/.local/state/kaisian"
      ! preflight_targets
    ) || exit 1
    rm -rf "$hm/.config/file"

    # 2. Checkout vs Sandbox (equality, ancestor, descendant)
    chk_sb_eq="$t/chk_sb_eq"
    mkdir -p "$chk_sb_eq/pkg/dot-config"
    printf 'file\n' > "$chk_sb_eq/pkg/dot-config/file"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk_sb_eq" init -q || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk_sb_eq" -c commit.gpgSign=false config user.email test@example.invalid || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk_sb_eq" -c commit.gpgSign=false config user.name test || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk_sb_eq" add . || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk_sb_eq" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || exit 1
    make_valid_sb "$chk_sb_eq"
    (
      CHECKOUT_DIR="$chk_sb_eq"
      SANDBOX="$chk_sb_eq"
      LOCK_DIR="$lk_base/lock4"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      STATE_ROOT="$hm/.local/state/kaisian"
      ! preflight_targets
    ) || exit 1

    sb_in_chk="$chk_sb_eq/sub_sb"
    make_valid_sb "$sb_in_chk"
    (
      CHECKOUT_DIR="$chk_sb_eq"
      SANDBOX="$sb_in_chk"
      LOCK_DIR="$lk_base/lock5"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      STATE_ROOT="$hm/.local/state/kaisian"
      ! preflight_targets
    ) || exit 1
    rm -rf "$chk_sb_eq"

    sb_parent="$t/sb_parent"
    mkdir -p "$sb_parent/checkout_sub/pkg/dot-config"
    printf 'file\n' > "$sb_parent/checkout_sub/pkg/dot-config/file"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$sb_parent/checkout_sub" init -q || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$sb_parent/checkout_sub" -c commit.gpgSign=false config user.email test@example.invalid || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$sb_parent/checkout_sub" -c commit.gpgSign=false config user.name test || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$sb_parent/checkout_sub" add . || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$sb_parent/checkout_sub" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || exit 1
    make_valid_sb "$sb_parent"
    (
      CHECKOUT_DIR="$sb_parent/checkout_sub"
      SANDBOX="$sb_parent"
      LOCK_DIR="$lk_base/lock6"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      STATE_ROOT="$hm/.local/state/kaisian"
      ! preflight_targets
    ) || exit 1
    rm -rf "$sb_parent"
    # 3. State vs Sandbox (equality, ancestor, descendant)
    normal_sb="$sb_base/normal"
    make_valid_sb "$normal_sb"
    (
      CHECKOUT_DIR="$t/checkout"
      SANDBOX="$normal_sb"
      STATE_ROOT="$normal_sb"
      LOCK_DIR="$lk_base/lock7"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      ! preflight_targets
    ) || exit 1

    sb_in_state="$hm/.local/state/kaisian/sub_sb"
    make_valid_sb "$sb_in_state"
    (
      CHECKOUT_DIR="$t/checkout"
      SANDBOX="$sb_in_state"
      STATE_ROOT="$hm/.local/state/kaisian"
      LOCK_DIR="$lk_base/lock8"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      ! preflight_targets
    ) || exit 1
    rm -rf "$hm/.local/state/kaisian/sub_sb"

    (
      CHECKOUT_DIR="$t/checkout"
      SANDBOX="$normal_sb"
      STATE_ROOT="$normal_sb/sub_state"
      LOCK_DIR="$lk_base/lock9"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      ! preflight_targets
    ) || exit 1

    # 4. Target vs Checkout/State/Lock and Checkout vs State/Lock and State vs Lock
    (
      CHECKOUT_DIR="$t/checkout"
      SANDBOX="$normal_sb"
      LOCK_DIR="$lk_base/lock_matrix"
      mkdir -p "$LOCK_DIR"
      PHYSICAL_HOME="$hm"
      STATE_ROOT="$hm/.local/state/kaisian"

      build_package_map || exit 1
      validate_typed_tree || exit 1

      # Target overlaps
      ! ( CHECKOUT_DIR="$hm/.config/file" preflight_targets ) || exit 1
      ! ( STATE_ROOT="$hm/.config/file" preflight_targets ) || exit 1
      ! ( LOCK_DIR="$hm/.config/file" preflight_targets ) || exit 1

      ! ( CHECKOUT_DIR="$hm/.config" preflight_targets ) || exit 1
      ! ( STATE_ROOT="$hm/.config" preflight_targets ) || exit 1
      ! ( LOCK_DIR="$hm/.config" preflight_targets ) || exit 1

      ! ( CHECKOUT_DIR="$hm/.config/file/sub" preflight_targets ) || exit 1
      ! ( STATE_ROOT="$hm/.config/file/sub" preflight_targets ) || exit 1
      ! ( LOCK_DIR="$hm/.config/file/sub" preflight_targets ) || exit 1

      # Checkout vs State
      ! ( CHECKOUT_DIR="$STATE_ROOT" preflight_targets ) || exit 1
      ! ( CHECKOUT_DIR="$STATE_ROOT/sub" preflight_targets ) || exit 1
      ! ( STATE_ROOT="$CHECKOUT_DIR/sub" preflight_targets ) || exit 1

      # Checkout vs Lock
      ! ( CHECKOUT_DIR="$LOCK_DIR" preflight_targets ) || exit 1
      ! ( CHECKOUT_DIR="$LOCK_DIR/sub" preflight_targets ) || exit 1
      ! ( LOCK_DIR="$CHECKOUT_DIR/sub" preflight_targets ) || exit 1

      # State vs Lock
      ! ( STATE_ROOT="$LOCK_DIR" preflight_targets ) || exit 1
      ! ( STATE_ROOT="$LOCK_DIR/sub" preflight_targets ) || exit 1
      ! ( LOCK_DIR="$STATE_ROOT/sub" preflight_targets ) || exit 1

      # Root '/' ancestor overlap
      ! ( CHECKOUT_DIR="/" preflight_targets ) || exit 1
      ! ( STATE_ROOT="/" preflight_targets ) || exit 1

      # Sibling directories pass
      preflight_targets || exit 1
    ) || exit 1
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

task5_preflight_cross_device_case() {
  t=$(mktemp -d "$ROOT/task5-preflight-xdev.XXXXXX") || return 1
  chk="$t/checkout/pkg"
  hm="$t/home"
  sb="$t/sandbox"
  mkdir -p "$chk/dot-config/app" "$hm/.config/app" "$hm/.local/state" "$sb"

  printf 'x1\n' > "$chk/dot-zshrc"
  printf 'x2\n' > "$chk/dot-gitconfig"
  printf 'x3\n' > "$chk/dot-config/app/config"
  printf 'x4\n' > "$chk/dot-broken"

  printf 'conflict_1\n' > "$hm/.zshrc"
  printf 'conflict_2\n' > "$hm/.gitconfig"
  printf 'conflict_3\n' > "$hm/.config/app/config"
  ln -s "$t/nonexistent_dest" "$hm/.broken"

  zshrc_ino=$(/usr/bin/stat -f '%i' "$hm/.zshrc")
  gitconfig_ino=$(/usr/bin/stat -f '%i' "$hm/.gitconfig")
  app_ino=$(/usr/bin/stat -f '%i' "$hm/.config/app/config")
  broken_target=$(/usr/bin/readlink "$hm/.broken")

  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" init -q || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.email test@example.invalid || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false config user.name test || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" add . || { /bin/rm -rf "$t"; return 1; }
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$t/checkout" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || { /bin/rm -rf "$t"; return 1; }

  printf 'pkg\tpkg\tpkg\n' > "$sb/groups.tsv"
  printf 'pkg\n' > "$sb/selected.txt"

  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    CHECKOUT_DIR="$t/checkout"
    SANDBOX="$sb"
    PHYSICAL_HOME="$hm"
    STATE_ROOT="$hm/.local/state/kaisian"

    build_package_map || exit 1
    validate_typed_tree || exit 1

    # 1. Normal run on same filesystem succeeds with 4 conflicts
    preflight_targets || exit 1
    test -s "$sb/conflicts.tsv" || exit 1
    test "$(wc -l < "$sb/conflicts.tsv" | tr -d ' ')" = 4 || exit 1

    # 2. Mock stat: mismatch specifically on the last (.zshrc) backup ancestor after .broken, .config/app/config, .gitconfig pass
    mock_bin="$t/mock_bin"
    mkdir -p "$mock_bin"
    stat_log="$t/stat_trace.log"
    : > "$stat_log"
    nearest_backup_ancestor="$hm/.local/state"

    cat << MOCK > "$mock_bin/stat"
#!/bin/bash
target_path="\${3:-}"
printf '%s\n' "\$target_path" >> "$stat_log"

if test "\$target_path" = "$nearest_backup_ancestor" && grep -Fxq "$hm/.zshrc" "$stat_log"; then
  printf '99999\n'
else
  /usr/bin/stat "\$@"
fi
MOCK
    chmod +x "$mock_bin/stat"

    (
      KAISIAN_STAT_EXEC="$mock_bin/stat"
      ! preflight_targets
    ) || exit 1

    # Assert exact 8 source/nearest-ancestor trace lines in Git conflict order:
    expected_trace=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$hm/.broken" \
      "$nearest_backup_ancestor" \
      "$hm/.config/app/config" \
      "$nearest_backup_ancestor" \
      "$hm/.gitconfig" \
      "$nearest_backup_ancestor" \
      "$hm/.zshrc" \
      "$nearest_backup_ancestor")
    test "$(cat "$stat_log")" = "$expected_trace" || exit 1

    # Assert non-mutation on all 4 target files
    test -f "$hm/.zshrc" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.zshrc")" = "$zshrc_ino" || exit 1
    test "$(cat "$hm/.zshrc")" = "conflict_1" || exit 1

    test -f "$hm/.gitconfig" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.gitconfig")" = "$gitconfig_ino" || exit 1
    test "$(cat "$hm/.gitconfig")" = "conflict_2" || exit 1

    test -f "$hm/.config/app/config" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.config/app/config")" = "$app_ino" || exit 1
    test "$(cat "$hm/.config/app/config")" = "conflict_3" || exit 1

    test -L "$hm/.broken" || exit 1
    test "$(/usr/bin/readlink "$hm/.broken")" = "$broken_target" || exit 1

    # No backup directory created
    test ! -d "$STATE_ROOT/backups" || test -z "$(find "$STATE_ROOT/backups" -mindepth 1 2>/dev/null)" || exit 1

    # 3. Stat failure (exit 1)
    cat << 'MOCK_FAIL' > "$mock_bin/stat_fail"
#!/bin/bash
exit 1
MOCK_FAIL
    chmod +x "$mock_bin/stat_fail"

    (
      KAISIAN_STAT_EXEC="$mock_bin/stat_fail"
      ! preflight_targets
    ) || exit 1

    # Invariants on all 4 target files and no state/BACKUP_ROOT creation
    test -f "$hm/.zshrc" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.zshrc")" = "$zshrc_ino" || exit 1
    test "$(cat "$hm/.zshrc")" = "conflict_1" || exit 1
    test -f "$hm/.gitconfig" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.gitconfig")" = "$gitconfig_ino" || exit 1
    test "$(cat "$hm/.gitconfig")" = "conflict_2" || exit 1
    test -f "$hm/.config/app/config" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.config/app/config")" = "$app_ino" || exit 1
    test "$(cat "$hm/.config/app/config")" = "conflict_3" || exit 1
    test -L "$hm/.broken" || exit 1
    test "$(/usr/bin/readlink "$hm/.broken")" = "$broken_target" || exit 1
    test ! -d "$STATE_ROOT/backups" || test -z "$(find "$STATE_ROOT/backups" -mindepth 1 2>/dev/null)" || exit 1

    # 4. Stat empty output
    cat << 'MOCK_EMPTY' > "$mock_bin/stat_empty"
#!/bin/bash
exit 0
MOCK_EMPTY
    chmod +x "$mock_bin/stat_empty"

    (
      KAISIAN_STAT_EXEC="$mock_bin/stat_empty"
      ! preflight_targets
    ) || exit 1

    # Invariants on all 4 target files and no state/BACKUP_ROOT creation
    test -f "$hm/.zshrc" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.zshrc")" = "$zshrc_ino" || exit 1
    test "$(cat "$hm/.zshrc")" = "conflict_1" || exit 1
    test -f "$hm/.gitconfig" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.gitconfig")" = "$gitconfig_ino" || exit 1
    test "$(cat "$hm/.gitconfig")" = "conflict_2" || exit 1
    test -f "$hm/.config/app/config" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.config/app/config")" = "$app_ino" || exit 1
    test "$(cat "$hm/.config/app/config")" = "conflict_3" || exit 1
    test -L "$hm/.broken" || exit 1
    test "$(/usr/bin/readlink "$hm/.broken")" = "$broken_target" || exit 1
    test ! -d "$STATE_ROOT/backups" || test -z "$(find "$STATE_ROOT/backups" -mindepth 1 2>/dev/null)" || exit 1
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}
task5_confirm_conflicts_matrix_case() {
  local t
  t=$(mktemp -d "$ROOT/task5-confirm-mat.XXXXXX") || return 1
  t=$(cd -P "$t" && pwd -P)
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    unset KAISIAN_TESTING_TTY KAISIAN_TESTING_PROMPT_FAIL KAISIAN_TESTING_READ_FAIL KAISIAN_TESTING_ANSWER KAISIAN_TESTING_PROMPT_TRACE_LOG KAISIAN_TESTING_PRE_MV_HOOK KAISIAN_TESTING_FILES_FAIL KAISIAN_TESTING_APPEND_FAIL KAISIAN_TESTING_TRACKING_CREATE_FAIL KAISIAN_MV_EXEC

    SANDBOX="$t/sandbox"
    /bin/mkdir -p "$SANDBOX" || exit 1
    CONFLICTS_FILE="$SANDBOX/conflicts.tsv"
    BACKUP_ROOT="$t/state/backups/20260819T000000Z-100"

    # 1. Empty / no conflicts: continues without TTY or root, returns 0, CONFIRMED=1 in same shell
    : > "$CONFLICTS_FILE"
    CONFIRMED=0
    KAISIAN_TESTING_TTY=0 confirm_conflicts || exit 1
    test "$CONFIRMED" -eq 1 || exit 1
    test ! -d "$t/state/backups" || exit 1

    # 2. Populated conflicts file with DRY_RUN=1: prints planned moves, skips prompt, returns 0, no backup root
    printf '%s\t%s\n' "$t/home/.zshrc" "$BACKUP_ROOT/files/.zshrc" > "$CONFLICTS_FILE"
    printf '%s\t%s\n' "$t/home/.config/app/config" "$BACKUP_ROOT/files/.config/app/config" >> "$CONFLICTS_FILE"

    CONFIRMED=0
    DRY_RUN=1
    ASSUME_YES=0
    out_dry=$(KAISIAN_TESTING_TTY=0 confirm_conflicts) || exit 1
    expected_moves=$(printf 'Move %s to %s\nMove %s to %s\n' \
      "$t/home/.zshrc" "$BACKUP_ROOT/files/.zshrc" \
      "$t/home/.config/app/config" "$BACKUP_ROOT/files/.config/app/config")
    test "$out_dry" = "$expected_moves" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 3. Populated conflicts file with ASSUME_YES=1: prints planned moves, skips prompt, returns 0, CONFIRMED=1
    DRY_RUN=0
    ASSUME_YES=1
    CONFIRMED=0
    out_yes=$(KAISIAN_TESTING_TTY=0 confirm_conflicts) || exit 1
    test "$out_yes" = "$expected_moves" || exit 1
    res_yes=$(
      CONFIRMED=0
      confirm_conflicts >/dev/null || exit 1
      test "$CONFIRMED" -eq 1 || exit 1
      printf 'ok'
    )
    test "$res_yes" = 'ok' || exit 1

    # 4a. Missing/unusable TTY: returns 1 before backup creation/move, emits localized error to stderr, CONFIRMED=0
    DRY_RUN=0
    ASSUME_YES=0
    err_notty=$(
      CONFIRMED=0
      KAISIAN_TESTING_TTY=0 confirm_conflicts 2>&1 >/dev/null
      st=$?
      test "$st" -eq 1 || exit 1
      test "$CONFIRMED" -eq 0 || exit 1
    )
    test $? -eq 0 || exit 1
    err_notty_msg=$(LANGUAGE=en message no_tty)
    err_pfx=$(LANGUAGE=en message error_prefix)
    assert_contains "$err_notty" "$err_pfx" || exit 1
    assert_contains "$err_notty" "$err_notty_msg" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 4b. Prompt write failure: returns 1 before backup creation/move, emits localized error, CONFIRMED=0
    err_prompt_fail=$(
      CONFIRMED=0
      KAISIAN_TESTING_TTY=1 KAISIAN_TESTING_PROMPT_FAIL=1 confirm_conflicts 2>&1 >/dev/null
      st=$?
      test "$st" -eq 1 || exit 1
      test "$CONFIRMED" -eq 0 || exit 1
    )
    test $? -eq 0 || exit 1
    assert_contains "$err_prompt_fail" "$err_pfx" || exit 1
    assert_contains "$err_prompt_fail" "$err_notty_msg" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 4c. TTY read failure / EOF / nonzero: returns 1 before backup creation/move, emits localized error, CONFIRMED=0
    prompt_trace="$t/prompt_trace.log"
    : > "$prompt_trace"
    err_read_fail=$(
      CONFIRMED=0
      KAISIAN_TESTING_TTY=1 KAISIAN_TESTING_READ_FAIL=1 KAISIAN_TESTING_PROMPT_TRACE_LOG="$prompt_trace" confirm_conflicts 2>&1 >/dev/null
      st=$?
      test "$st" -eq 1 || exit 1
      test "$CONFIRMED" -eq 0 || exit 1
    )
    test $? -eq 0 || exit 1
    assert_contains "$err_read_fail" "$err_pfx" || exit 1
    assert_contains "$err_read_fail" "$err_notty_msg" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1
    assert_contains "$(cat "$prompt_trace")" "PROMPT_REACHED" || exit 1
    # 5. Interactive prompt with 'y' / 'yes': returns 0, CONFIRMED=1
    res_y=$(
      CONFIRMED=0
      KAISIAN_TESTING_TTY=1 KAISIAN_TESTING_ANSWER='y' confirm_conflicts >/dev/null || exit 1
      test "$CONFIRMED" -eq 1 || exit 1
      printf 'ok'
    )
    test "$res_y" = 'ok' || exit 1

    res_yes_ans=$(
      CONFIRMED=0
      KAISIAN_TESTING_TTY=1 KAISIAN_TESTING_ANSWER='yes' confirm_conflicts >/dev/null || exit 1
      test "$CONFIRMED" -eq 1 || exit 1
      printf 'ok'
    )
    test "$res_yes_ans" = 'ok' || exit 1

    # 6. Interactive prompt with 'n' / empty: returns 0 without target/state changes, CONFIRMED=0
    res_n=$(
      CONFIRMED=0
      KAISIAN_TESTING_TTY=1 KAISIAN_TESTING_ANSWER='n' confirm_conflicts >/dev/null || exit 1
      test "$CONFIRMED" -eq 0 || exit 1
      printf 'ok'
    )
    test "$res_n" = 'ok' || exit 1

    res_empty=$(
      CONFIRMED=0
      KAISIAN_TESTING_TTY=1 KAISIAN_TESTING_ANSWER='' confirm_conflicts >/dev/null || exit 1
      test "$CONFIRMED" -eq 0 || exit 1
      printf 'ok'
    )
    test "$res_empty" = 'ok' || exit 1

    # 7. Bilingual TTY error check for zh-TW
    err_zhtw=$(
      LANGUAGE=zh-TW KAISIAN_TESTING_TTY=0 confirm_conflicts 2>&1 >/dev/null
    )
    err_zhtw_msg=$(LANGUAGE=zh-TW message no_tty)
    err_zhtw_pfx=$(LANGUAGE=zh-TW message error_prefix)
    assert_contains "$err_zhtw" "$err_zhtw_pfx" || exit 1
    assert_contains "$err_zhtw" "$err_zhtw_msg" || exit 1

    exit 0
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

task5_move_conflicts_execution_case() {
  local t
  t=$(mktemp -d "$ROOT/task5-move-exec.XXXXXX") || return 1
  t=$(cd -P "$t" && pwd -P)
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    unset KAISIAN_TESTING_TTY KAISIAN_TESTING_PROMPT_FAIL KAISIAN_TESTING_READ_FAIL KAISIAN_TESTING_ANSWER KAISIAN_TESTING_PROMPT_TRACE_LOG KAISIAN_TESTING_PRE_MV_HOOK KAISIAN_TESTING_FILES_FAIL KAISIAN_TESTING_APPEND_FAIL KAISIAN_TESTING_TRACKING_CREATE_FAIL KAISIAN_MV_EXEC

    hm="$t/home"
    chk="$t/checkout"
    st="$t/state"
    sb="$t/sandbox"
    lk="$t/lock"
    /bin/mkdir -p "$hm" "$chk" "$st" "$sb" "$lk" || exit 1

    HOME="$hm"
    PHYSICAL_HOME="$hm"
    CHECKOUT_DIR="$chk"
    STATE_ROOT="$st"
    SANDBOX="$sb"
    LOCK_DIR="$lk"

    # Setup manifest packages: shell, git, mise, macos
    /bin/mkdir -p "$chk/shell" "$chk/git" "$chk/mise" "$chk/macos/dot-config/app" "$chk/macos/dot-config" || exit 1
    printf 'new_zshrc_payload\n' > "$chk/shell/dot-zshrc"
    printf 'new_gitconfig_payload\n' > "$chk/git/dot-gitconfig"
    /bin/mkdir -p "$chk/mise/dot-config/mise" || exit 1
    printf 'new_mise_toml\n' > "$chk/mise/dot-config/mise/config.toml"
    printf 'new_app_config\n' > "$chk/macos/dot-config/app/config"
    printf 'new_dir_conflict_payload\n' > "$chk/macos/dot-config/dir_conflict"
    printf 'new_broken_payload\n' > "$chk/macos/dot-broken_link"

    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" init -q || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false config user.email test@example.invalid || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false config user.name test || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" add . || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || exit 1

    printf 'shell\tshell\tshell\ngit\tgit\tgit\nmise\tmise\tmise\nmacos\tmacos\tmacos\n' > "$sb/groups.tsv"
    printf 'shell\ngit\nmise\nmacos\n' > "$sb/selected.txt"
    : > "$sb/unselected.txt"

    # Setup conflicting targets in HOME:
    # 1. Regular file: .zshrc
    printf 'old_zshrc_data_12345\n' > "$hm/.zshrc"
    zshrc_ino=$(/usr/bin/stat -f '%i' "$hm/.zshrc")

    # 2. Nested directory & file: .config/app/config
    /bin/mkdir -p "$hm/.config/app" || exit 1
    printf 'old_app_data_98765\n' > "$hm/.config/app/config"
    app_ino=$(/usr/bin/stat -f '%i' "$hm/.config/app/config")

    # 3. Symlink conflict: .gitconfig pointing to external file
    ext_target="$t/external_gitconfig"
    printf 'ext_gitconfig_data\n' > "$ext_target"
    ln -s "$ext_target" "$hm/.gitconfig" || exit 1

    # 4. Conflicting directory in HOME: .config/dir_conflict (directory with file inside, package has file)
    /bin/mkdir -p "$hm/.config/dir_conflict" || exit 1
    printf 'dir_conflict_child_data\n' > "$hm/.config/dir_conflict/child.txt"
    dir_conflict_child_ino=$(/usr/bin/stat -f '%i' "$hm/.config/dir_conflict/child.txt")

    # 5. Conflicting broken symlink: .broken_link with tabs and newlines in target
    broken_dest=$(printf 'broken\ttarget\nwith\tcontrol\n')
    ln -s "$broken_dest" "$hm/.broken_link" || exit 1

    # 6. Non-conflicting regular file in HOME: .unrelated
    printf 'unrelated_data_555\n' > "$hm/.unrelated"
    unrel_ino=$(/usr/bin/stat -f '%i' "$hm/.unrelated")

    # 7. Non-conflicting directory in HOME: .config/other/data
    /bin/mkdir -p "$hm/.config/other" || exit 1
    printf 'other_data_777\n' > "$hm/.config/other/data"
    other_ino=$(/usr/bin/stat -f '%i' "$hm/.config/other/data")

    # 8. Canonical symlink already pointing to exact package source (no conflict): .config/mise/config.toml
    /bin/mkdir -p "$hm/.config/mise" || exit 1
    ln -s "$chk/mise/dot-config/mise/config.toml" "$hm/.config/mise/config.toml" || exit 1

    # Run mapping and preflight
    build_package_map || exit 1
    validate_typed_tree || exit 1
    KAISIAN_TEST_TIME="20260819T080000Z" preflight_targets || exit 1

    # Verify conflicts table has exactly 5 entries
    test -f "$CONFLICTS_FILE" || exit 1
    test "$(wc -l < "$CONFLICTS_FILE" | tr -d ' ')" = "5" || exit 1

    # Run confirmation (--yes)
    ASSUME_YES=1
    DRY_RUN=0
    confirm_conflicts >/dev/null || exit 1
    test "$CONFIRMED" -eq 1 || exit 1

    # Run move_conflicts
    move_conflicts || exit 1

    # Assertions on BACKUP_ROOT
    test -d "$BACKUP_ROOT" || exit 1
    test "$(/usr/bin/stat -f '%Lp' "$BACKUP_ROOT")" = "700" || exit 1
    test -d "$BACKUP_ROOT/files" || exit 1

    # 1. .zshrc moved
    test ! -e "$hm/.zshrc" && test ! -L "$hm/.zshrc" || exit 1
    test -f "$BACKUP_ROOT/files/.zshrc" || exit 1
    test "$(/usr/bin/stat -f '%i' "$BACKUP_ROOT/files/.zshrc")" = "$zshrc_ino" || exit 1
    test "$(cat "$BACKUP_ROOT/files/.zshrc")" = "old_zshrc_data_12345" || exit 1

    # 2. .config/app/config moved
    test ! -e "$hm/.config/app/config" && test ! -L "$hm/.config/app/config" || exit 1
    test -f "$BACKUP_ROOT/files/.config/app/config" || exit 1
    test "$(/usr/bin/stat -f '%i' "$BACKUP_ROOT/files/.config/app/config")" = "$app_ino" || exit 1
    test "$(cat "$BACKUP_ROOT/files/.config/app/config")" = "old_app_data_98765" || exit 1

    # 3. .gitconfig symlink moved
    test ! -e "$hm/.gitconfig" && test ! -L "$hm/.gitconfig" || exit 1
    test -L "$BACKUP_ROOT/files/.gitconfig" || exit 1
    test "$(/usr/bin/readlink "$BACKUP_ROOT/files/.gitconfig")" = "$ext_target" || exit 1

    # 4. .config/dir_conflict directory moved
    test ! -e "$hm/.config/dir_conflict" && test ! -L "$hm/.config/dir_conflict" || exit 1
    test -d "$BACKUP_ROOT/files/.config/dir_conflict" || exit 1
    test -f "$BACKUP_ROOT/files/.config/dir_conflict/child.txt" || exit 1
    test "$(/usr/bin/stat -f '%i' "$BACKUP_ROOT/files/.config/dir_conflict/child.txt")" = "$dir_conflict_child_ino" || exit 1
    test "$(cat "$BACKUP_ROOT/files/.config/dir_conflict/child.txt")" = "dir_conflict_child_data" || exit 1

    # 5. .broken_link broken symlink moved
    test ! -e "$hm/.broken_link" && test ! -L "$hm/.broken_link" || exit 1
    test -L "$BACKUP_ROOT/files/.broken_link" || exit 1
    test "$(/usr/bin/readlink "$BACKUP_ROOT/files/.broken_link")" = "$broken_dest" || exit 1

    # 6. Non-conflicting files untouched
    test -f "$hm/.unrelated" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.unrelated")" = "$unrel_ino" || exit 1
    test "$(cat "$hm/.unrelated")" = "unrelated_data_555" || exit 1

    test -f "$hm/.config/other/data" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.config/other/data")" = "$other_ino" || exit 1
    test "$(cat "$hm/.config/other/data")" = "other_data_777" || exit 1

    # 7. Canonical symlink untouched
    test -L "$hm/.config/mise/config.toml" || exit 1
    test "$(/usr/bin/readlink "$hm/.config/mise/config.toml")" = "$chk/mise/dot-config/mise/config.toml" || exit 1

    # 8. Idempotent re-run: 0 conflicts, no new backup directory
    preflight_targets || exit 1
    test ! -s "$CONFLICTS_FILE" || exit 1
    confirm_conflicts >/dev/null || exit 1
    move_conflicts || exit 1
    backup_count=$(/bin/ls -1 "$st/backups" | wc -l | tr -d ' ')
    test "$backup_count" = "1" || exit 1

    exit 0
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

task5_backup_prefix_validation_case() {
  local t
  t=$(mktemp -d "$ROOT/task5-bk-prefix.XXXXXX") || return 1
  t=$(cd -P "$t" && pwd -P)
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    unset KAISIAN_TESTING_TTY KAISIAN_TESTING_PROMPT_FAIL KAISIAN_TESTING_READ_FAIL KAISIAN_TESTING_ANSWER KAISIAN_TESTING_PROMPT_TRACE_LOG KAISIAN_TESTING_PRE_MV_HOOK KAISIAN_TESTING_FILES_FAIL KAISIAN_TESTING_APPEND_FAIL KAISIAN_TESTING_TRACKING_CREATE_FAIL KAISIAN_MV_EXEC

    # 1. Non-matching backup prefix: $BACKUP_ROOT/other/.zshrc with isolated roots
    t1="$t/case1"
    /bin/mkdir -p "$t1/home" "$t1/state" "$t1/sandbox" || exit 1
    HOME="$t1/home" PHYSICAL_HOME="$t1/home" STATE_ROOT="$t1/state" SANDBOX="$t1/sandbox"
    CONFLICTS_FILE="$t1/sandbox/conflicts.tsv" BACKUP_ROOT="$t1/state/backups/20260819T090001Z-1"
    printf 'test_zshrc_1\n' > "$t1/home/.zshrc"
    zshrc_ino_1=$(/usr/bin/stat -f '%i' "$t1/home/.zshrc")
    printf '%s\t%s\n' "$t1/home/.zshrc" "$BACKUP_ROOT/other/.zshrc" > "$CONFLICTS_FILE"
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t1/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1
    test -f "$t1/home/.zshrc" || exit 1
    test "$(/usr/bin/stat -f '%i' "$t1/home/.zshrc")" = "$zshrc_ino_1" || exit 1

    # 2. Traversal in backup path: $BACKUP_ROOT/files/../../outside
    t2="$t/case2"
    /bin/mkdir -p "$t2/home" "$t2/state" "$t2/sandbox" || exit 1
    HOME="$t2/home" PHYSICAL_HOME="$t2/home" STATE_ROOT="$t2/state" SANDBOX="$t2/sandbox"
    CONFLICTS_FILE="$t2/sandbox/conflicts.tsv" BACKUP_ROOT="$t2/state/backups/20260819T090002Z-2"
    printf 'test_zshrc_2\n' > "$t2/home/.zshrc"
    zshrc_ino_2=$(/usr/bin/stat -f '%i' "$t2/home/.zshrc")
    printf '%s\t%s\n' "$t2/home/.zshrc" "$BACKUP_ROOT/files/../../outside" > "$CONFLICTS_FILE"
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t2/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1
    test -f "$t2/home/.zshrc" || exit 1
    test "$(/usr/bin/stat -f '%i' "$t2/home/.zshrc")" = "$zshrc_ino_2" || exit 1

    # 3. Generic /files/ prefix without $BACKUP_ROOT
    t3="$t/case3"
    /bin/mkdir -p "$t3/home" "$t3/state" "$t3/sandbox" || exit 1
    HOME="$t3/home" PHYSICAL_HOME="$t3/home" STATE_ROOT="$t3/state" SANDBOX="$t3/sandbox"
    CONFLICTS_FILE="$t3/sandbox/conflicts.tsv" BACKUP_ROOT="$t3/state/backups/20260819T090003Z-3"
    printf 'test_zshrc_3\n' > "$t3/home/.zshrc"
    zshrc_ino_3=$(/usr/bin/stat -f '%i' "$t3/home/.zshrc")
    printf '%s\t%s\n' "$t3/home/.zshrc" "/files/.zshrc" > "$CONFLICTS_FILE"
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t3/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1
    test -f "$t3/home/.zshrc" || exit 1
    test "$(/usr/bin/stat -f '%i' "$t3/home/.zshrc")" = "$zshrc_ino_3" || exit 1

    # 4. Source outside PHYSICAL_HOME
    t4="$t/case4"
    /bin/mkdir -p "$t4/home" "$t4/state" "$t4/sandbox" "$t4/outside" || exit 1
    HOME="$t4/home" PHYSICAL_HOME="$t4/home" STATE_ROOT="$t4/state" SANDBOX="$t4/sandbox"
    CONFLICTS_FILE="$t4/sandbox/conflicts.tsv" BACKUP_ROOT="$t4/state/backups/20260819T090004Z-4"
    printf 'outside\n' > "$t4/outside/file"
    printf '%s\t%s\n' "$t4/outside/file" "$BACKUP_ROOT/files/file" > "$CONFLICTS_FILE"
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t4/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 5. Source does not exist
    t5="$t/case5"
    /bin/mkdir -p "$t5/home" "$t5/state" "$t5/sandbox" || exit 1
    HOME="$t5/home" PHYSICAL_HOME="$t5/home" STATE_ROOT="$t5/state" SANDBOX="$t5/sandbox"
    CONFLICTS_FILE="$t5/sandbox/conflicts.tsv" BACKUP_ROOT="$t5/state/backups/20260819T090005Z-5"
    printf '%s\t%s\n' "$t5/home/.nonexistent" "$BACKUP_ROOT/files/.nonexistent" > "$CONFLICTS_FILE"
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t5/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 6. Pre-existing BACKUP_ROOT reservation collision
    t6="$t/case6"
    /bin/mkdir -p "$t6/home" "$t6/state" "$t6/sandbox" || exit 1
    HOME="$t6/home" PHYSICAL_HOME="$t6/home" STATE_ROOT="$t6/state" SANDBOX="$t6/sandbox"
    CONFLICTS_FILE="$t6/sandbox/conflicts.tsv" BACKUP_ROOT="$t6/state/backups/20260819T090006Z-6"
    /bin/mkdir -p "$BACKUP_ROOT" || exit 1
    printf 'test_zshrc_6\n' > "$t6/home/.zshrc"
    zshrc_ino_6=$(/usr/bin/stat -f '%i' "$t6/home/.zshrc")
    printf '%s\t%s\n' "$t6/home/.zshrc" "$BACKUP_ROOT/files/.zshrc" > "$CONFLICTS_FILE"
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test -f "$t6/home/.zshrc" || exit 1

    # 7. Missing sidecar file aborts before root/move
    t7="$t/case7"
    /bin/mkdir -p "$t7/home" "$t7/state" "$t7/sandbox" || exit 1
    HOME="$t7/home" PHYSICAL_HOME="$t7/home" STATE_ROOT="$t7/state" SANDBOX="$t7/sandbox"
    CONFLICTS_FILE="$t7/sandbox/conflicts.tsv" BACKUP_ROOT="$t7/state/backups/20260819T090007Z-7"
    printf 'test_zshrc_7\n' > "$t7/home/.zshrc"
    printf '%s\t%s\n' "$t7/home/.zshrc" "$BACKUP_ROOT/files/.zshrc" > "$CONFLICTS_FILE"
    # No sidecar file
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t7/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 8. Truncated sidecar file (cardinality mismatch) aborts before root/move
    t8="$t/case8"
    /bin/mkdir -p "$t8/home" "$t8/state" "$t8/sandbox" || exit 1
    HOME="$t8/home" PHYSICAL_HOME="$t8/home" STATE_ROOT="$t8/state" SANDBOX="$t8/sandbox"
    CONFLICTS_FILE="$t8/sandbox/conflicts.tsv" BACKUP_ROOT="$t8/state/backups/20260819T090008Z-8"
    printf 'test_zshrc_8a\n' > "$t8/home/.zshrc"
    printf 'test_zshrc_8b\n' > "$t8/home/.other"
    printf '%s\t%s\n' "$t8/home/.zshrc" "$BACKUP_ROOT/files/.zshrc" > "$CONFLICTS_FILE"
    printf '%s\t%s\n' "$t8/home/.other" "$BACKUP_ROOT/files/.other" >> "$CONFLICTS_FILE"
    # Sidecar only has 1 row for 2 conflicts
    dev8=$(stat_dev "$t8/home/.zshrc")
    ino8=$(/usr/bin/stat -f '%i' "$t8/home/.zshrc")
    printf '%s\t%s\t%s\t%s\t%s\n' "$t8/home/.zshrc" "$dev8" "$ino8" "Regular File" "100644" > "$t8/sandbox/conflicts_identities.tsv"
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t8/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 9. Duplicate sidecar rows abort before root/move
    t9="$t/case9"
    /bin/mkdir -p "$t9/home" "$t9/state" "$t9/sandbox" || exit 1
    HOME="$t9/home" PHYSICAL_HOME="$t9/home" STATE_ROOT="$t9/state" SANDBOX="$t9/sandbox"
    CONFLICTS_FILE="$t9/sandbox/conflicts.tsv" BACKUP_ROOT="$t9/state/backups/20260819T090009Z-9"
    printf 'test_zshrc_9\n' > "$t9/home/.zshrc"
    printf '%s\t%s\n' "$t9/home/.zshrc" "$BACKUP_ROOT/files/.zshrc" > "$CONFLICTS_FILE"
    dev9=$(stat_dev "$t9/home/.zshrc")
    ino9=$(/usr/bin/stat -f '%i' "$t9/home/.zshrc")
    printf '%s\t%s\t%s\t%s\t%s\n' "$t9/home/.zshrc" "$dev9" "$ino9" "Regular File" "100644" > "$t9/sandbox/conflicts_identities.tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' "$t9/home/.zshrc" "$dev9" "$ino9" "Regular File" "100644" >> "$t9/sandbox/conflicts_identities.tsv"
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t9/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1
    test "$(/usr/bin/stat -f '%i' "$t6/home/.zshrc")" = "$zshrc_ino_6" || exit 1
    exit 0
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}
task5_toctou_premutation_rejection_case() {
  local t
  t=$(mktemp -d "$ROOT/task5-toctou.XXXXXX") || return 1
  t=$(cd -P "$t" && pwd -P)
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    unset KAISIAN_TESTING_TTY KAISIAN_TESTING_PROMPT_FAIL KAISIAN_TESTING_READ_FAIL KAISIAN_TESTING_ANSWER KAISIAN_TESTING_PROMPT_TRACE_LOG KAISIAN_TESTING_PRE_MV_HOOK KAISIAN_TESTING_FILES_FAIL KAISIAN_TESTING_APPEND_FAIL KAISIAN_TESTING_TRACKING_CREATE_FAIL KAISIAN_MV_EXEC

    chk="$t/checkout"
    /bin/mkdir -p "$chk/pkg1" "$chk/pkg2/dot-config/app" || exit 1
    printf 'pkg1_payload\n' > "$chk/pkg1/dot-zshrc"
    printf 'pkg2_payload\n' > "$chk/pkg2/dot-config/app/config"
    printf 'gitconfig_payload\n' > "$chk/pkg1/dot-gitconfig"

    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" init -q || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false config user.email test@example.invalid || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false config user.name test || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" add . || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$chk" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm fixture || exit 1

    # 1. TOCTOU Swap: Source parent swapped to symlink after confirmation
    t1="$t/toctou_parent"
    /bin/mkdir -p "$t1/home/.config/app" "$t1/state" "$t1/sandbox" "$t1/real_app" "$t1/lock" || exit 1
    printf 'old_app\n' > "$t1/home/.config/app/config"
    printf 'old_zshrc\n' > "$t1/home/.zshrc"
    printf 'pkg1\tpkg1\tpkg1\npkg2\tpkg2\tpkg2\n' > "$t1/sandbox/groups.tsv"
    printf 'pkg1\npkg2\n' > "$t1/sandbox/selected.txt"
    : > "$t1/sandbox/unselected.txt"
    HOME="$t1/home" PHYSICAL_HOME="$t1/home" CHECKOUT_DIR="$chk" STATE_ROOT="$t1/state" SANDBOX="$t1/sandbox" LOCK_DIR="$t1/lock"
    build_package_map || exit 1
    validate_typed_tree || exit 1
    KAISIAN_TEST_TIME="20260819T120000Z" preflight_targets || exit 1
    mv "$t1/home/.config/app" "$t1/real_app/app" || exit 1
    ln -s "$t1/real_app/app" "$t1/home/.config/app" || exit 1
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t1/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 2. TOCTOU Swap: Source regular file replaced with FIFO / special node
    t2="$t/toctou_fifo"
    /bin/mkdir -p "$t2/home/.config/app" "$t2/state" "$t2/sandbox" "$t2/lock" || exit 1
    printf 'old_app\n' > "$t2/home/.config/app/config"
    printf 'old_zshrc\n' > "$t2/home/.zshrc"
    printf 'pkg1\tpkg1\tpkg1\npkg2\tpkg2\tpkg2\n' > "$t2/sandbox/groups.tsv"
    printf 'pkg1\npkg2\n' > "$t2/sandbox/selected.txt"
    : > "$t2/sandbox/unselected.txt"
    HOME="$t2/home" PHYSICAL_HOME="$t2/home" CHECKOUT_DIR="$chk" STATE_ROOT="$t2/state" SANDBOX="$t2/sandbox" LOCK_DIR="$t2/lock"
    build_package_map || exit 1
    validate_typed_tree || exit 1
    KAISIAN_TEST_TIME="20260819T120001Z" preflight_targets || exit 1
    rm -f "$t2/home/.zshrc" || exit 1
    mkfifo "$t2/home/.zshrc" || exit 1
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t2/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 3. TOCTOU Swap: Source symlink target swapped after confirmation
    t3="$t/toctou_symlink"
    /bin/mkdir -p "$t3/home" "$t3/state" "$t3/sandbox" "$t3/lock" || exit 1
    ext1="$t3/ext1"
    ext2="$t3/ext2"
    printf 'ext1\n' > "$ext1"
    printf 'ext2\n' > "$ext2"
    ln -s "$ext1" "$t3/home/.gitconfig" || exit 1
    printf 'old_zshrc\n' > "$t3/home/.zshrc"
    printf 'pkg1\tpkg1\tpkg1\npkg2\tpkg2\tpkg2\n' > "$t3/sandbox/groups.tsv"
    printf 'pkg1\npkg2\n' > "$t3/sandbox/selected.txt"
    : > "$t3/sandbox/unselected.txt"
    HOME="$t3/home" PHYSICAL_HOME="$t3/home" CHECKOUT_DIR="$chk" STATE_ROOT="$t3/state" SANDBOX="$t3/sandbox" LOCK_DIR="$t3/lock"
    build_package_map || exit 1
    validate_typed_tree || exit 1
    KAISIAN_TEST_TIME="20260819T120002Z" preflight_targets || exit 1
    rm -f "$t3/home/.gitconfig" || exit 1
    ln -s "$ext2" "$t3/home/.gitconfig" || exit 1
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t3/state/backups" || exit 1
    test ! -e "$BACKUP_ROOT" || exit 1

    # 4. TOCTOU Swap: Backup intermediate directory swapped to symlink after confirmation
    t4="$t/toctou_bk_ancestor"
    /bin/mkdir -p "$t4/home/.config/app" "$t4/state/backups/sub" "$t4/sandbox" "$t4/outside" "$t4/lock" || exit 1
    printf 'old_zshrc\n' > "$t4/home/.zshrc"
    printf 'pkg1\tpkg1\tpkg1\npkg2\tpkg2\tpkg2\n' > "$t4/sandbox/groups.tsv"
    printf 'pkg1\npkg2\n' > "$t4/sandbox/selected.txt"
    : > "$t4/sandbox/unselected.txt"
    HOME="$t4/home" PHYSICAL_HOME="$t4/home" STATE_ROOT="$t4/state" SANDBOX="$t4/sandbox" LOCK_DIR="$t4/lock"
    build_package_map || exit 1
    validate_typed_tree || exit 1
    KAISIAN_TEST_TIME="20260819T120003Z" preflight_targets || exit 1
    rm -rf "$t4/state/backups" || exit 1
    ln -s "$t4/outside" "$t4/state/backups" || exit 1
    ( move_conflicts ) >/dev/null 2>&1 && exit 1
    test ! -e "$t4/outside/files" || exit 1
    # 5. TOCTOU Swap during Pass 2 immediately before 2nd mv (using KAISIAN_TESTING_PRE_MV_HOOK)
    t5="$t/toctou_pre_mv"
    /bin/mkdir -p "$t5/home/.config/app" "$t5/state" "$t5/sandbox" "$t5/lock" || exit 1
    printf 'f1_data\n' > "$t5/home/.zshrc"
    f1_ino_5=$(/usr/bin/stat -f '%i' "$t5/home/.zshrc")
    printf 'f2_data\n' > "$t5/home/.config/app/config"
    printf 'pkg1\tpkg1\tpkg1\npkg2\tpkg2\tpkg2\n' > "$t5/sandbox/groups.tsv"
    printf 'pkg1\npkg2\n' > "$t5/sandbox/selected.txt"
    : > "$t5/sandbox/unselected.txt"
    HOME="$t5/home" PHYSICAL_HOME="$t5/home" CHECKOUT_DIR="$chk" STATE_ROOT="$t5/state" SANDBOX="$t5/sandbox" LOCK_DIR="$t5/lock"
    build_package_map || exit 1
    validate_typed_tree || exit 1
    KAISIAN_TEST_TIME="20260819T120005Z" preflight_targets || exit 1

    # Hook triggers before 2nd mv: swaps .config/app/config to a FIFO
    pre_mv_hook="if test -f '$t5/home/.config/app/config'; then rm -f '$t5/home/.config/app/config' && mkfifo '$t5/home/.config/app/config'; fi"

    err_premvh=$(
      CONFIRMED=1
      KAISIAN_TESTING_PRE_MV_HOOK="$pre_mv_hook" move_conflicts 2>&1
    )
    test $? -eq 1 || exit 1

    # Assert .zshrc (1st conflict) was moved and is preserved in backup
    test ! -e "$t5/home/.zshrc" || exit 1
    test -f "$BACKUP_ROOT/files/.zshrc" || exit 1
    test "$(/usr/bin/stat -f '%i' "$BACKUP_ROOT/files/.zshrc")" = "$f1_ino_5" || exit 1

    # Assert restore guidance ONLY emitted for .zshrc, not for the swapped item
    assert_contains "$err_premvh" "Backup root: $BACKUP_ROOT" || exit 1
    assert_contains "$err_premvh" "Restore manually with: mv '$BACKUP_ROOT/files/.zshrc' '$t5/home/.zshrc'" || exit 1
    if printf '%s\n' "$err_premvh" | /usr/bin/grep -q "Restore manually with: mv.*app/config"; then
      exit 1
    fi


    exit 0
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

task5_partial_failure_and_preservation_case() {
  local t
  t=$(mktemp -d "$ROOT/task5-partial-fail.XXXXXX") || return 1
  t=$(cd -P "$t" && pwd -P)
  (
    export KAISIAN_TESTING=1
    . "$SCRIPT"
    unset KAISIAN_TESTING_TTY KAISIAN_TESTING_PROMPT_FAIL KAISIAN_TESTING_READ_FAIL KAISIAN_TESTING_ANSWER KAISIAN_TESTING_PROMPT_TRACE_LOG KAISIAN_TESTING_PRE_MV_HOOK KAISIAN_TESTING_FILES_FAIL KAISIAN_TESTING_APPEND_FAIL KAISIAN_TESTING_TRACKING_CREATE_FAIL KAISIAN_MV_EXEC

    hm="$t/home"
    st="$t/state"
    sb="$t/sandbox"
    mock_bin="$t/mockbin"
    /bin/mkdir -p "$hm" "$st" "$sb" "$mock_bin" || exit 1

    HOME="$hm"
    PHYSICAL_HOME="$hm"
    STATE_ROOT="$st"
    SANDBOX="$sb"
    CONFLICTS_FILE="$sb/conflicts.tsv"
    BACKUP_ROOT="$st/backups/20260819T100000Z-300"

    # Setup 3 conflicting files
    printf 'file1_data\n' > "$hm/.file1"
    printf 'file2_data\n' > "$hm/.file2"
    printf 'file3_data\n' > "$hm/.file3"

    f1_ino=$(/usr/bin/stat -f '%i' "$hm/.file1")
    f2_ino=$(/usr/bin/stat -f '%i' "$hm/.file2")
    f3_ino=$(/usr/bin/stat -f '%i' "$hm/.file3")

    printf '%s\t%s\n' "$hm/.file1" "$BACKUP_ROOT/files/.file1" > "$CONFLICTS_FILE"
    printf '%s\t%s\n' "$hm/.file2" "$BACKUP_ROOT/files/.file2" >> "$CONFLICTS_FILE"
    printf '%s\t%s\n' "$hm/.file3" "$BACKUP_ROOT/files/.file3" >> "$CONFLICTS_FILE"
    f1_mode=$(/usr/bin/stat -f '%p' "$hm/.file1")
    f2_mode=$(/usr/bin/stat -f '%p' "$hm/.file2")
    f3_mode=$(/usr/bin/stat -f '%p' "$hm/.file3")
    dev1=$(stat_dev "$hm/.file1")
    dev2=$(stat_dev "$hm/.file2")
    dev3=$(stat_dev "$hm/.file3")
    printf '%s\t%s\t%s\t%s\t%s\n' "$hm/.file1" "$dev1" "$f1_ino" "Regular File" "$f1_mode" > "$sb/conflicts_identities.tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' "$hm/.file2" "$dev2" "$f2_ino" "Regular File" "$f2_mode" >> "$sb/conflicts_identities.tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' "$hm/.file3" "$dev3" "$f3_ino" "Regular File" "$f3_mode" >> "$sb/conflicts_identities.tsv"

    # Create mock mv that succeeds on .file1 and fails on .file2
    trace_log="$t/mv_trace.log"
    : > "$trace_log"
    cat << MOCK_MV > "$mock_bin/mv"
#!/bin/bash
printf 'mv %s %s\n' "\$1" "\$2" >> "$trace_log"
if test "\$1" = "$hm/.file2"; then
  exit 1
fi
/bin/mv "\$@"
MOCK_MV
    chmod +x "$mock_bin/mv"

    # 1. Run under LANGUAGE=en
    CONFIRMED=1
    DRY_RUN=0
    KAISIAN_MV_EXEC="$mock_bin/mv"
    LANGUAGE=en

    err_out=$(
      CONFIRMED=1
      move_conflicts 2>&1
    ) || st_err=$?
    test "${st_err-0}" -eq 1 || exit 1

    # Assertions on partial preservation:
    # a. BACKUP_ROOT is kept and not deleted
    test -d "$BACKUP_ROOT" || exit 1
    test -d "$BACKUP_ROOT/files" || exit 1

    # b. file1 was moved and is preserved in backup with original inode and content
    test ! -e "$hm/.file1" || exit 1
    test -f "$BACKUP_ROOT/files/.file1" || exit 1
    test "$(/usr/bin/stat -f '%i' "$BACKUP_ROOT/files/.file1")" = "$f1_ino" || exit 1
    test "$(cat "$BACKUP_ROOT/files/.file1")" = "file1_data" || exit 1

    # c. file2 and file3 remain in home untouched with original inodes and content
    test -f "$hm/.file2" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.file2")" = "$f2_ino" || exit 1
    test "$(cat "$hm/.file2")" = "file2_data" || exit 1

    test -f "$hm/.file3" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm/.file3")" = "$f3_ino" || exit 1
    test "$(cat "$hm/.file3")" = "file3_data" || exit 1

    # d. file2 and file3 are not in backup
    test ! -e "$BACKUP_ROOT/files/.file2" || exit 1
    test ! -e "$BACKUP_ROOT/files/.file3" || exit 1

    root_occurrences=$(printf '%s\n' "$err_out" | /usr/bin/grep -E -c '^(Error|錯誤): (Backup root|備份根目錄)')
    test "$root_occurrences" -eq 1 || exit 1

    assert_contains "$err_out" "Restore manually with: mv '$BACKUP_ROOT/files/.file1' '$hm/.file1'" || exit 1
    if printf '%s\n' "$err_out" | /usr/bin/grep -q "Restore manually with: mv.*\.file2"; then
      exit 1
    fi
    if printf '%s\n' "$err_out" | /usr/bin/grep -q "Restore manually with: mv.*\.file3"; then
      exit 1
    fi

    # f. Assert no cp, rsync, rm, or rollback was executed
    if /usr/bin/grep -E -w -q -- 'cp|rsync|rm' "$trace_log"; then
      exit 1
    fi

    # 1g. Tracking file create/truncate failure before reservation
    t_track_fail=$(mktemp -d "$t/track_fail.XXXXXX")
    t_track_fail=$(cd -P "$t_track_fail" && pwd -P)
    /bin/mkdir -p "$t_track_fail/home" "$t_track_fail/state" "$t_track_fail/sandbox" || exit 1
    bk_tf="$t_track_fail/state/backups/20260819T100000Z-tf"
    printf 'tf_data\n' > "$t_track_fail/home/.file"
    printf '%s\t%s\n' "$t_track_fail/home/.file" "$bk_tf/files/.file" > "$t_track_fail/sandbox/conflicts.tsv"
    dev_tf=$(stat_dev "$t_track_fail/home/.file")
    ino_tf=$(/usr/bin/stat -f '%i' "$t_track_fail/home/.file")
    mode_tf=$(/usr/bin/stat -f '%p' "$t_track_fail/home/.file")
    printf '%s\t%s\t%s\t%s\t%s\n' "$t_track_fail/home/.file" "$dev_tf" "$ino_tf" "Regular File" "$mode_tf" > "$t_track_fail/sandbox/conflicts_identities.tsv"
    (
      CONFIRMED=1
      KAISIAN_TESTING_TRACKING_CREATE_FAIL=1 move_conflicts
    ) >/dev/null 2>&1 && exit 1
    test ! -e "$t_track_fail/state/backups" || exit 1
    test ! -e "$bk_tf" || exit 1
    test -f "$t_track_fail/home/.file" || exit 1

    # 1h. Tracking file append failure after mv succeeds derives recovery from filesystem state
    t_app_fail=$(mktemp -d "$t/app_fail.XXXXXX")
    t_app_fail=$(cd -P "$t_app_fail" && pwd -P)
    /bin/mkdir -p "$t_app_fail/home" "$t_app_fail/state" "$t_app_fail/sandbox" || exit 1
    bk_af="$t_app_fail/state/backups/20260819T100000Z-af"
    printf 'af_data\n' > "$t_app_fail/home/.file"
    printf '%s\t%s\n' "$t_app_fail/home/.file" "$bk_af/files/.file" > "$t_app_fail/sandbox/conflicts.tsv"
    dev_af=$(stat_dev "$t_app_fail/home/.file")
    ino_af=$(/usr/bin/stat -f '%i' "$t_app_fail/home/.file")
    mode_af=$(/usr/bin/stat -f '%p' "$t_app_fail/home/.file")
    printf '%s\t%s\t%s\t%s\t%s\n' "$t_app_fail/home/.file" "$dev_af" "$ino_af" "Regular File" "$mode_af" > "$t_app_fail/sandbox/conflicts_identities.tsv"
    HOME="$t_app_fail/home" PHYSICAL_HOME="$t_app_fail/home" STATE_ROOT="$t_app_fail/state" SANDBOX="$t_app_fail/sandbox" CONFLICTS_FILE="$t_app_fail/sandbox/conflicts.tsv" BACKUP_ROOT="$bk_af"
    err_af=$(
      CONFIRMED=1
      KAISIAN_TESTING_APPEND_FAIL=1 move_conflicts 2>&1
    ) || st_af=$?
    test "${st_af-0}" -eq 1 || exit 1
    assert_contains "$err_af" "Backup root: $bk_af" || exit 1
    assert_contains "$err_af" "Restore manually with: mv '$bk_af/files/.file' '$t_app_fail/home/.file'" || exit 1
    # 2. Initial files directory creation failure reports root and 0 restore commands
    t_files_fail=$(mktemp -d "$t/files_fail.XXXXXX")
    t_files_fail=$(cd -P "$t_files_fail" && pwd -P)
    /bin/mkdir -p "$t_files_fail/home" "$t_files_fail/state" "$t_files_fail/sandbox" || exit 1
    bk_ff="$t_files_fail/state/backups/20260819T100001Z-ff"
    printf 'data\n' > "$t_files_fail/home/.file"
    printf '%s\t%s\n' "$t_files_fail/home/.file" "$bk_ff/files/.file" > "$t_files_fail/sandbox/conflicts.tsv"
    dev_ff=$(stat_dev "$t_files_fail/home/.file")
    ino_ff=$(/usr/bin/stat -f '%i' "$t_files_fail/home/.file")
    mode_ff=$(/usr/bin/stat -f '%p' "$t_files_fail/home/.file")
    printf '%s\t%s\t%s\t%s\t%s\n' "$t_files_fail/home/.file" "$dev_ff" "$ino_ff" "Regular File" "$mode_ff" > "$t_files_fail/sandbox/conflicts_identities.tsv"
    HOME="$t_files_fail/home" PHYSICAL_HOME="$t_files_fail/home" STATE_ROOT="$t_files_fail/state" SANDBOX="$t_files_fail/sandbox" CONFLICTS_FILE="$t_files_fail/sandbox/conflicts.tsv" BACKUP_ROOT="$bk_ff"
    err_ff=$(
      CONFIRMED=1
      KAISIAN_TESTING_FILES_FAIL=1 move_conflicts 2>&1
    ) || st_ff=$?
    test "${st_ff-0}" -eq 1 || exit 1
    assert_contains "$err_ff" "Backup root: $bk_ff" || exit 1
    if printf '%s\n' "$err_ff" | /usr/bin/grep -q "Restore manually with:"; then
      exit 1
    fi

    # 3. Apostrophe-path shell quoting & recovery execution test
    t_apo=$(mktemp -d "$t/apo_test.XXXXXX")
    t_apo=$(cd -P "$t_apo" && pwd -P)
    /bin/mkdir -p "$t_apo/home/Bob's Config" "$t_apo/state" "$t_apo/sandbox" || exit 1
    hm_apo="$t_apo/home"
    st_apo="$t_apo/state"
    sb_apo="$t_apo/sandbox"
    bk_apo="$st_apo/backups/20260819T100002Z-apo"

    printf 'apostrophe_config_payload\n' > "$hm_apo/Bob's Config/app.conf"
    apo_ino=$(/usr/bin/stat -f '%i' "$hm_apo/Bob's Config/app.conf")
    apo_mode=$(/usr/bin/stat -f '%p' "$hm_apo/Bob's Config/app.conf")
    printf 'fail_payload\n' > "$hm_apo/.fail_target"
    fail_ino=$(/usr/bin/stat -f '%i' "$hm_apo/.fail_target")
    fail_mode=$(/usr/bin/stat -f '%p' "$hm_apo/.fail_target")

    printf '%s\t%s\n' "$hm_apo/Bob's Config/app.conf" "$bk_apo/files/Bob's Config/app.conf" > "$sb_apo/conflicts.tsv"
    printf '%s\t%s\n' "$hm_apo/.fail_target" "$bk_apo/files/.fail_target" >> "$sb_apo/conflicts.tsv"

    dev_apo1=$(stat_dev "$hm_apo/Bob's Config/app.conf")
    dev_apo2=$(stat_dev "$hm_apo/.fail_target")
    printf '%s\t%s\t%s\t%s\t%s\n' "$hm_apo/Bob's Config/app.conf" "$dev_apo1" "$apo_ino" "Regular File" "$apo_mode" > "$sb_apo/conflicts_identities.tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' "$hm_apo/.fail_target" "$dev_apo2" "$fail_ino" "Regular File" "$fail_mode" >> "$sb_apo/conflicts_identities.tsv"

    cat << MOCK_APO_MV > "$mock_bin/mv_apo"
#!/bin/bash
if test "\$1" = "$hm_apo/.fail_target"; then
  exit 1
fi
/bin/mv "\$@"
MOCK_APO_MV
    chmod +x "$mock_bin/mv_apo"

    HOME="$hm_apo" PHYSICAL_HOME="$hm_apo" STATE_ROOT="$st_apo" SANDBOX="$sb_apo" CONFLICTS_FILE="$sb_apo/conflicts.tsv" BACKUP_ROOT="$bk_apo" LANGUAGE=en

    err_apo=$(
      CONFIRMED=1
      KAISIAN_MV_EXEC="$mock_bin/mv_apo" move_conflicts 2>&1
    ) || st_apo=$?
    test "${st_apo-0}" -eq 1 || exit 1

    # Verify Bob's Config/app.conf was moved
    test ! -e "$hm_apo/Bob's Config/app.conf" || exit 1
    test -f "$bk_apo/files/Bob's Config/app.conf" || exit 1

    # Extract restore command line
    restore_line=$(printf '%s\n' "$err_apo" | /usr/bin/grep "Restore manually with: mv ")
    test -n "$restore_line" || exit 1
    restore_cmd=${restore_line#*Restore manually with: }

    ( eval "$restore_cmd" ) || exit 1

    # Assert file is safely restored to HOME
    test -f "$hm_apo/Bob's Config/app.conf" || exit 1
    test "$(/usr/bin/stat -f '%i' "$hm_apo/Bob's Config/app.conf")" = "$apo_ino" || exit 1
    test "$(cat "$hm_apo/Bob's Config/app.conf")" = "apostrophe_config_payload" || exit 1

    # 4. Test localized error messages under LANGUAGE=zh-TW on another failure setup
    t2=$(mktemp -d "$t/zhtw.XXXXXX")
    t2=$(cd -P "$t2" && pwd -P)
    /bin/mkdir -p "$t2/home" "$t2/state" "$t2/sandbox" || exit 1
    hm2="$t2/home"
    st2="$t2/state"
    sb2="$t2/sandbox"
    bk2="$st2/backups/20260819T110000Z-400"
    printf 'f2\n' > "$hm2/.file"
    printf '%s\t%s\n' "$hm2/.file" "$bk2/files/.file" > "$sb2/conflicts.tsv"
    dev2=$(stat_dev "$hm2/.file")
    ino2=$(/usr/bin/stat -f '%i' "$hm2/.file")
    mode2=$(/usr/bin/stat -f '%p' "$hm2/.file")
    printf '%s\t%s\t%s\t%s\t%s\n' "$hm2/.file" "$dev2" "$ino2" "Regular File" "$mode2" > "$sb2/conflicts_identities.tsv"
    HOME="$hm2"
    PHYSICAL_HOME="$hm2"
    STATE_ROOT="$st2"
    SANDBOX="$sb2"
    CONFLICTS_FILE="$sb2/conflicts.tsv"
    BACKUP_ROOT="$bk2"
    LANGUAGE=zh-TW

    cat << 'MOCK_FAIL' > "$mock_bin/mv_fail"
#!/bin/bash
exit 1
MOCK_FAIL
    chmod +x "$mock_bin/mv_fail"

    err_zhtw_out=$(
      CONFIRMED=1
      KAISIAN_MV_EXEC="$mock_bin/mv_fail" move_conflicts 2>&1
    ) || st_zhtw=$?
    test "${st_zhtw-0}" -eq 1 || exit 1
    assert_contains "$err_zhtw_out" "備份根目錄：$bk2" || exit 1
    # 0 restore commands because mv_fail failed on the first item
    if printf '%s\n' "$err_zhtw_out" | /usr/bin/grep -q "手動還原指令："; then
      exit 1
    fi

    exit 0
  )
  status=$?
  /bin/rm -rf "$t"
  return "$status"
}

run_case 'Task 5 preflight target classification and exact conflict planning' task5_preflight_targets_classification_case
run_case 'Task 5 preflight target rejection for symlink parents and special nodes' task5_preflight_targets_rejection_case
run_case 'Task 5 preflight unselected package filtering' task5_preflight_selection_filtering_case
run_case 'Task 5 preflight XDG_STATE_HOME and state root validation' task5_preflight_state_root_validation_case
run_case 'Task 5 preflight path overlap matrix and sibling acceptance' task5_preflight_overlap_matrix_case
run_case 'Task 5 preflight cross-device stat validation rejection' task5_preflight_cross_device_case
run_case 'Task 5 confirm conflicts matrix and TTY prompt cancellation' task5_confirm_conflicts_matrix_case
run_case 'Task 5 move conflicts execution, inode preservation, and idempotency' task5_move_conflicts_execution_case
run_case 'Task 5 backup prefix validation and reservation safety' task5_backup_prefix_validation_case
run_case 'Task 5 TOCTOU pre-mutation rejection for parent swaps, FIFOs, symlink target swaps, and backup ancestors' task5_toctou_premutation_rejection_case
run_case 'Task 5 partial failure preservation and manual restore guidance' task5_partial_failure_and_preservation_case

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
