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
    invalid_manifest)
      reason_key=${1-}
      case "$reason_key" in
        path_required) printf 'Invalid manifest: manifest path is required.' ;;
        file_not_found) printf "Invalid manifest: manifest file '%s' not found or unreadable." "${2-}" ;;
        checkout_dir_not_found) printf "Invalid manifest: checkout directory '%s' not found." "${2-}" ;;
        groups_not_found) printf 'Invalid manifest: groups table not found.' ;;
        malformed_syntax) printf 'Invalid manifest: malformed JSON syntax.' ;;
        root_not_object) printf 'Invalid manifest: root must be a JSON object.' ;;
        unknown_top_key) printf "Invalid manifest: unknown top-level key '%s'." "${2-}" ;;
        missing_schema) printf "Invalid manifest: missing 'schema' key." ;;
        missing_groups) printf "Invalid manifest: missing 'groups' key." ;;
        schema_not_integer) printf "Invalid manifest: 'schema' must be an integer." ;;
        unsupported_schema) printf "Invalid manifest: unsupported schema version '%s'." "${2-}" ;;
        groups_not_array) printf "Invalid manifest: 'groups' must be an array." ;;
        empty_groups) printf "Invalid manifest: 'groups' cannot be empty." ;;
        group_not_object) printf "Invalid manifest: group item %s must be an object." "${2-}" ;;
        group_missing_name) printf "Invalid manifest: group %s missing 'name'." "${2-}" ;;
        group_missing_description) printf "Invalid manifest: group %s missing 'description'." "${2-}" ;;
        group_invalid_name) printf "Invalid manifest: invalid group name '%s'." "${2-}" ;;
        group_duplicate_name) printf "Invalid manifest: duplicate group name '%s'." "${2-}" ;;
        group_unknown_key) printf "Invalid manifest: unknown key in group %s." "${2-}" ;;
        description_not_object) printf "Invalid manifest: group %s 'description' must be an object." "${2-}" ;;
        description_missing_en) printf "Invalid manifest: group %s description missing 'en'." "${2-}" ;;
        description_missing_zhtw) printf "Invalid manifest: group %s description missing 'zh-TW'." "${2-}" ;;
        description_unknown_key) printf "Invalid manifest: unknown key in group %s description." "${2-}" ;;
        description_empty_en) printf "Invalid manifest: group %s description.en cannot be empty." "${2-}" ;;
        description_empty_zhtw) printf "Invalid manifest: group %s description.zh-TW cannot be empty." "${2-}" ;;
        description_control_char) printf "Invalid manifest: group %s description contains control/tab/newline characters." "${2-}" ;;
        missing_package_dir) printf "Invalid manifest: missing package directory '%s'." "${2-}" ;;
        undeclared_package_dir) printf "Invalid manifest: undeclared package directory '%s'." "${2-}" ;;
        profiles_not_object) printf "Invalid manifest: 'profiles' must be an object." ;;
        profile_invalid_name) printf "Invalid manifest: invalid profile name '%s'." "${2-}" ;;
        profile_not_array) printf "Invalid manifest: profile '%s' must be an array." "${2-}" ;;
        profile_empty) printf "Invalid manifest: profile '%s' cannot be empty." "${2-}" ;;
        profile_unknown_group) printf "Invalid manifest: profile '%s' references unknown group '%s'." "${2-}" "${3-}" ;;
        profile_duplicate_group) printf "Invalid manifest: profile '%s' contains duplicate group '%s'." "${2-}" "${3-}" ;;
        profile_unknown_key) printf "Invalid manifest: unknown key in 'profiles'." ;;
        *) printf 'Invalid manifest: %s' "${1-}" ;;
      esac
      ;;
    unknown_profile) printf "Unknown profile '%s'." "${1-}" ;;
    unknown_group) printf "Unknown group '%s'." "${1-}" ;;
    empty_group_selection) printf 'Group selection cannot be empty.' ;;
    empty_selection) printf 'No packages selected.' ;;
    fzf_failed)
      reason_key=${1-}
      case "$reason_key" in
        empty_record) printf 'fzf interactive selection failed: output contains an empty or whitespace record.' ;;
        unknown_record) printf "fzf interactive selection failed: output contains unknown record '%s'." "${2-}" ;;
        invalid_format) printf "fzf interactive selection failed: malformed record format '%s'." "${2-}" ;;
        *) printf 'fzf interactive selection failed (%s).' "${1-}" ;;
      esac
      ;;
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
    invalid_manifest)
      reason_key=${1-}
      case "$reason_key" in
        path_required) printf '無效的 manifest：必須提供 manifest 路徑。' ;;
        file_not_found) printf '無效的 manifest：找不到 manifest 檔案或無法讀取「%s」。' "${2-}" ;;
        checkout_dir_not_found) printf '無效的 manifest：找不到檢出目錄「%s」。' "${2-}" ;;
        groups_not_found) printf '無效的 manifest：找不到群組資料表。' ;;
        malformed_syntax) printf '無效的 manifest：JSON 語法錯誤。' ;;
        root_not_object) printf '無效的 manifest：根節點必須是 JSON 物件。' ;;
        unknown_top_key) printf '無效的 manifest：未知的頂層鍵值「%s」。' "${2-}" ;;
        missing_schema) printf '無效的 manifest：缺少「schema」鍵值。' ;;
        missing_groups) printf '無效的 manifest：缺少「groups」鍵值。' ;;
        schema_not_integer) printf '無效的 manifest：「schema」必須是整數。' ;;
        unsupported_schema) printf '無效的 manifest：不支援的 schema 版本「%s」。' "${2-}" ;;
        groups_not_array) printf '無效的 manifest：「groups」必須是陣列。' ;;
        empty_groups) printf '無效的 manifest：「groups」不能為空。' ;;
        group_not_object) printf '無效的 manifest：群組項目 %s 必須是物件。' "${2-}" ;;
        group_missing_name) printf '無效的 manifest：群組 %s 缺少「name」。' "${2-}" ;;
        group_missing_description) printf '無效的 manifest：群組 %s 缺少「description」。' "${2-}" ;;
        group_invalid_name) printf '無效的 manifest：無效的群組名稱「%s」。' "${2-}" ;;
        group_duplicate_name) printf '無效的 manifest：重複的群組名稱「%s」。' "${2-}" ;;
        group_unknown_key) printf '無效的 manifest：群組 %s 包含未知鍵值。' "${2-}" ;;
        description_not_object) printf '無效的 manifest：群組 %s 的「description」必須是物件。' "${2-}" ;;
        description_missing_en) printf '無效的 manifest：群組 %s 的 description 缺少「en」。' "${2-}" ;;
        description_missing_zhtw) printf '無效的 manifest：群組 %s 的 description 缺少「zh-TW」。' "${2-}" ;;
        description_unknown_key) printf '無效的 manifest：群組 %s 的 description 包含未知鍵值。' "${2-}" ;;
        description_empty_en) printf '無效的 manifest：群組 %s 的 description.en 不能為空。' "${2-}" ;;
        description_empty_zhtw) printf '無效的 manifest：群組 %s 的 description.zh-TW 不能為空。' "${2-}" ;;
        description_control_char) printf '無效的 manifest：群組 %s 的說明包含控制字元、Tab 或換行。' "${2-}" ;;
        missing_package_dir) printf '無效的 manifest：缺少套件目錄「%s」。' "${2-}" ;;
        undeclared_package_dir) printf '無效的 manifest：未宣告的套件目錄「%s」。' "${2-}" ;;
        profiles_not_object) printf '無效的 manifest：「profiles」必須是物件。' ;;
        profile_invalid_name) printf '無效的 manifest：無效的設定檔名稱「%s」。' "${2-}" ;;
        profile_not_array) printf '無效的 manifest：設定檔「%s」必須是陣列。' "${2-}" ;;
        profile_empty) printf '無效的 manifest：設定檔「%s」不能為空。' "${2-}" ;;
        profile_unknown_group) printf '無效的 manifest：設定檔「%s」引用了未知的群組「%s」。' "${2-}" "${3-}" ;;
        profile_duplicate_group) printf '無效的 manifest：設定檔「%s」包含重複的群組「%s」。' "${2-}" "${3-}" ;;
        profile_unknown_key) printf '無效的 manifest：「profiles」包含未知鍵值。' ;;
        *) printf '無效的 manifest：%s' "${1-}" ;;
      esac
      ;;
    unknown_profile) printf '未知的設定檔「%s」。' "${1-}" ;;
    unknown_group) printf '未知的群組「%s」。' "${1-}" ;;
    empty_group_selection) printf '群組選取不能為空。' ;;
    empty_selection) printf '未選取任何套件。' ;;
    fzf_failed)
      reason_key=${1-}
      case "$reason_key" in
        empty_record) printf 'fzf 互動選取失敗：輸出包含空紀錄或空白字元。' ;;
        unknown_record) printf 'fzf 互動選取失敗：輸出包含未知的紀錄「%s」。' "${2-}" ;;
        invalid_format) printf 'fzf 互動選取失敗：無效的紀錄格式「%s」。' "${2-}" ;;
        *) printf 'fzf 互動選取失敗（%s）。' "${1-}" ;;
      esac
      ;;
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
              phys_parent=$(cd -P -- "${next_path%/*}" 2>/dev/null && pwd -P) || phys_parent=${next_path%/*}
              base=${next_path##*/}
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
  test -n "$name" || return 1
  raw_path=$(type -P -- "$name" 2>/dev/null || true)
  if test -z "$raw_path"; then
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
        raw_path="$candidate"
        break
      fi
    done
  fi
  test -n "$raw_path" || return 1

  case "$raw_path" in
    /*)
      dir_part="${raw_path%/*}"
      file_part="${raw_path##*/}"
      test -n "$dir_part" || dir_part='/'
      abs_dir=$(cd -P -- "$dir_part" 2>/dev/null && pwd -P) || return 1
      if test "$abs_dir" = '/'; then
        abs_path="/$file_part"
      else
        abs_path="$abs_dir/$file_part"
      fi
      ;;
    */*)
      dir_part="${raw_path%/*}"
      file_part="${raw_path##*/}"
      test -n "$dir_part" || dir_part='.'
      abs_dir=$(cd -P -- "$dir_part" 2>/dev/null && pwd -P) || return 1
      if test "$abs_dir" = '/'; then
        abs_path="/$file_part"
      else
        abs_path="$abs_dir/$file_part"
      fi
      ;;
    *)
      abs_dir=$(cd -P -- '.' 2>/dev/null && pwd -P) || return 1
      if test "$abs_dir" = '/'; then
        abs_path="/$raw_path"
      else
        abs_path="$abs_dir/$raw_path"
      fi
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

is_valid_name() {
  case "$1" in
    [!abcdefghijklmnopqrstuvwxyz]* | *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
    "") return 1 ;;
    *) return 0 ;;
  esac
}

has_control_char() {
  (
    LC_ALL=C
    case "$1" in
      *[[:cntrl:]]*) exit 0 ;;
      *) exit 1 ;;
    esac
  )
}

trim_whitespace() {
  local var=$1
  while case "$var" in [[:space:]]*) var="${var#[[:space:]]}"; true ;; *) false ;; esac; do :; done
  while case "$var" in *[[:space:]]) var="${var%[[:space:]]}"; true ;; *) false ;; esac; do :; done
  printf '%s' "$var"
}

parse_manifest() {
  manifest=${1-}
  test -n "$manifest" || die invalid_manifest path_required
  test -f "$manifest" && test -r "$manifest" || die invalid_manifest file_not_found "$manifest"

  case "$manifest" in
    */*) manifest_dir="${manifest%/*}" ;;
    *) manifest_dir='.' ;;
  esac
  checkout_dir="${2:-${CHECKOUT_DIR:-$manifest_dir}}"
  test -n "$checkout_dir" || checkout_dir='.'
  test -d "$checkout_dir" || die invalid_manifest checkout_dir_not_found "$checkout_dir"

  test -n "$SANDBOX" && test -d "$SANDBOX" || die lock_failed "$SANDBOX"

  if test "${KAISIAN_TESTING-0}" = '1'; then
    plutil_bin="${KAISIAN_PLUTIL_EXEC:-${PLUTIL_EXEC:-/usr/bin/plutil}}"
  else
    plutil_bin='/usr/bin/plutil'
  fi

  # 1. Syntax check
  "$plutil_bin" -convert json -o /dev/null -- "$manifest" 2>/dev/null || die invalid_manifest malformed_syntax

  # 2. Convert to XML in sandbox and wrap to inspect root dictionary keys
  manifest_xml="$SANDBOX/manifest.xml"
  "$plutil_bin" -convert xml1 -o "$manifest_xml" -- "$manifest" 2>/dev/null || die invalid_manifest malformed_syntax

  wrapper_xml="$SANDBOX/manifest_wrapper.xml"
  "$plutil_bin" -create xml1 "$wrapper_xml" 2>/dev/null || die invalid_manifest malformed_syntax
  "$plutil_bin" -insert root -xml "$(cat "$manifest_xml")" "$wrapper_xml" 2>/dev/null || die invalid_manifest malformed_syntax

  root_type=$("$plutil_bin" -type root "$wrapper_xml" 2>/dev/null || true)
  test "$root_type" = 'dictionary' || die invalid_manifest root_not_object

  # Top-level keys: verify schema and groups exist
  schema_type=$("$plutil_bin" -type root.schema "$wrapper_xml" 2>/dev/null || true)
  test -n "$schema_type" || die invalid_manifest missing_schema

  groups_type=$("$plutil_bin" -type root.groups "$wrapper_xml" 2>/dev/null || true)
  test -n "$groups_type" || die invalid_manifest missing_groups

  has_profiles=0
  profiles_type=$("$plutil_bin" -type root.profiles "$wrapper_xml" 2>/dev/null || true)
  if test -n "$profiles_type"; then
    has_profiles=1
  fi

  # Unknown top-level key check via plutil residual validation
  root_check_xml="$SANDBOX/manifest_root_check.xml"
  cp "$wrapper_xml" "$root_check_xml"
  "$plutil_bin" -remove root.schema "$root_check_xml" 2>/dev/null || true
  "$plutil_bin" -remove root.groups "$root_check_xml" 2>/dev/null || true
  if test "$has_profiles" -eq 1; then
    "$plutil_bin" -remove root.profiles "$root_check_xml" 2>/dev/null || true
  fi
  residual_root=$("$plutil_bin" -extract root json -o - "$root_check_xml" 2>/dev/null || true)
  test "$residual_root" = '{}' || die invalid_manifest unknown_top_key "$residual_root"
  /bin/rm -f "$root_check_xml" 2>/dev/null || true

  # 3. Schema validation
  test "$schema_type" = 'integer' || die invalid_manifest schema_not_integer
  schema_val=$("$plutil_bin" -extract schema raw "$manifest" 2>/dev/null || true)
  test "$schema_val" = '1' || die invalid_manifest unsupported_schema "$schema_val"

  # 4. Groups validation
  test "$groups_type" = 'array' || die invalid_manifest groups_not_array
  group_count=$("$plutil_bin" -extract groups raw "$manifest" 2>/dev/null || true)
  case "$group_count" in
    [0-9]*) ;;
    *) die invalid_manifest groups_not_array ;;
  esac
  test "$group_count" -gt 0 || die invalid_manifest empty_groups

  groups_tsv="$SANDBOX/groups.tsv"
  : > "$groups_tsv"
  seen_group_names=''

  i=0
  nl='
'
  while test "$i" -lt "$group_count"; do
    gtype=$("$plutil_bin" -type "groups.$i" "$manifest" 2>/dev/null || true)
    test "$gtype" = 'dictionary' || die invalid_manifest group_not_object "$i"

    # Verify required keys in group
    gname_type=$("$plutil_bin" -type "groups.$i.name" "$manifest" 2>/dev/null || true)
    test -n "$gname_type" || die invalid_manifest group_missing_name "$i"

    gdesc_type=$("$plutil_bin" -type "groups.$i.description" "$manifest" 2>/dev/null || true)
    test -n "$gdesc_type" || die invalid_manifest group_missing_description "$i"

    # Residual unknown-key check on group
    group_check_xml="$SANDBOX/group_check_$i.xml"
    cp "$manifest_xml" "$group_check_xml"
    "$plutil_bin" -remove "groups.$i.name" "$group_check_xml" 2>/dev/null || true
    "$plutil_bin" -remove "groups.$i.description" "$group_check_xml" 2>/dev/null || true
    residual_group=$("$plutil_bin" -extract "groups.$i" json -o - "$group_check_xml" 2>/dev/null || true)
    test "$residual_group" = '{}' || die invalid_manifest group_unknown_key "$i"
    /bin/rm -f "$group_check_xml" 2>/dev/null || true

    # Name validation
    test "$gname_type" = 'string' || die invalid_manifest group_invalid_name "$i"
    gname=$("$plutil_bin" -extract "groups.$i.name" raw "$manifest" 2>/dev/null || true)
    is_valid_name "$gname" || die invalid_manifest group_invalid_name "$gname"

    case " $seen_group_names " in
      *" $gname "*) die invalid_manifest group_duplicate_name "$gname" ;;
    esac
    if test -z "$seen_group_names"; then
      seen_group_names="$gname"
    else
      seen_group_names="$seen_group_names $gname"
    fi

    # Description validation
    test "$gdesc_type" = 'dictionary' || die invalid_manifest description_not_object "$i"

    en_type=$("$plutil_bin" -type "groups.$i.description.en" "$manifest" 2>/dev/null || true)
    test -n "$en_type" || die invalid_manifest description_missing_en "$i"

    zhtw_type=$("$plutil_bin" -type "groups.$i.description.zh-TW" "$manifest" 2>/dev/null || true)
    test -n "$zhtw_type" || die invalid_manifest description_missing_zhtw "$i"

    # Residual unknown-key check on description
    desc_check_xml="$SANDBOX/desc_check_$i.xml"
    cp "$manifest_xml" "$desc_check_xml"
    "$plutil_bin" -remove "groups.$i.description.en" "$desc_check_xml" 2>/dev/null || true
    "$plutil_bin" -remove "groups.$i.description.zh-TW" "$desc_check_xml" 2>/dev/null || true
    residual_desc=$("$plutil_bin" -extract "groups.$i.description" json -o - "$desc_check_xml" 2>/dev/null || true)
    test "$residual_desc" = '{}' || die invalid_manifest description_unknown_key "$i"
    /bin/rm -f "$desc_check_xml" 2>/dev/null || true

    test "$en_type" = 'string' || die invalid_manifest description_empty_en "$i"
    raw_desc_en=$("$plutil_bin" -extract "groups.$i.description.en" raw "$manifest" 2>/dev/null; printf 'x')
    raw_desc_en=${raw_desc_en%x}
    raw_desc_en=${raw_desc_en%"$nl"}
    test -n "$raw_desc_en" || die invalid_manifest description_empty_en "$i"
    has_control_char "$raw_desc_en" && die invalid_manifest description_control_char "$i"

    test "$zhtw_type" = 'string' || die invalid_manifest description_empty_zhtw "$i"
    raw_desc_zh=$("$plutil_bin" -extract "groups.$i.description.zh-TW" raw "$manifest" 2>/dev/null; printf 'x')
    raw_desc_zh=${raw_desc_zh%x}
    raw_desc_zh=${raw_desc_zh%"$nl"}
    test -n "$raw_desc_zh" || die invalid_manifest description_empty_zhtw "$i"
    has_control_char "$raw_desc_zh" && die invalid_manifest description_control_char "$i"

    printf '%s\t%s\t%s\n' "$gname" "$raw_desc_en" "$raw_desc_zh" >> "$groups_tsv"
    i=$((i + 1))
  done

  # 5. Package directory alignment
  for g in $seen_group_names; do
    test -d "$checkout_dir/$g" && test ! -L "$checkout_dir/$g" || die invalid_manifest missing_package_dir "$g"
  done

  for entry in "$checkout_dir"/*; do
    test -e "$entry" || continue
    if test -d "$entry" && test ! -L "$entry"; then
      entry_name="${entry##*/}"
      case " $seen_group_names " in
        *" $entry_name "*) ;;
        *) die invalid_manifest undeclared_package_dir "$entry_name" ;;
      esac
    fi
  done

  # 6. Profiles validation
  profiles_tsv="$SANDBOX/profiles.tsv"
  : > "$profiles_tsv"

  if test "$has_profiles" -eq 1; then
    test "$profiles_type" = 'dictionary' || die invalid_manifest profiles_not_object

    prof_check_xml="$SANDBOX/prof_check.xml"
    cp "$manifest_xml" "$prof_check_xml"

    pnames=$("$plutil_bin" -extract profiles raw "$manifest" 2>/dev/null || true)
    old_ifs=$IFS
    IFS='
'
    for pname in $pnames; do
      IFS=$old_ifs
      is_valid_name "$pname" || die invalid_manifest profile_invalid_name "$pname"

      prof_type=$("$plutil_bin" -type "profiles.$pname" "$manifest" 2>/dev/null || true)
      test "$prof_type" = 'array' || die invalid_manifest profile_not_array "$pname"

      pcount=$("$plutil_bin" -extract "profiles.$pname" raw "$manifest" 2>/dev/null || true)
      case "$pcount" in
        [0-9]*) ;;
        *) die invalid_manifest profile_not_array "$pname" ;;
      esac
      test "$pcount" -gt 0 || die invalid_manifest profile_empty "$pname"

      seen_prof_groups=''
      j=0
      while test "$j" -lt "$pcount"; do
        entry_type=$("$plutil_bin" -type "profiles.$pname.$j" "$manifest" 2>/dev/null || true)
        test "$entry_type" = 'string' || die invalid_manifest profile_unknown_group "$pname" "$j"
        entry_name=$("$plutil_bin" -extract "profiles.$pname.$j" raw "$manifest" 2>/dev/null || true)

        case " $seen_group_names " in
          *" $entry_name "*) ;;
          *) die invalid_manifest profile_unknown_group "$pname" "$entry_name" ;;
        esac

        case " $seen_prof_groups " in
          *" $entry_name "*) die invalid_manifest profile_duplicate_group "$pname" "$entry_name" ;;
        esac

        if test -z "$seen_prof_groups"; then
          seen_prof_groups="$entry_name"
        else
          seen_prof_groups="$seen_prof_groups $entry_name"
        fi
        j=$((j + 1))
      done

      printf '%s\t%s\n' "$pname" "$seen_prof_groups" >> "$profiles_tsv"
      "$plutil_bin" -remove "profiles.$pname" "$prof_check_xml" 2>/dev/null || true
      IFS='
'
    done
    IFS=$old_ifs

    residual_prof=$("$plutil_bin" -extract profiles json -o - "$prof_check_xml" 2>/dev/null || true)
    test "$residual_prof" = '{}' || die invalid_manifest profile_unknown_key
    /bin/rm -f "$prof_check_xml" 2>/dev/null || true
  fi
}

select_interactively() {
  if test "${KAISIAN_TESTING-0}" = '1' && test "${KAISIAN_TESTING_TTY-}" = '0'; then
    die no_tty
  elif test "${KAISIAN_TESTING-0}" != '1' || test "${KAISIAN_TESTING_TTY-}" != '1'; then
    ( : < /dev/tty && : > /dev/tty ) 2>/dev/null || die no_tty
  fi

  test -n "$SANDBOX" || die lock_failed "$SANDBOX"
  test -f "$SANDBOX/groups.tsv" || die invalid_manifest groups_not_found

  fzf_candidates="$SANDBOX/fzf_candidates.txt"
  : > "$fzf_candidates"
  all_groups=''
  while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
    test -n "$gname" || continue
    if test -z "$all_groups"; then
      all_groups="$gname"
    else
      all_groups="$all_groups $gname"
    fi
    case "$LANGUAGE" in
      zh-TW|zh_TW) desc="$desc_zh" ;;
      *) desc="$desc_en" ;;
    esac
    printf '%s\t%s\n' "$gname" "$desc" >> "$fzf_candidates"
  done < "$SANDBOX/groups.tsv"

  fzf_output="$SANDBOX/fzf_output.txt"
  : > "$fzf_output"

  if test "${KAISIAN_TESTING-0}" = '1'; then
    fzf_bin="${KAISIAN_FZF_EXEC:-${FZF_EXEC:-fzf}}"
  else
    fzf_bin="${FZF_EXEC:-fzf}"
  fi

  fzf_status=0
  "$fzf_bin" --multi --with-nth=1,2 < "$fzf_candidates" > "$fzf_output" || fzf_status=$?

  if test "$fzf_status" -eq 130; then
    cleanup
    exit 0
  elif test "$fzf_status" -ne 0; then
    die fzf_failed "$fzf_status"
  fi

  if test ! -s "$fzf_output"; then
    die empty_selection
  fi

  selected_set=''
  while IFS= read -r line || test -n "$line"; do
    test -n "$line" || die fzf_failed empty_record
    case "$line" in
      *'	'*)
        is_cand_match=0
        while IFS= read -r cand_line || test -n "$cand_line"; do
          if test "$line" = "$cand_line"; then
            is_cand_match=1
            record_name="${line%%	*}"
            break
          fi
        done < "$fzf_candidates"
        test "$is_cand_match" -eq 1 || die fzf_failed invalid_format "$line"
        ;;
      *)
        is_valid_name "$line" || die fzf_failed invalid_format "$line"
        is_group_match=0
        while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
          test -n "$gname" || continue
          if test "$line" = "$gname"; then
            is_group_match=1
            record_name="$line"
            break
          fi
        done < "$SANDBOX/groups.tsv"
        test "$is_group_match" -eq 1 || die fzf_failed unknown_record "$line"
        ;;
    esac

    case " $selected_set " in
      *" $record_name "*) ;;
      *)
        if test -z "$selected_set"; then
          selected_set="$record_name"
        else
          selected_set="$selected_set $record_name"
        fi
        ;;
    esac
  done < "$fzf_output"

  test -n "$selected_set" || die empty_selection

  : > "$SANDBOX/selected.txt"
  : > "$SANDBOX/unselected.txt"
  while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
    test -n "$gname" || continue
    case " $selected_set " in
      *" $gname "*) printf '%s\n' "$gname" >> "$SANDBOX/selected.txt" ;;
      *) printf '%s\n' "$gname" >> "$SANDBOX/unselected.txt" ;;
    esac
  done < "$SANDBOX/groups.tsv"
}

resolve_selection() {
  test -n "$SANDBOX" || die lock_failed "$SANDBOX"
  test -f "$SANDBOX/groups.tsv" || die invalid_manifest groups_not_found

  case "$SELECTION_MODE" in
    none|all)
      : > "$SANDBOX/selected.txt"
      : > "$SANDBOX/unselected.txt"
      while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
        test -n "$gname" || continue
        printf '%s\n' "$gname" >> "$SANDBOX/selected.txt"
      done < "$SANDBOX/groups.tsv"
      ;;
    profile)
      test -n "$SELECTION_VALUE" || die missing_option_value '--profile'
      test -f "$SANDBOX/profiles.tsv" || die unknown_profile "$SELECTION_VALUE"

      profile_groups=''
      found_profile=0
      while IFS='	' read -r pname pgroups || test -n "$pname"; do
        if test "$pname" = "$SELECTION_VALUE"; then
          profile_groups="$pgroups"
          found_profile=1
          break
        fi
      done < "$SANDBOX/profiles.tsv"

      test "$found_profile" -eq 1 || die unknown_profile "$SELECTION_VALUE"

      : > "$SANDBOX/selected.txt"
      : > "$SANDBOX/unselected.txt"
      while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
        test -n "$gname" || continue
        case " $profile_groups " in
          *" $gname "*) printf '%s\n' "$gname" >> "$SANDBOX/selected.txt" ;;
          *) printf '%s\n' "$gname" >> "$SANDBOX/unselected.txt" ;;
        esac
      done < "$SANDBOX/groups.tsv"
      ;;
    groups)
      test -n "$SELECTION_VALUE" || die missing_option_value '--groups'

      all_groups=''
      while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
        test -n "$gname" || continue
        if test -z "$all_groups"; then
          all_groups="$gname"
        else
          all_groups="$all_groups $gname"
        fi
      done < "$SANDBOX/groups.tsv"

      cur="$SELECTION_VALUE"
      selected_set=''
      while :; do
        has_more=0
        case "$cur" in
          *,*)
            part="${cur%%,*}"
            cur="${cur#*,}"
            has_more=1
            ;;
          *)
            part="$cur"
            cur=''
            ;;
        esac
        trimmed=$(trim_whitespace "$part")
        test -n "$trimmed" || die empty_group_selection

        case " $all_groups " in
          *" $trimmed "*) ;;
          *) die unknown_group "$trimmed" ;;
        esac

        case " $selected_set " in
          *" $trimmed "*) ;;
          *)
            if test -z "$selected_set"; then
              selected_set="$trimmed"
            else
              selected_set="$selected_set $trimmed"
            fi
            ;;
        esac

        test "$has_more" -eq 0 && break
      done

      test -n "$selected_set" || die empty_group_selection

      : > "$SANDBOX/selected.txt"
      : > "$SANDBOX/unselected.txt"
      while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
        test -n "$gname" || continue
        case " $selected_set " in
          *" $gname "*) printf '%s\n' "$gname" >> "$SANDBOX/selected.txt" ;;
          *) printf '%s\n' "$gname" >> "$SANDBOX/unselected.txt" ;;
        esac
      done < "$SANDBOX/groups.tsv"
      ;;
    interactive)
      select_interactively
      ;;
    *)
      die selection_conflict
      ;;
  esac
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
