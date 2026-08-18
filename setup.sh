#!/bin/bash
set -u

readonly KAISIAN_VERSION='0.1.0'
readonly DEFAULT_REPOSITORY='taiansu/dotfiles'
readonly DEFAULT_DOTFILES_COMMIT='0b3b0c3f206e1f4fb35dac82794a871c5c18f405'

LANGUAGE='en'
PHYSICAL_HOME=''
CHECKOUT_DIR=''
STATE_ROOT=''
LOCK_DIR=''
SANDBOX=''
DRY_RUN=0
ASSUME_YES=0
SELECTION_MODE='none'
SELECTION_VALUE=''
REPOSITORY="$DEFAULT_REPOSITORY"
REQUESTED_REF="$DEFAULT_DOTFILES_COMMIT"
RECORDED_LOCK_DEV_INO=''
RECORDED_SANDBOX_DEV_INO=''
GIT_EXEC=''
STOW_EXEC=''
FZF_EXEC=''
PLUTIL_EXEC=''

usage() {
  printf '%s\n' \
'setup.sh [OPTIONS]

Selection, exactly zero or one:
  --profile NAME
  --groups GROUPS
  --interactive
  --all

Source and execution:
  --repo URL|OWNER/REPO
  --ref REF
  --repo-dir PATH
  --lang en|zh-TW
  --dry-run
  --yes
  -h, --help'
}

resolve_language() {
  if test $# -gt 0 && test -n "${1-}"; then
    case "$1" in
      en) LANGUAGE='en'; return 0 ;;
      zh-TW) LANGUAGE='zh-TW'; return 0 ;;
      *) return 1 ;;
    esac
  fi

  raw_loc=''
  if test -n "${LC_ALL-}"; then
    raw_loc="$LC_ALL"
  elif test -n "${LC_MESSAGES-}"; then
    raw_loc="$LC_MESSAGES"
  elif test -n "${LANG-}"; then
    raw_loc="$LANG"
  fi

  case "$raw_loc" in
    zh*|ZH*) LANGUAGE='zh-TW' ;;
    *) LANGUAGE='en' ;;
  esac
  return 0
}

message_en() {
  key=${1-}
  shift || true
  case "$key" in
    error_prefix) printf 'Error' ;;
    missing_tools) printf 'Missing required commands: %s' "${1-}" ;;
    unsupported_os) printf 'Kaisian requires macOS (Darwin).' ;;
    no_tty) printf 'A controlling terminal is required.' ;;
    selection_conflict) printf 'Selection flags (--profile, --groups, --interactive, --all) are mutually exclusive.' ;;
    unknown_argument) printf 'Unknown argument: %s' "${1-}" ;;
    missing_option_value) printf "Option '%s' requires a non-empty value." "${1-}" ;;
    invalid_language) printf "Invalid language '%s'. Supported: en, zh-TW." "${1-}" ;;
    invalid_home) printf 'HOME directory is invalid, relative, missing, symlinked, unwritable, or unowned: %s' "${1-}" ;;
    lock_failed) printf 'Failed to acquire lock at %s. Another instance may be running, or a stale lock directory exists.' "${1-}" ;;
    unsafe_path_overlap) printf "Path '%s' overlaps with lock or sandbox directory '%s'." "${1-}" "${2-}" ;;
    unsupported_stow) printf 'GNU Stow does not support required behavior (%s).' "${1-}" ;;
    *) return 64 ;;
  esac
}

message_zh_tw() {
  key=${1-}
  shift || true
  case "$key" in
    error_prefix) printf '錯誤' ;;
    missing_tools) printf '缺少必要指令：%s' "${1-}" ;;
    unsupported_os) printf 'Kaisian 僅支援 macOS (Darwin)。' ;;
    no_tty) printf '此操作需要可控制的終端機。' ;;
    selection_conflict) printf '選取選項（--profile, --groups, --interactive, --all）不可同時使用。' ;;
    unknown_argument) printf '未知的參數：%s' "${1-}" ;;
    missing_option_value) printf '選項「%s」需要非空值。' "${1-}" ;;
    invalid_language) printf '不支援的語言「%s」。僅支援：en, zh-TW。' "${1-}" ;;
    invalid_home) printf 'HOME 目錄無效、為相對路徑、不存在、為符號連結、無法寫入或非當前使用者所有：%s' "${1-}" ;;
    lock_failed) printf '無法取得鎖定：%s。可能有其他執行個體正在執行，或存在殘留的鎖定目錄。' "${1-}" ;;
    unsafe_path_overlap) printf '路徑「%s」與鎖定或沙盒目錄「%s」重疊。' "${1-}" "${2-}" ;;
    unsupported_stow) printf 'GNU Stow 不支援必要功能（%s）。' "${1-}" ;;
    *) return 64 ;;
  esac
}

message() {
  case "$LANGUAGE" in
    zh-TW|zh_TW) message_zh_tw "$@" ;;
    *) message_en "$@" ;;
  esac
}

die() {
  err_pfx=$(message error_prefix 2>/dev/null) || err_pfx='Error'
  msg=$(message "$@" 2>/dev/null) || msg="$*"
  printf '%s: %s\n' "$err_pfx" "$msg" >&2
  exit 1
}

parse_args() {
  prev=''
  for arg in "$@"; do
    case "$prev" in
      --lang)
        case "$arg" in
          en|zh-TW) LANGUAGE="$arg" ;;
        esac
        prev=''
        ;;
      *)
        case "$arg" in
          --lang=en) LANGUAGE='en' ;;
          --lang=zh-TW) LANGUAGE='zh-TW' ;;
          --lang) prev='--lang' ;;
        esac
        ;;
    esac
  done

  selection_count=0
  while test $# -gt 0; do
    arg=$1
    shift
    case "$arg" in
      -h|--help)
        usage
        exit 0
        ;;
      --profile|--profile=*)
        if test "$arg" = '--profile'; then
          test $# -gt 0 || die missing_option_value '--profile'
          val=$1
          shift
        else
          val=${arg#--profile=}
        fi
        test -n "$val" || die missing_option_value '--profile'
        SELECTION_MODE='profile'
        SELECTION_VALUE="$val"
        selection_count=$((selection_count + 1))
        ;;
      --groups|--groups=*)
        if test "$arg" = '--groups'; then
          test $# -gt 0 || die missing_option_value '--groups'
          val=$1
          shift
        else
          val=${arg#--groups=}
        fi
        test -n "$val" || die missing_option_value '--groups'
        SELECTION_MODE='groups'
        SELECTION_VALUE="$val"
        selection_count=$((selection_count + 1))
        ;;
      --interactive)
        SELECTION_MODE='interactive'
        SELECTION_VALUE=''
        selection_count=$((selection_count + 1))
        ;;
      --all)
        SELECTION_MODE='all'
        SELECTION_VALUE=''
        selection_count=$((selection_count + 1))
        ;;
      --repo|--repo=*)
        if test "$arg" = '--repo'; then
          test $# -gt 0 || die missing_option_value '--repo'
          val=$1
          shift
        else
          val=${arg#--repo=}
        fi
        test -n "$val" || die missing_option_value '--repo'
        REPOSITORY="$val"
        ;;
      --ref|--ref=*)
        if test "$arg" = '--ref'; then
          test $# -gt 0 || die missing_option_value '--ref'
          val=$1
          shift
        else
          val=${arg#--ref=}
        fi
        test -n "$val" || die missing_option_value '--ref'
        REQUESTED_REF="$val"
        ;;
      --repo-dir|--repo-dir=*)
        if test "$arg" = '--repo-dir'; then
          test $# -gt 0 || die missing_option_value '--repo-dir'
          val=$1
          shift
        else
          val=${arg#--repo-dir=}
        fi
        test -n "$val" || die missing_option_value '--repo-dir'
        CHECKOUT_DIR="$val"
        ;;
      --lang|--lang=*)
        if test "$arg" = '--lang'; then
          test $# -gt 0 || die missing_option_value '--lang'
          val=$1
          shift
        else
          val=${arg#--lang=}
        fi
        test -n "$val" || die missing_option_value '--lang'
        case "$val" in
          en|zh-TW) LANGUAGE="$val" ;;
          *) die invalid_language "$val" ;;
        esac
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --yes)
        ASSUME_YES=1
        ;;
      *)
        die unknown_argument "$arg"
        ;;
    esac
  done

  if test "$selection_count" -gt 1; then
    die selection_conflict
  fi
}

validate_home() {
  raw_home=${HOME-}
  test -n "$raw_home" || die invalid_home '<empty>'
  case "$raw_home" in
    /*) ;;
    *) die invalid_home "$raw_home" ;;
  esac
  test -d "$raw_home" || die invalid_home "$raw_home"

  physical=$(cd -P -- "$raw_home" 2>/dev/null && pwd -P) || die invalid_home "$raw_home"
  test "$raw_home" = "$physical" || die invalid_home "$raw_home"

  test -r "$raw_home" && test -w "$raw_home" && test -x "$raw_home" || die invalid_home "$raw_home"

  owner_uid=$(/usr/bin/stat -f '%u' "$raw_home" 2>/dev/null || stat -f '%u' "$raw_home" 2>/dev/null) || die invalid_home "$raw_home"
  curr_uid=$(/usr/bin/id -u 2>/dev/null || id -u) || die invalid_home "$raw_home"
  test "$owner_uid" = "$curr_uid" || die invalid_home "$raw_home"

  PHYSICAL_HOME="$physical"
  if test -z "$CHECKOUT_DIR"; then
    CHECKOUT_DIR="$PHYSICAL_HOME/.dotfiles"
  fi
  if test -z "$STATE_ROOT"; then
    xdg_state=${XDG_STATE_HOME-}
    if test -n "$xdg_state"; then
      case "$xdg_state" in
        /*) STATE_ROOT="$xdg_state/kaisian" ;;
        *) STATE_ROOT="$PHYSICAL_HOME/.local/state/kaisian" ;;
      esac
    else
      STATE_ROOT="$PHYSICAL_HOME/.local/state/kaisian"
    fi
  fi
}

canonicalize_path() {
  in_path=$1
  test -n "$in_path" || return 1
  case "$in_path" in
    /*) ;;
    *) return 1 ;;
  esac

  old_ifs=$IFS
  IFS='/'
  set -f
  # shellcheck disable=SC2086
  set -- $in_path
  set +f
  IFS=$old_ifs

  curr_dir='/'
  suffix=''
  for seg in "$@"; do
    case "$seg" in
      ''|'.') ;;
      '..')
        if test -z "$suffix"; then
          if test -d "$curr_dir"; then
            curr_dir=$(cd -P -- "$curr_dir/.." 2>/dev/null && pwd -P) || curr_dir='/'
          else
            curr_dir=${curr_dir%/*}
            test -n "$curr_dir" || curr_dir='/'
          fi
        else
          suffix=${suffix%/*}
        fi
        ;;
      *)
        if test -z "$suffix"; then
          next_path="$curr_dir/$seg"
          if test "$curr_dir" = '/'; then
            next_path="/$seg"
          fi
          if test -L "$next_path"; then
            if test -d "$next_path"; then
              curr_dir=$(cd -P -- "$next_path" 2>/dev/null && pwd -P) || curr_dir="$next_path"
            else
              phys_parent=$(cd -P -- "$(dirname "$next_path")" 2>/dev/null && pwd -P) || phys_parent=$(dirname "$next_path")
              base=$(basename "$next_path")
              suffix="/$base"
              curr_dir="$phys_parent"
            fi
          elif test -d "$next_path"; then
            curr_dir=$(cd -P -- "$next_path" 2>/dev/null && pwd -P) || curr_dir="$next_path"
          else
            suffix="/$seg"
          fi
        else
          suffix="$suffix/$seg"
        fi
        ;;
    esac
  done

  if test "$curr_dir" = '/'; then
    final_path="$suffix"
    test -n "$final_path" || final_path='/'
  else
    final_path="$curr_dir$suffix"
  fi
  printf '%s\n' "$final_path"
}

check_path_overlap_with_lock() {
  target_path=$1
  test -n "$target_path" || return 0

  canon_target=$(canonicalize_path "$target_path") || die unsafe_path_overlap "$target_path" "$LOCK_DIR"
  canon_lock=$(canonicalize_path "$LOCK_DIR") || die unsafe_path_overlap "$target_path" "$LOCK_DIR"

  if test "$canon_target" = "$canon_lock"; then
    die unsafe_path_overlap "$target_path" "$LOCK_DIR"
  fi

  case "$canon_lock" in
    "$canon_target"/*)
      die unsafe_path_overlap "$target_path" "$LOCK_DIR"
      ;;
  esac

  case "$canon_target" in
    "$canon_lock"/*)
      die unsafe_path_overlap "$target_path" "$LOCK_DIR"
      ;;
  esac
}

on_signal() {
  sig=$1
  trap - EXIT HUP INT TERM
  cleanup
  case "$sig" in
    HUP) exit 129 ;;
    INT) exit 130 ;;
    TERM) exit 143 ;;
    *) exit 1 ;;
  esac
}

acquire_lock() {
  curr_uid=$(/usr/bin/id -u 2>/dev/null || id -u)
  LOCK_DIR="/private/tmp/kaisian-$curr_uid.lock"

  test -d '/private/tmp' || die lock_failed "$LOCK_DIR"
  tmp_owner=$(/usr/bin/stat -f '%u' '/private/tmp' 2>/dev/null || stat -f '%u' '/private/tmp' 2>/dev/null)
  test "$tmp_owner" = '0' || die lock_failed "$LOCK_DIR"
  test -k '/private/tmp' || die lock_failed "$LOCK_DIR"

  check_path_overlap_with_lock "$CHECKOUT_DIR"
  check_path_overlap_with_lock "$STATE_ROOT"

  if ! ( umask 077 && /bin/mkdir "$LOCK_DIR" 2>/dev/null ); then
    die lock_failed "$LOCK_DIR"
  fi

  RECORDED_LOCK_DEV_INO=$(/usr/bin/stat -f '%d %i' "$LOCK_DIR" 2>/dev/null || stat -f '%d %i' "$LOCK_DIR" 2>/dev/null)
  if test -z "$RECORDED_LOCK_DEV_INO"; then
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
    die lock_failed "$LOCK_DIR"
  fi

  trap 'cleanup' EXIT
  trap 'on_signal HUP' HUP
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM

  printf '%s\n' "$$" > "$LOCK_DIR/pid" || die lock_failed "$LOCK_DIR"

  SANDBOX="$LOCK_DIR/sandbox"
  /bin/mkdir -m 0700 "$SANDBOX" 2>/dev/null || die lock_failed "$LOCK_DIR"
  RECORDED_SANDBOX_DEV_INO=$(/usr/bin/stat -f '%d %i' "$SANDBOX" 2>/dev/null || stat -f '%d %i' "$SANDBOX" 2>/dev/null)
  if test -z "$RECORDED_SANDBOX_DEV_INO"; then
    /bin/rmdir "$SANDBOX" 2>/dev/null || true
    die lock_failed "$LOCK_DIR"
  fi

  /bin/mkdir -m 0700 "$SANDBOX/git-home" "$SANDBOX/stow-cwd" "$SANDBOX/stow-home" 2>/dev/null || die lock_failed "$LOCK_DIR"
  : > "$SANDBOX/stow-home/.stow-global-ignore" || die lock_failed "$LOCK_DIR"

  # Re-check path overlap after sandbox exists to ensure symlink-plus-.. cannot bypass lock containment
  check_path_overlap_with_lock "$CHECKOUT_DIR"
  check_path_overlap_with_lock "$STATE_ROOT"
}

cleanup() {
  test -n "$LOCK_DIR" || return 0
  test -n "$RECORDED_LOCK_DEV_INO" || return 0

  curr_lock_dev_ino=$(/usr/bin/stat -f '%d %i' "$LOCK_DIR" 2>/dev/null || stat -f '%d %i' "$LOCK_DIR" 2>/dev/null || true)
  if test "$curr_lock_dev_ino" != "$RECORDED_LOCK_DEV_INO"; then
    return 0
  fi

  if test -n "$SANDBOX" && test -n "$RECORDED_SANDBOX_DEV_INO"; then
    curr_sb_dev_ino=$(/usr/bin/stat -f '%d %i' "$SANDBOX" 2>/dev/null || stat -f '%d %i' "$SANDBOX" 2>/dev/null || true)
    if test "$curr_sb_dev_ino" = "$RECORDED_SANDBOX_DEV_INO"; then
      case "$SANDBOX" in
        "$LOCK_DIR"/*)
          /bin/rm -rf -- "$SANDBOX" 2>/dev/null || true
          ;;
      esac
    fi
  fi

  /bin/rm -f -- "$LOCK_DIR/pid" 2>/dev/null || true
  /bin/rmdir -- "$LOCK_DIR" 2>/dev/null || true
}

discover_executable() {
  name=$1
  raw_path=$(which "$name" 2>/dev/null || type -p "$name" 2>/dev/null || command -v "$name" 2>/dev/null || true)
  test -n "$raw_path" || return 1
  case "$raw_path" in
    /*) abs_path="$raw_path" ;;
    */*)
      abs_dir=$(cd -P -- "$(dirname "$raw_path")" 2>/dev/null && pwd -P) || return 1
      abs_path="$abs_dir/$(basename "$raw_path")"
      ;;
    *)
      abs_path=''
      old_ifs=$IFS
      IFS=':'
      set -f
      # shellcheck disable=SC2086
      set -- ${PATH-}
      set +f
      IFS=$old_ifs
      for pdir in "$@"; do
        test -n "$pdir" || pdir='.'
        candidate="$pdir/$name"
        if test -f "$candidate" && test -x "$candidate"; then
          abs_dir=$(cd -P -- "$pdir" 2>/dev/null && pwd -P) || abs_dir="$pdir"
          abs_path="$abs_dir/$name"
          break
        fi
      done
      ;;
  esac
  test -n "$abs_path" || return 1
  test -f "$abs_path" || return 1
  test -x "$abs_path" || return 1
  printf '%s\n' "$abs_path"
}

run_git() {
  test -n "$SANDBOX" || die lock_failed 'sandbox not initialized'
  /bin/mkdir -p "$SANDBOX/git-home" 2>/dev/null || true
  if test "${KAISIAN_TESTING-0}" = '1'; then
    git_bin="${KAISIAN_GIT_EXEC:-${GIT_EXEC:-/usr/bin/git}}"
    runner_path="${KAISIAN_RUNNER_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
  else
    git_bin="${GIT_EXEC:-/usr/bin/git}"
    runner_path='/usr/bin:/bin:/usr/sbin:/sbin'
  fi
  /usr/bin/env -i \
    PATH="$runner_path" \
    HOME="$SANDBOX/git-home" \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/usr/bin/false \
    GIT_NO_REPLACE_OBJECTS=1 \
    "$git_bin" "$@"
}

run_stow() {
  test -n "$SANDBOX" || die lock_failed 'sandbox not initialized'
  /bin/mkdir -p "$SANDBOX/stow-cwd" "$SANDBOX/stow-home" 2>/dev/null || true
  test -f "$SANDBOX/stow-home/.stow-global-ignore" || : > "$SANDBOX/stow-home/.stow-global-ignore"
  if test "${KAISIAN_TESTING-0}" = '1'; then
    stow_bin="${KAISIAN_STOW_EXEC:-${STOW_EXEC:-stow}}"
    runner_path="${KAISIAN_RUNNER_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
  else
    stow_bin="${STOW_EXEC:-stow}"
    runner_path='/usr/bin:/bin:/usr/sbin:/sbin'
  fi
  (
    cd "$SANDBOX/stow-cwd" && \
    /usr/bin/env -i \
      PATH="$runner_path" \
      LC_ALL=C \
      HOME="$SANDBOX/stow-home" \
      "$stow_bin" "$@"
  )
}

require_prerequisites() {
  os_name=$(/usr/bin/uname -s 2>/dev/null || uname -s)
  test "$os_name" = 'Darwin' || die unsupported_os

  missing=''
  if ! GIT_EXEC=$(discover_executable git); then
    missing='git'
  fi
  if ! STOW_EXEC=$(discover_executable stow); then
    if test -z "$missing"; then missing='stow'; else missing="$missing, stow"; fi
  fi
  if ! FZF_EXEC=$(discover_executable fzf); then
    if test -z "$missing"; then missing='fzf'; else missing="$missing, fzf"; fi
  fi
  if ! PLUTIL_EXEC=$(discover_executable plutil); then
    if test -z "$missing"; then missing='plutil'; else missing="$missing, plutil"; fi
  fi
  if test -n "$missing"; then
    die missing_tools "$missing"
  fi

  probe_src="$SANDBOX/stow-probe-src"
  probe_tgt="$SANDBOX/stow-probe-tgt"
  /bin/mkdir -p "$probe_src/pkg1/dot-config/app" "$probe_src/pkg2/excluded" "$probe_tgt" 2>/dev/null || die lock_failed "$SANDBOX"

  # 1. --dotfiles and --no-folding (nested directory structure)
  echo 'test' > "$probe_src/pkg1/dot-testfile"
  echo 'ignoreme' > "$probe_src/pkg1/README"
  echo 'nested' > "$probe_src/pkg1/dot-config/app/dot-nested"
  echo 'obsolete' > "$probe_src/pkg1/dot-obsolete"
  if ! run_stow -d "$probe_src" -t "$probe_tgt" --dotfiles --no-folding pkg1 >/dev/null 2>&1; then
    die unsupported_stow '--dotfiles --no-folding'
  fi
  test -L "$probe_tgt/.testfile" || die unsupported_stow '--dotfiles link creation'
  test -L "$probe_tgt/README" || die unsupported_stow 'built-in-ignore disabling'
  test -d "$probe_tgt/.config" && test ! -L "$probe_tgt/.config" || die unsupported_stow '--no-folding directory creation'
  test -d "$probe_tgt/.config/app" && test ! -L "$probe_tgt/.config/app" || die unsupported_stow '--no-folding nested directory'
  test -L "$probe_tgt/.config/app/.nested" || die unsupported_stow '--no-folding leaf link'
  test -L "$probe_tgt/.obsolete" || die unsupported_stow '--dotfiles link creation'

  # 2. --simulate
  echo 'test2' > "$probe_src/pkg2/dot-test2"
  if ! run_stow -d "$probe_src" -t "$probe_tgt" --dotfiles --no-folding --simulate pkg2 >/dev/null 2>&1; then
    die unsupported_stow '--simulate'
  fi
  test ! -e "$probe_tgt/.test2" || die unsupported_stow '--simulate isolated'

  # 3. Mixed -R / -D with --compat and anchored subtree ignore
  echo 'sub' > "$probe_src/pkg2/excluded/dot-sub"
  /bin/rm -f "$probe_src/pkg1/dot-obsolete"
  if ! run_stow -d "$probe_src" -t "$probe_tgt" --dotfiles --no-folding --compat --ignore='^excluded(/.*)?$' -R pkg2 -D pkg1 >/dev/null 2>&1; then
    die unsupported_stow 'mixed -R/-D --compat'
  fi
  test -L "$probe_tgt/.test2" || die unsupported_stow 'mixed -R restow'
  test ! -e "$probe_tgt/.testfile" || die unsupported_stow 'mixed -D unstow'
  test ! -e "$probe_tgt/.obsolete" && test ! -L "$probe_tgt/.obsolete" || die unsupported_stow '--compat obsolete link deletion'
  test ! -e "$probe_tgt/excluded" || die unsupported_stow 'anchored ignore exclusion'

  /bin/rm -rf -- "$probe_src" "$probe_tgt" 2>/dev/null || true
}

main() {
  resolve_language ''
  parse_args "$@"
  validate_home
  acquire_lock
  require_prerequisites
  return 0
}

if test "${KAISIAN_TESTING-0}" != 1; then
  main "$@"
fi
