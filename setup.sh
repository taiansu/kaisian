#!/bin/bash
set -u

readonly KAISIAN_VERSION='0.2.0'
readonly DEFAULT_REPOSITORY='taiansu/dotfiles'
readonly DEFAULT_DOTFILES_REF='kaisian'

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
REQUESTED_REF="$DEFAULT_DOTFILES_REF"
CANONICAL_REPO=''
RESOLVED_FETCH_REF=''
RESOLVED_COMMIT=''
EXPECTED_COMMIT_SHA=''
RECORDED_LOCK_DEV_INO=''
RECORDED_SANDBOX_DEV_INO=''
GIT_EXEC=''
STOW_EXEC=''
FZF_EXEC=''
PLUTIL_EXEC=''
BREW_EXEC=''
MISE_EXEC=''
SELECTED_FONT=''
SELECTED_BREW=''
SELECTED_LANGS=''
SELECTED_FEATURES=''
STOW_ONLY=0
MISE_TOOLS=''
RUN_TIMESTAMP=''
MAPPING_FILE=''
CONFLICTS_FILE=''
STOW_IGNORE_FILE=''
BACKUP_ROOT=''
CONFIRMED=0

has_control_char() {
  LC_ALL=C
  case "${1-}" in
    *[[:cntrl:]]*) return 0 ;;
    *) return 1 ;;
  esac
}

shell_quote() {
  local arg=${1-}
  local sq="'"
  local repl="'\\''"
  local escaped="${arg//$sq/$repl}"
  printf "'%s'" "$escaped"
}

append_directory_rows() {
  dir_rel=$1
  dir_seen=$2
  old_ifs=$IFS
  IFS='/'
  set -f
  set -- $dir_rel
  set +f
  IFS=$old_ifs
  prefix=''
  for component in "$@"; do
    test -n "$component" || continue
    if test -n "$prefix"; then prefix="$prefix/$component"; else prefix="$component"; fi
    target=$(normalized_relpath "$prefix") || return 1
    if ! /usr/bin/grep -F -x -q -e "$prefix" "$dir_seen" 2>/dev/null; then
      key=$(ascii_fold "$target")
      printf '%s\n' "$prefix" >> "$dir_seen" || return 1
      printf 'dir\t%s\t%s\t%s\t%s\n' "$CURRENT_PACKAGE" "$prefix" "$target" "$key" >> "$MAPPING_FILE" || return 1
    fi
  done
}
ascii_fold() {
  LC_ALL=C
  printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

normalized_relpath() {
  rel=$1
  old_ifs=$IFS
  IFS='/'
  set -f
  set -- $rel
  set +f
  IFS=$old_ifs
  out=''
  for comp in "$@"; do
    test -n "$comp" || continue
    case "$comp" in
      .|..) return 1 ;;
    esac
    has_control_char "$comp" && return 1
    case "$comp" in
      dot-*) comp=".${comp#dot-}" ;;
    esac
    case "$comp" in
      .|..) return 1 ;;
    esac
    if test -n "$out"; then out="$out/$comp"; else out="$comp"; fi
  done
  test -n "$out" || return 1
  printf '%s\n' "$out"
}

build_package_map() {
  test -n "$SANDBOX" && test -d "$SANDBOX" || return 1
  test -n "$CHECKOUT_DIR" && test -d "$CHECKOUT_DIR" || return 1
  MAPPING_FILE="$SANDBOX/mapping.tsv"
  STOW_IGNORE_FILE="$SANDBOX/stow-ignore.txt"
  : > "$MAPPING_FILE" || return 1
  : > "$STOW_IGNORE_FILE" || return 1
  test -f "$SANDBOX/groups.tsv" || return 1
  dir_seen="$SANDBOX/package-dirs-$$"
  : > "$dir_seen" || return 1

  while IFS='	' read -r package desc_en desc_zh || test -n "$package"; do
    test -n "$package" || continue
    is_pure_ascii "$package" || return 1
    case "$package" in */*|.|..) return 1 ;; esac
    pkg="$CHECKOUT_DIR/$package"
    test -d "$pkg" && test ! -L "$pkg" || return 1
    CURRENT_PACKAGE=$package

    # Inspect every filesystem node, not only Git-index entries.
    tree_nodes="$SANDBOX/package-tree-$$"
    /usr/bin/find -P "$pkg" -print0 > "$tree_nodes" || { /bin/rm -f "$tree_nodes"; return 1; }
    while IFS= read -r -d '' node; do
      test "$node" = "$pkg" && continue
      relnode=${node#"$pkg"/}
      is_pure_ascii "$relnode" || { /bin/rm -f "$tree_nodes"; return 1; }
      test ! -L "$node" || { /bin/rm -f "$tree_nodes"; return 1; }
      case "$relnode" in */.git|.git/*|.git) /bin/rm -f "$tree_nodes"; return 1 ;; esac
      if test -d "$node"; then
        child=$(/usr/bin/find -P "$node" -mindepth 1 -maxdepth 1 -print -quit)
        test -n "$child" || { /bin/rm -f "$tree_nodes"; return 1; }
      fi
    done < "$tree_nodes"
    /bin/rm -f "$tree_nodes"

    # Git's NUL-delimited status is the authoritative check for untracked,
    # ignored, modified, deleted, and renamed payload entries.
    status_file="$SANDBOX/package-status-$$"
    run_git -C "$CHECKOUT_DIR" status --porcelain=v1 --untracked-files=all \
      --ignored=matching --ignore-submodules=none -z -- "$package" > "$status_file" 2>/dev/null || {
      /bin/rm -f "$status_file"
      return 1
    }
    test ! -s "$status_file" || {
      /bin/rm -f "$status_file"
      return 1
    }
    /bin/rm -f "$status_file"

    entries="$SANDBOX/package-index-$$"
    : > "$entries" || return 1
    run_git -C "$CHECKOUT_DIR" ls-files --stage -z -- "$package" > "$entries" 2>/dev/null || {
      /bin/rm -f "$entries"
      return 1
    }
    package_count=0
    while IFS= read -r -d '' entry; do
      meta=${entry%%	*}
      rel=${entry#*	}
      mode=${meta%% *}
      case "$mode" in
        100644|100755) ;;
        120000|160000) /bin/rm -f "$entries"; return 1 ;;
        *) /bin/rm -f "$entries"; return 1 ;;
      esac
      test -n "$rel" || { /bin/rm -f "$entries"; return 1; }
      case "$rel" in
        "$package"/*) rel=${rel#"$package"/} ;;
        *) /bin/rm -f "$entries"; return 1 ;;
      esac
      target=$(normalized_relpath "$rel") || { /bin/rm -f "$entries"; return 1; }
      file_target=$target
      is_pure_ascii "$rel" || { /bin/rm -f "$entries"; return 1; }
      # Dotfiles must use the explicit dot- encoding; a decoded traversal
      # component (dot-. or dot-..) is never accepted.
      old_ifs=$IFS
      IFS='/'
      set -f
      set -- $rel
      set +f
      IFS=$old_ifs
      for comp in "$@"; do
        test -n "$comp" || continue
        case "$comp" in
          .*) /bin/rm -f "$entries"; return 1 ;;
          dot-.) /bin/rm -f "$entries"; return 1 ;;
          dot-..) /bin/rm -f "$entries"; return 1 ;;
        esac
      done
      source="$CHECKOUT_DIR/$package/$rel"
      test -f "$source" && test ! -L "$source" || {
        /bin/rm -f "$entries"
        return 1
      }
      case "$rel" in
        */*) append_directory_rows "${rel%/*}" "$dir_seen" || {
          /bin/rm -f "$entries" "$dir_seen"
          return 1
        } ;;
      esac
      target=$file_target
      key=$(ascii_fold "$target")
      printf 'file\t%s\t%s\t%s\t%s\n' "$package" "$rel" "$target" "$key" >> "$MAPPING_FILE" || {
        /bin/rm -f "$entries" "$dir_seen"
        return 1
      }
      package_count=$((package_count + 1))
    done < "$entries"
    test "$package_count" -gt 0 || return 1
  done < "$SANDBOX/groups.tsv"
  /bin/rm -f "$dir_seen"
  return 0
}

validate_typed_tree() {
  test -f "$MAPPING_FILE" || return 1
  rows="$SANDBOX/typed-tree-$$"
  : > "$rows" || return 1
  while IFS='	' read -r typ pkg src target folded extra || test -n "$typ"; do
    case "$typ" in dir|file) ;; *) /bin/rm -f "$rows"; return 1 ;; esac
    test -n "$pkg" && test -n "$src" && test -n "$target" && test -n "$folded" || {
      /bin/rm -f "$rows"
      return 1
    }
    test -z "$extra" || { /bin/rm -f "$rows"; return 1; }
    is_pure_ascii "$pkg" && is_pure_ascii "$src" && is_pure_ascii "$target" || {
      /bin/rm -f "$rows"
      return 1
    }
    expected_target=$(normalized_relpath "$src") || { /bin/rm -f "$rows"; return 1; }
    test "$target" = "$expected_target" || { /bin/rm -f "$rows"; return 1; }
    expected_folded=$(ascii_fold "$target")
    test "$folded" = "$expected_folded" || { /bin/rm -f "$rows"; return 1; }
    while IFS='	' read -r oldtyp oldtarget oldfolded || test -n "$oldtarget"; do
      test -n "$oldtarget" || continue
      if test "$folded" = "$oldfolded"; then
        test "$typ" = dir && test "$oldtyp" = dir || { /bin/rm -f "$rows"; return 1; }
      elif test "$typ" = file && test "$oldtyp" = file; then
        case "$folded/" in "$oldfolded/"*) /bin/rm -f "$rows"; return 1 ;; esac
        case "$oldfolded/" in "$folded/"*) /bin/rm -f "$rows"; return 1 ;; esac
      fi
    done < "$rows"
    printf '%s\t%s\t%s\n' "$typ" "$target" "$folded" >> "$rows" || {
      /bin/rm -f "$rows"
      return 1
    }
  done < "$MAPPING_FILE"
  test -s "$rows"
  result=$?
  /bin/rm -f "$rows"
  return "$result"
}

paths_overlap() {
  test "$1" = "$2" && return 0
  test "$1" = '/' && return 0
  test "$2" = '/' && return 0
  case "$1/" in "$2/"*) return 0 ;; esac
  case "$2/" in "$1/"*) return 0 ;; esac
  return 1
}

physical_parent_safe() {
  target_path=$1
  case "$target_path" in
    "$PHYSICAL_HOME"/*) ;;
    *) return 1 ;;
  esac
  parent=${target_path%/*}
  while test "$parent" != "$PHYSICAL_HOME" && test "$parent" != '/'; do
    if test -L "$parent"; then return 1; fi
    if test -e "$parent" && test ! -d "$parent"; then return 1; fi
    parent=${parent%/*}
    test -n "$parent" || parent='/'
  done
  test "$parent" = "$PHYSICAL_HOME" || return 1
  return 0
}

nearest_existing() {
  p=$1
  while test ! -e "$p" && test ! -L "$p"; do
    p=${p%/*}
    test -n "$p" || p='/'
    test "$p" != '/' || break
  done
  printf '%s\n' "$p"
}

stat_dev() {
  if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_STAT_EXEC-}"; then
    "$KAISIAN_STAT_EXEC" -f '%d' "$1" 2>/dev/null
  else
    /usr/bin/stat -f '%d' "$1" 2>/dev/null
  fi
}

preflight_targets() {
  has_control_char "${PHYSICAL_HOME-}" && return 1
  has_control_char "${HOME-}" && return 1
  has_control_char "${XDG_STATE_HOME-}" && return 1
  has_control_char "${STATE_ROOT-}" && return 1
  has_control_char "${CHECKOUT_DIR-}" && return 1
  has_control_char "${LOCK_DIR-}" && return 1
  has_control_char "${SANDBOX-}" && return 1

  : "${PHYSICAL_HOME:=${HOME-}}"
  test -n "$PHYSICAL_HOME" && test "${PHYSICAL_HOME#/}" != "$PHYSICAL_HOME" || return 1
  test -d "$PHYSICAL_HOME" && test ! -L "$PHYSICAL_HOME" || return 1
  PHYSICAL_HOME=$(canonicalize_path "$PHYSICAL_HOME") || return 1
  if test -n "${XDG_STATE_HOME+x}" && test -n "$XDG_STATE_HOME"; then
    case "$XDG_STATE_HOME" in
      /*) raw_state_root="$XDG_STATE_HOME/kaisian" ;;
      *) return 1 ;;
    esac
  elif test -z "$STATE_ROOT"; then
    raw_state_root="$PHYSICAL_HOME/.local/state/kaisian"
  else
    raw_state_root="$STATE_ROOT"
  fi
  case "$raw_state_root" in
    /*) ;;
    *) return 1 ;;
  esac
  has_control_char "$raw_state_root" && return 1

  # Walk every raw absolute existing component before canonicalize
  sr_curr="$raw_state_root"
  while test "$sr_curr" != '/' && test -n "$sr_curr"; do
    if test -L "$sr_curr"; then return 1; fi
    if test -e "$sr_curr" && test ! -d "$sr_curr"; then return 1; fi
    sr_curr=${sr_curr%/*}
    test -n "$sr_curr" || sr_curr='/'
  done

  STATE_ROOT=$(canonicalize_path "$raw_state_root") || return 1
  has_control_char "$STATE_ROOT" && return 1
  backup_base="$STATE_ROOT/backups"

  # Compute unique non-reserved timestamped candidate BACKUP_ROOT
  n=0
  while :; do
    if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_TEST_TIME-}"; then
      utc_ts="$KAISIAN_TEST_TIME"
    else
      utc_ts=$(/bin/date -u '+%Y%m%dT%H%M%SZ')
    fi
    BACKUP_ROOT="$backup_base/$utc_ts-$$"
    test "$n" -eq 0 || BACKUP_ROOT="$BACKUP_ROOT-$n"
    test ! -e "$BACKUP_ROOT" && test ! -L "$BACKUP_ROOT" && break
    n=$((n + 1))
  done
  b_curr="$backup_base"
  while test "$b_curr" != '/' && test "$b_curr" != "$STATE_ROOT"; do
    if test -L "$b_curr"; then return 1; fi
    if test -e "$b_curr" && test ! -d "$b_curr"; then return 1; fi
    b_curr=${b_curr%/*}
    test -n "$b_curr" || b_curr='/'
  done

  canon_checkout=''
  if test -n "$CHECKOUT_DIR"; then
    canon_checkout=$(canonicalize_path "$CHECKOUT_DIR") || return 1
  fi
  canon_lock=''
  if test -n "$LOCK_DIR"; then
    canon_lock=$(canonicalize_path "$LOCK_DIR") || return 1
  fi
  canon_sandbox=''
  if test -n "$SANDBOX"; then
    canon_sandbox=$(canonicalize_path "$SANDBOX") || return 1
  fi

  if test -n "$canon_checkout" && test -n "$STATE_ROOT"; then
    paths_overlap "$canon_checkout" "$STATE_ROOT" && return 1
  fi
  if test -n "$canon_checkout" && test -n "$canon_lock"; then
    paths_overlap "$canon_checkout" "$canon_lock" && return 1
  fi
  if test -n "$canon_checkout" && test -n "$canon_sandbox"; then
    paths_overlap "$canon_checkout" "$canon_sandbox" && return 1
  fi
  if test -n "$STATE_ROOT" && test -n "$canon_lock"; then
    paths_overlap "$STATE_ROOT" "$canon_lock" && return 1
  fi
  if test -n "$STATE_ROOT" && test -n "$canon_sandbox"; then
    paths_overlap "$STATE_ROOT" "$canon_sandbox" && return 1
  fi

  test -n "$SANDBOX" && test -d "$SANDBOX" || return 1
  MAPPING_FILE="$SANDBOX/mapping.tsv"
  test -f "$MAPPING_FILE" || return 1
  test -f "$SANDBOX/selected.txt" || return 1

  CONFLICTS_FILE="$SANDBOX/conflicts.tsv"
  : > "$CONFLICTS_FILE" || return 1
  IDENTITIES_FILE="$SANDBOX/conflicts_identities.tsv"
  : > "$IDENTITIES_FILE" || return 1

  while IFS='	' read -r typ pkg src target folded extra || test -n "$typ"; do
    test -n "$typ" || continue
    /usr/bin/grep -F -x -q -e "$pkg" "$SANDBOX/selected.txt" || continue

    dst="$PHYSICAL_HOME/$target"
    case "$dst" in
      "$PHYSICAL_HOME"/*) ;;
      *) return 1 ;;
    esac

    for guard in "$canon_checkout" "$STATE_ROOT" "$canon_lock" "$canon_sandbox" "$BACKUP_ROOT"; do
      test -n "$guard" || continue
      paths_overlap "$dst" "$guard" && return 1
    done

    if test "$typ" = 'dir'; then
      physical_parent_safe "$dst" || return 1
      if test -L "$dst"; then
        return 1
      fi
      if test -e "$dst" && test ! -d "$dst"; then
        return 1
      fi
      continue
    fi

    test "$typ" = 'file' || return 1
    source="$CHECKOUT_DIR/$pkg/$src"

    physical_parent_safe "$dst" || return 1

    if test ! -e "$dst" && test ! -L "$dst"; then
      continue
    fi

    if test -e "$dst" && test ! -L "$dst" && test ! -f "$dst" && test ! -d "$dst"; then
      return 1
    fi

    is_exact_leaf=0
    if test -L "$dst"; then
      if test -e "$dst" && test "$dst" -ef "$source"; then
        is_exact_leaf=1
      fi
    fi

    if test "$is_exact_leaf" -eq 1; then
      continue
    fi

    backup="$BACKUP_ROOT/files/$target"

    # Validate that every existing ancestor of backup destination is safe (no symlink, real dir)
    bk_ancestor_check="$backup"
    while test "$bk_ancestor_check" != '/' && test -n "$bk_ancestor_check"; do
      if test -L "$bk_ancestor_check"; then return 1; fi
      if test -e "$bk_ancestor_check" && test ! -d "$bk_ancestor_check"; then return 1; fi
      bk_ancestor_check=${bk_ancestor_check%/*}
      test -n "$bk_ancestor_check" || bk_ancestor_check='/'
    done

    dst_dev=$(stat_dev "$dst") || return 1
    test -n "$dst_dev" || return 1
    backup_ancestor=$(nearest_existing "$backup")
    backup_dev=$(stat_dev "$backup_ancestor") || return 1
    test -n "$backup_dev" || return 1
    test "$dst_dev" = "$backup_dev" || return 1

    printf '%s\t%s\n' "$dst" "$backup" >> "$CONFLICTS_FILE" || return 1
    dst_ino=$(/usr/bin/stat -f '%i' "$dst" 2>/dev/null) || return 1
    test -n "$dst_ino" || return 1
    has_control_char "$dst_ino" && return 1
    dst_type=$(/usr/bin/stat -f '%HT' "$dst" 2>/dev/null) || return 1
    test -n "$dst_type" || return 1
    has_control_char "$dst_type" && return 1
    dst_mode=$(/usr/bin/stat -f '%p' "$dst" 2>/dev/null) || return 1
    test -n "$dst_mode" || return 1
    has_control_char "$dst_mode" && return 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$dst" "$dst_dev" "$dst_ino" "$dst_type" "$dst_mode" >> "$IDENTITIES_FILE" || return 1
  done < "$MAPPING_FILE"

  if test -f "$SANDBOX/selected_features.txt" && test -f "$SANDBOX/feature_copy.tsv"; then
    while IFS= read -r sel_feat || test -n "$sel_feat"; do
      test -n "$sel_feat" || continue
      while IFS='	' read -r c_feat c_from c_to || test -n "$c_feat"; do
        test "$c_feat" = "$sel_feat" || continue
        test -n "$c_to" || continue

        dst="$PHYSICAL_HOME/$c_to"
        case "$dst" in
          "$PHYSICAL_HOME"/*) ;;
          *) return 1 ;;
        esac

        for guard in "$canon_checkout" "$STATE_ROOT" "$canon_lock" "$canon_sandbox" "$BACKUP_ROOT"; do
          test -n "$guard" || continue
          paths_overlap "$dst" "$guard" && return 1
        done

        physical_parent_safe "$dst" || return 1

        if test ! -e "$dst" && test ! -L "$dst"; then
          continue
        fi

        if test -e "$dst" && test ! -L "$dst" && test ! -f "$dst" && test ! -d "$dst"; then
          return 1
        fi

        backup="$BACKUP_ROOT/files/$c_to"

        bk_ancestor_check="$backup"
        while test "$bk_ancestor_check" != '/' && test -n "$bk_ancestor_check"; do
          if test -L "$bk_ancestor_check"; then return 1; fi
          if test -e "$bk_ancestor_check" && test ! -d "$bk_ancestor_check"; then return 1; fi
          bk_ancestor_check=${bk_ancestor_check%/*}
          test -n "$bk_ancestor_check" || bk_ancestor_check='/'
        done

        dst_dev=$(stat_dev "$dst") || return 1
        test -n "$dst_dev" || return 1
        backup_ancestor=$(nearest_existing "$backup")
        backup_dev=$(stat_dev "$backup_ancestor") || return 1
        test -n "$backup_dev" || return 1
        test "$dst_dev" = "$backup_dev" || return 1

        if ! /usr/bin/grep -F -e "$(printf '%s\t' "$dst")" "$CONFLICTS_FILE" 2>/dev/null; then
          printf '%s\t%s\n' "$dst" "$backup" >> "$CONFLICTS_FILE" || return 1
          dst_ino=$(/usr/bin/stat -f '%i' "$dst" 2>/dev/null) || return 1
          test -n "$dst_ino" || return 1
          has_control_char "$dst_ino" && return 1
          dst_type=$(/usr/bin/stat -f '%HT' "$dst" 2>/dev/null) || return 1
          test -n "$dst_type" || return 1
          has_control_char "$dst_type" && return 1
          dst_mode=$(/usr/bin/stat -f '%p' "$dst" 2>/dev/null) || return 1
          test -n "$dst_mode" || return 1
          has_control_char "$dst_mode" && return 1
          printf '%s\t%s\t%s\t%s\t%s\n' "$dst" "$dst_dev" "$dst_ino" "$dst_type" "$dst_mode" >> "$IDENTITIES_FILE" || return 1
        fi
      done < "$SANDBOX/feature_copy.tsv"
    done < "$SANDBOX/selected_features.txt"
  fi
  return 0
}

run_mv() {
  if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_MV_EXEC-}"; then
    "$KAISIAN_MV_EXEC" "$@"
  else
    /bin/mv "$@"
  fi
}

prompt_tty() {
  if test "${KAISIAN_TESTING-0}" = '1'; then
    if test -n "${KAISIAN_TESTING_PROMPT_FAIL-}"; then
      return 1
    fi
    if test "${KAISIAN_TESTING_TTY-}" = '1'; then
      if test -n "${KAISIAN_TESTING_PROMPT_TRACE_LOG-}"; then
        printf 'PROMPT_REACHED\n' >> "$KAISIAN_TESTING_PROMPT_TRACE_LOG"
      fi
      return 0
    fi
  fi
  printf '%s ' 'Proceed? [y/N]' > /dev/tty
}

read_tty() {
  if test "${KAISIAN_TESTING-0}" = '1'; then
    if test -n "${KAISIAN_TESTING_READ_FAIL-}"; then
      return 1
    fi
    if test -n "${KAISIAN_TESTING_ANSWER+x}"; then
      answer="$KAISIAN_TESTING_ANSWER"
      return 0
    fi
    if test "${KAISIAN_TESTING_TTY-}" = '1'; then
      return 1
    fi
  fi
  IFS= read -r answer < /dev/tty
}

confirm_conflicts() {
  test -f "$CONFLICTS_FILE" || return 1
  if test ! -s "$CONFLICTS_FILE"; then
    CONFIRMED=1
    return 0
  fi
  while IFS='	' read -r source backup extra || test -n "$source"; do
    test -n "$source" || continue
    printf 'Move %s to %s\n' "$source" "$backup"
  done < "$CONFLICTS_FILE"
  if test "$DRY_RUN" -eq 1; then
    return 0
  fi
  if test "$ASSUME_YES" -eq 1; then
    CONFIRMED=1
    return 0
  fi
  if test "${KAISIAN_TESTING-0}" = '1' && test "${KAISIAN_TESTING_TTY-}" = '0'; then
    err_pfx=$(message error_prefix 2>/dev/null) || err_pfx='Error'
    msg=$(message no_tty 2>/dev/null) || msg='A controlling terminal is required.'
    printf '%s: %s\n' "$err_pfx" "$msg" >&2
    CONFIRMED=0
    return 1
  elif test "${KAISIAN_TESTING-0}" != '1' || test "${KAISIAN_TESTING_TTY-}" != '1'; then
    if ! ( : < /dev/tty && : > /dev/tty ) 2>/dev/null; then
      err_pfx=$(message error_prefix 2>/dev/null) || err_pfx='Error'
      msg=$(message no_tty 2>/dev/null) || msg='A controlling terminal is required.'
      printf '%s: %s\n' "$err_pfx" "$msg" >&2
      CONFIRMED=0
      return 1
    fi
  fi
  if ! prompt_tty 2>/dev/null; then
    err_pfx=$(message error_prefix 2>/dev/null) || err_pfx='Error'
    msg=$(message no_tty 2>/dev/null) || msg='A controlling terminal is required.'
    printf '%s: %s\n' "$err_pfx" "$msg" >&2
    CONFIRMED=0
    return 1
  fi
  if ! read_tty; then
    err_pfx=$(message error_prefix 2>/dev/null) || err_pfx='Error'
    msg=$(message no_tty 2>/dev/null) || msg='A controlling terminal is required.'
    printf '%s: %s\n' "$err_pfx" "$msg" >&2
    CONFIRMED=0
    return 1
  fi
  case "$answer" in
    y|Y|yes|YES)
      CONFIRMED=1
      return 0
      ;;
    *)
      CONFIRMED=0
      return 0
      ;;
  esac
}

revalidate_conflict() {
  local target_src=$1
  local target_bk=$2
  local match_count=0
  local row_src row_dev row_ino row_type row_mode extra_id
  local cur_dev cur_ino cur_type cur_mode bk_ancestor bk_dev

  # Re-run physical_parent_safe on source
  physical_parent_safe "$target_src" || return 1

  # Source must exist (regular, directory, or symlink)
  if test ! -e "$target_src" && test ! -L "$target_src"; then
    return 1
  fi
  if test -e "$target_src" && test ! -L "$target_src" && test ! -f "$target_src" && test ! -d "$target_src"; then
    return 1
  fi

  # Find matching row in $IDENTITIES_FILE using pure literal comparison
  while IFS='	' read -r row_src row_dev row_ino row_type row_mode extra_id || test -n "$row_src"; do
    test -n "$row_src" || return 1
    test -n "$row_dev" || return 1
    test -n "$row_ino" || return 1
    test -n "$row_type" || return 1
    test -n "$row_mode" || return 1
    test -z "$extra_id" || return 1
    if test "$row_src" = "$target_src"; then
      match_count=$((match_count + 1))
      test "$match_count" -eq 1 || return 1 # reject duplicates

      cur_dev=$(stat_dev "$target_src") || return 1
      test -n "$cur_dev" || return 1
      test "$cur_dev" = "$row_dev" || return 1

      cur_ino=$(/usr/bin/stat -f '%i' "$target_src" 2>/dev/null) || return 1
      test "$cur_ino" = "$row_ino" || return 1

      cur_type=$(/usr/bin/stat -f '%HT' "$target_src" 2>/dev/null) || return 1
      test "$cur_type" = "$row_type" || return 1

      cur_mode=$(/usr/bin/stat -f '%p' "$target_src" 2>/dev/null) || return 1
      test "$cur_mode" = "$row_mode" || return 1
    fi
  done < "$IDENTITIES_FILE"

  test "$match_count" -eq 1 || return 1

  # Re-check source device against nearest destination ancestor device
  bk_ancestor=$(nearest_existing "$target_bk")
  bk_dev=$(stat_dev "$bk_ancestor") || return 1
  test -n "$bk_dev" || return 1
  test "$cur_dev" = "$bk_dev" || return 1

  return 0
}

record_backup_tree_identities() {
  local identity_file=$1
  local path canon dev ino
  : > "$identity_file" || return 1
  for path in "$STATE_ROOT" "$backup_base" "$BACKUP_ROOT" "$BACKUP_ROOT/files"; do
    test -d "$path" && test ! -L "$path" || return 1
    canon=$(canonicalize_path "$path") || return 1
    dev=$(stat_dev "$path") || return 1
    ino=$(/usr/bin/stat -f '%i' "$path" 2>/dev/null) || return 1
    test -n "$canon" && test -n "$dev" && test -n "$ino" || return 1
    has_control_char "$path" && return 1
    has_control_char "$canon" && return 1
    printf '%s\t%s\t%s\t%s\n' "$path" "$canon" "$dev" "$ino" >> "$identity_file" || return 1
  done
  test "$(/usr/bin/wc -l < "$identity_file" | /usr/bin/tr -d ' ')" = '4'
}

verify_backup_tree_identities() {
  local identity_file=$1
  local path canon dev ino extra current_canon current_dev current_ino count=0
  test -f "$identity_file" && test -s "$identity_file" || return 1
  while IFS='	' read -r path canon dev ino extra || test -n "$path"; do
    test -n "$path" && test -n "$canon" && test -n "$dev" && test -n "$ino" || return 1
    test -z "$extra" || return 1
    test -d "$path" && test ! -L "$path" || return 1
    current_canon=$(canonicalize_path "$path") || return 1
    current_dev=$(stat_dev "$path") || return 1
    current_ino=$(/usr/bin/stat -f '%i' "$path" 2>/dev/null) || return 1
    test "$current_canon" = "$canon" || return 1
    test "$current_dev" = "$dev" || return 1
    test "$current_ino" = "$ino" || return 1
    count=$((count + 1))
  done < "$identity_file"
  test "$count" -eq 4
}

emit_restore_guidance() {
  local err_pfx bk_root_msg q_dest q_src restore_msg s b
  err_pfx=$(message error_prefix 2>/dev/null) || err_pfx='Error'
  bk_root_msg=$(message backup_root "$BACKUP_ROOT" 2>/dev/null) || bk_root_msg="Backup root: $BACKUP_ROOT"
  printf '%s: %s\n' "$err_pfx" "$bk_root_msg" >&2

  while IFS='	' read -r s b extra || test -n "$s"; do
    test -n "$s" || continue
    if (test ! -e "$s" && test ! -L "$s") && (test -e "$b" || test -L "$b"); then
      q_dest=$(shell_quote "$b")
      q_src=$(shell_quote "$s")
      restore_msg=$(message manual_restore "$q_dest" "$q_src" 2>/dev/null) || restore_msg="Restore manually with: mv $q_dest $q_src"
      printf '%s: %s\n' "$err_pfx" "$restore_msg" >&2
    fi
  done < "$CONFLICTS_FILE"
}

move_conflicts() {
  test "$DRY_RUN" -eq 0 || return 0
  test -f "$CONFLICTS_FILE" || return 1
  test ! -s "$CONFLICTS_FILE" && return 0
  test -n "${BACKUP_ROOT-}" || return 1
  has_control_char "$BACKUP_ROOT" && return 1
  case "$BACKUP_ROOT" in
    /*) ;;
    *) return 1 ;;
  esac

  test -n "$SANDBOX" && test -d "$SANDBOX" || return 1
  completed_file="$SANDBOX/completed_moves.tsv"
  if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_TESTING_TRACKING_CREATE_FAIL-}"; then
    return 1
  fi
  : > "$completed_file" || return 1

  backup_base=${BACKUP_ROOT%/*}
  test -n "$backup_base" || return 1

  IDENTITIES_FILE="$SANDBOX/conflicts_identities.tsv"
  test -f "$IDENTITIES_FILE" && test -s "$IDENTITIES_FILE" || return 1

  conflicts_cnt=$(/usr/bin/wc -l < "$CONFLICTS_FILE" | /usr/bin/tr -d ' ')
  identities_cnt=$(/usr/bin/wc -l < "$IDENTITIES_FILE" | /usr/bin/tr -d ' ')
  test "$conflicts_cnt" = "$identities_cnt" || return 1

  # Pass 1: Validate EVERY row without any filesystem mutation
  while IFS='	' read -r source backup extra || test -n "$source"; do
    test -n "$source" || return 1
    test -n "$backup" || return 1
    test -z "$extra" || return 1
    has_control_char "$source" && return 1
    has_control_char "$backup" && return 1
    case "$source" in
      "$PHYSICAL_HOME"/*) ;;
      *) return 1 ;;
    esac
    case "$backup" in
      "$BACKUP_ROOT/files"/*) ;;
      *) return 1 ;;
    esac

    rel_src=${source#"$PHYSICAL_HOME/"}
    test -n "$rel_src" || return 1
    old_ifs=$IFS
    IFS='/'
    set -f
    set -- $rel_src
    set +f
    IFS=$old_ifs
    test $# -gt 0 || return 1
    for comp in "$@"; do
      test -n "$comp" || return 1
      test "$comp" != '.' || return 1
      test "$comp" != '..' || return 1
    done
    if test "$backup" != "$BACKUP_ROOT/files/$rel_src"; then
      return 1
    fi

    revalidate_conflict "$source" "$backup" || return 1
  done < "$CONFLICTS_FILE"

  # Immediately before mutation: re-walk ALL raw state/backup ancestors, reject symlink/non-dir
  chk_ancestor="$backup_base"
  while test "$chk_ancestor" != '/' && test -n "$chk_ancestor"; do
    if test -L "$chk_ancestor"; then return 1; fi
    if test -e "$chk_ancestor" && test ! -d "$chk_ancestor"; then return 1; fi
    chk_ancestor=${chk_ancestor%/*}
    test -n "$chk_ancestor" || chk_ancestor='/'
  done

  # Re-check each source against nearest destination ancestor device
  while IFS='	' read -r source backup extra || test -n "$source"; do
    test -n "$source" || continue
    src_dev=$(stat_dev "$source") || return 1
    test -n "$src_dev" || return 1
    bk_ancestor=$(nearest_existing "$backup")
    bk_dev=$(stat_dev "$bk_ancestor") || return 1
    test -n "$bk_dev" || return 1
    test "$src_dev" = "$bk_dev" || return 1
  done < "$CONFLICTS_FILE"

  # Defensively create backup_base and re-walk ALL components after creation to ensure no intermediate symlinks
  /bin/mkdir -p "$backup_base" || return 1
  chk_after="$backup_base"
  while test "$chk_after" != '/' && test -n "$chk_after"; do
    if test -L "$chk_after"; then return 1; fi
    if test ! -d "$chk_after"; then return 1; fi
    chk_after=${chk_after%/*}
    test -n "$chk_after" || chk_after='/'
  done

  # Atomically reserve BACKUP_ROOT
  /bin/mkdir -m 0700 "$BACKUP_ROOT" 2>/dev/null || return 1
  if test -L "$BACKUP_ROOT" || test ! -d "$BACKUP_ROOT"; then return 1; fi

  # Create $BACKUP_ROOT/files
  files_ok=1
  if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_TESTING_FILES_FAIL-}"; then
    files_ok=0
  elif ! /bin/mkdir -p "$BACKUP_ROOT/files" || test -L "$BACKUP_ROOT/files"; then
    files_ok=0
  fi
  if test "$files_ok" -eq 0; then
    emit_restore_guidance
    return 1
  fi

  BACKUP_TREE_IDENTITIES_FILE="$SANDBOX/backup_tree_identities.tsv"
  if ! record_backup_tree_identities "$BACKUP_TREE_IDENTITIES_FILE"; then
    emit_restore_guidance
    return 1
  fi

  # Pass 2: Move execution with exact completed move tracking and derivation
  while IFS='	' read -r source backup extra || test -n "$source"; do
    test -n "$source" || continue
    dest="$backup"
    dest_parent=${dest%/*}

    if ! /bin/mkdir -p "$dest_parent" || test -L "$dest_parent"; then
      emit_restore_guidance
      return 1
    fi

    if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_TESTING_PRE_MV_HOOK-}"; then
      eval "$KAISIAN_TESTING_PRE_MV_HOOK" || true
    fi

    if ! verify_backup_tree_identities "$BACKUP_TREE_IDENTITIES_FILE"; then
      emit_restore_guidance
      return 1
    fi

    # Re-walk raw backup destination parents from dest_parent up to $BACKUP_ROOT/files
    p_chk="$dest_parent"
    files_root="$BACKUP_ROOT/files"
    while test "$p_chk" != "$files_root" && test "$p_chk" != '/' && test -n "$p_chk"; do
      if test -L "$p_chk" || test ! -d "$p_chk"; then
        emit_restore_guidance
        return 1
      fi
      p_chk=${p_chk%/*}
      test -n "$p_chk" || p_chk='/'
    done
    if test -L "$files_root" || test ! -d "$files_root"; then
      emit_restore_guidance
      return 1
    fi

    # Verify canonical containment under BACKUP_ROOT/files
    canon_dest_p=$(canonicalize_path "$dest_parent") || {
      emit_restore_guidance
      return 1
    }
    canon_files_r=$(canonicalize_path "$files_root") || {
      emit_restore_guidance
      return 1
    }
    case "$canon_dest_p" in
      "$canon_files_r"|"$canon_files_r"/*) ;;
      *)
        emit_restore_guidance
        return 1
        ;;
    esac

    if ! revalidate_conflict "$source" "$backup"; then
      emit_restore_guidance
      return 1
    fi
    if ! run_mv "$source" "$dest"; then
      emit_restore_guidance
      return 1
    fi

    if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_TESTING_APPEND_FAIL-}"; then
      emit_restore_guidance
      return 1
    fi

    printf '%s\t%s\n' "$dest" "$source" >> "$completed_file" || {
      emit_restore_guidance
      return 1
    }
  done < "$CONFLICTS_FILE"
  return 0
}

usage() {
  printf '%s\n' \
'setup.sh [OPTIONS]

Selection, exactly zero or one (none: the default profile from the manifest):
  --prompt NAME
  --profile NAME
  --groups GROUPS
  --interactive
  --all

Customization (optional):
  --font CASK
  --brew PKG[,PKG...]
  --langs LANG[,LANG...]
  --features NAME[,NAME...]
  --stow-only

Source and execution:
  --repo URL|OWNER/REPO[/tree/REF]
  --ref REF
  --dir PATH
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
    selection_conflict) printf 'Selection flags (--prompt, --profile, --groups, --interactive, --all) are mutually exclusive.' ;;
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
        group_invalid_kind) printf "Invalid manifest: group %s invalid 'kind'." "${2-}" ;;
        fonts_not_array) printf "Invalid manifest: 'fonts' must be an array." ;;
        font_not_object) printf 'Invalid manifest: font item %s must be an object.' "${2-}" ;;
        font_missing_cask) printf "Invalid manifest: font %s missing 'cask'." "${2-}" ;;
        font_invalid_cask) printf "Invalid manifest: invalid font cask '%s'." "${2-}" ;;
        font_duplicate_cask) printf "Invalid manifest: duplicate font cask '%s'." "${2-}" ;;
        font_missing_family) printf "Invalid manifest: font %s missing 'family'." "${2-}" ;;
        font_empty_family) printf "Invalid manifest: font %s family cannot be empty." "${2-}" ;;
        font_control_char) printf "Invalid manifest: font %s family contains control/tab/newline characters." "${2-}" ;;
        font_missing_description) printf "Invalid manifest: font %s missing 'description'." "${2-}" ;;
        font_unknown_key) printf 'Invalid manifest: unknown key in font %s.' "${2-}" ;;
        brew_not_array) printf "Invalid manifest: 'brew' must be an array." ;;
        brew_not_object) printf 'Invalid manifest: brew item %s must be an object.' "${2-}" ;;
        brew_missing_name) printf "Invalid manifest: brew item %s missing 'name'." "${2-}" ;;
        brew_invalid_name) printf "Invalid manifest: invalid brew name '%s'." "${2-}" ;;
        brew_duplicate_name) printf "Invalid manifest: duplicate brew name '%s'." "${2-}" ;;
        brew_invalid_cask) printf "Invalid manifest: brew item %s 'cask' must be a boolean." "${2-}" ;;
        brew_missing_description) printf "Invalid manifest: brew item %s missing 'description'." "${2-}" ;;
        brew_unknown_key) printf 'Invalid manifest: unknown key in brew item %s.' "${2-}" ;;
        group_invalid_brew) printf "Invalid manifest: group %s invalid 'brew' dependencies." "${2-}" ;;
        group_unknown_brew) printf "Invalid manifest: group %s references undeclared brew dependency '%s'." "${2-}" "${3-}" ;;
        group_preview_not_array) printf "Invalid manifest: group %s 'preview' must be an array." "${2-}" ;;
        group_preview_line_not_array) printf "Invalid manifest: group %s preview line %s must be an array." "${2-}" "${3-}" ;;
        group_preview_segment_not_object) printf "Invalid manifest: group %s preview line %s segment %s must be an object." "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_missing_text) printf "Invalid manifest: group %s preview line %s segment %s missing 'text'." "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_invalid_text) printf "Invalid manifest: group %s preview line %s segment %s 'text' must be a string." "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_invalid_color) printf "Invalid manifest: group %s preview line %s segment %s 'color' must be a string." "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_invalid_bg) printf "Invalid manifest: group %s preview line %s segment %s 'bg' must be a string." "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_unknown_key) printf "Invalid manifest: unknown key in group %s preview line %s segment %s." "${2-}" "${3-}" "${4-}" ;;
        font_invalid_preview) printf "Invalid manifest: font %s 'preview' must be a string." "${2-}" ;;
        features_not_array) printf "Invalid manifest: 'features' must be an array." ;;
        feature_not_object) printf 'Invalid manifest: feature item %s must be an object.' "${2-}" ;;
        feature_missing_name) printf "Invalid manifest: feature %s missing 'name'." "${2-}" ;;
        feature_invalid_name) printf "Invalid manifest: invalid feature name '%s'." "${2-}" ;;
        feature_duplicate_name) printf "Invalid manifest: duplicate feature name '%s'." "${2-}" ;;
        feature_invalid_macos) printf "Invalid manifest: feature %s 'macos' must be a boolean." "${2-}" ;;
        feature_missing_description) printf "Invalid manifest: feature %s missing 'description'." "${2-}" ;;
        feature_invalid_notes) printf "Invalid manifest: feature %s 'notes' must be an object." "${2-}" ;;
        notes_not_object) printf "Invalid manifest: feature %s 'notes' must be an object." "${2-}" ;;
        notes_missing_en) printf "Invalid manifest: feature %s notes missing 'en'." "${2-}" ;;
        notes_missing_zhtw) printf "Invalid manifest: feature %s notes missing 'zh-TW'." "${2-}" ;;
        notes_empty_en) printf "Invalid manifest: feature %s notes.en cannot be empty." "${2-}" ;;
        notes_empty_zhtw) printf "Invalid manifest: feature %s notes.zh-TW cannot be empty." "${2-}" ;;
        notes_control_char) printf "Invalid manifest: feature %s notes contains control/tab/newline characters." "${2-}" ;;
        notes_unknown_key) printf "Invalid manifest: unknown key in feature %s notes." "${2-}" ;;
        feature_brew_not_array) printf "Invalid manifest: feature %s 'brew' must be an array." "${2-}" ;;
        feature_brew_not_object) printf 'Invalid manifest: feature %s brew item %s must be an object.' "${2-}" "${3-}" ;;
        feature_brew_missing_name) printf "Invalid manifest: feature %s brew item %s missing 'name'." "${2-}" "${3-}" ;;
        feature_brew_invalid_name) printf "Invalid manifest: feature %s invalid brew name '%s'." "${2-}" "${3-}" ;;
        feature_brew_invalid_cask) printf "Invalid manifest: feature %s brew item %s 'cask' must be a boolean." "${2-}" "${3-}" ;;
        feature_brew_unknown_key) printf 'Invalid manifest: unknown key in feature %s brew item %s.' "${2-}" "${3-}" ;;
        feature_copy_not_array) printf "Invalid manifest: feature %s 'copy' must be an array." "${2-}" ;;
        feature_copy_not_object) printf 'Invalid manifest: feature %s copy item %s must be an object.' "${2-}" "${3-}" ;;
        feature_copy_missing_from) printf "Invalid manifest: feature %s copy item %s missing 'from'." "${2-}" "${3-}" ;;
        feature_copy_invalid_from) printf "Invalid manifest: feature %s copy item %s invalid or missing source '%s'." "${2-}" "${3-}" "${4-}" ;;
        feature_copy_missing_to) printf "Invalid manifest: feature %s copy item %s missing 'to'." "${2-}" "${3-}" ;;
        feature_copy_invalid_to) printf "Invalid manifest: feature %s copy item %s invalid destination '%s'." "${2-}" "${3-}" "${4-}" ;;
        feature_copy_unknown_key) printf 'Invalid manifest: unknown key in feature %s copy item %s.' "${2-}" "${3-}" ;;
        feature_hotkeys_not_array) printf "Invalid manifest: feature %s 'hotkeys' must be an array." "${2-}" ;;
        feature_hotkey_not_object) printf 'Invalid manifest: feature %s hotkey item %s must be an object.' "${2-}" "${3-}" ;;
        feature_hotkey_missing_id) printf "Invalid manifest: feature %s hotkey item %s missing 'id'." "${2-}" "${3-}" ;;
        feature_hotkey_invalid_id) printf "Invalid manifest: feature %s hotkey item %s 'id' must be an integer." "${2-}" "${3-}" ;;
        feature_hotkey_invalid_enabled) printf "Invalid manifest: feature %s hotkey item %s 'enabled' must be a boolean." "${2-}" "${3-}" ;;
        feature_hotkey_missing_params) printf "Invalid manifest: feature %s hotkey item %s missing required parameters (ascii, keycode, modifiers)." "${2-}" "${3-}" ;;
        feature_hotkey_invalid_param) printf "Invalid manifest: feature %s hotkey item %s parameter '%s' must be an integer." "${2-}" "${3-}" "${4-}" ;;
        feature_hotkey_unknown_key) printf 'Invalid manifest: unknown key in feature %s hotkey item %s.' "${2-}" "${3-}" ;;
        feature_unknown_key) printf 'Invalid manifest: unknown key in feature %s.' "${2-}" ;;
        *) printf 'Invalid manifest: %s' "${1-}" ;;
      esac
      ;;
    unknown_profile) printf "Unknown profile '%s'." "${1-}" ;;
    unknown_prompt) printf "Unknown prompt group '%s'." "${1-}" ;;
    no_default_profile) printf 'The manifest defines no default profile; --prompt cannot be used.' ;;
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
    invalid_repository) printf 'Invalid or unsupported repository source: %s' "${1-}" ;;
    custom_repo_requires_ref) printf 'specifying a custom --repo requires an explicit --ref or the OWNER/REPO/tree/REF form' ;;
    repo_tree_ref_conflict) printf '%s' '--repo with /tree/REF cannot be combined with --ref.' ;;
    invalid_ref) printf 'Invalid git reference: %s' "${1-}" ;;
    ambiguous_ref) printf "Reference '%s' is ambiguous on origin (matches both branch and tag)." "${1-}" ;;
    ref_not_found) printf "Reference '%s' was not found on remote origin." "${1-}" ;;
    invalid_git_config) printf 'Invalid or unallowed git configuration: %s' "${1-}" ;;
    invalid_git_admin) printf 'Invalid git administrative directory or state: %s' "${1-}" ;;
    dirty_checkout) printf 'Working tree is dirty or contains untracked/ignored files.' ;;
    invalid_submodule) printf 'Invalid or unallowed submodule definition: %s' "${1-}" ;;
    submodule_failed) printf "Failed to initialize submodule '%s'." "${1-}" ;;
    git_operation_failed) printf 'Git operation failed (%s).' "${1-}" ;;
    invalid_package_tree) printf 'Package tree contains unsafe, duplicate, or colliding paths.' ;;
    invalid_targets) printf 'Targets contain unsafe paths, overlaps, or cross-device conflicts.' ;;
    backup_root) printf 'Backup root: %s' "${1-}" ;;
    manual_restore) printf 'Restore manually with: mv %s %s' "${1-}" "${2-}" ;;
    invalid_font) printf "Invalid font '%s'. It is not declared in the manifest." "${1-}" ;;
    invalid_brew) printf "Invalid brew package '%s'. It is not declared in the manifest." "${1-}" ;;
    invalid_lang) printf "Invalid language '%s'." "${1-}" ;;
    invalid_feature) printf "Invalid feature '%s'. It is not declared in the manifest." "${1-}" ;;
    copy_failed) printf "Failed to copy feature file '%s' (%s)." "${1-}" "${2-}" ;;
    hotkey_failed) printf "Failed to configure symbolic hotkey '%s' (%s)." "${1-}" "${2-}" ;;
    activate_settings_failed) printf 'Failed to activate settings. Please log out and log back in for hotkey changes to take effect.' ;;
    warning_prefix) printf 'Warning' ;;
    prompt_conflict) printf 'Multiple prompt groups selected. At most one prompt group may be selected.' ;;
    brew_bundle_failed) printf 'brew bundle failed (%s).' "${1-}" ;;
    unknown_mise_tools) printf 'Unknown mise tools: %s — see https://mise.jdx.dev/registry.html' "${1-}" ;;
    mise_install_failed) printf 'mise install failed (%s).' "${1-}" ;;
    bootstrap_failed) printf 'Bootstrap failed: %s' "${1-}" ;;
    bootstrap_brew_installing) printf 'Installing Homebrew...' ;;
    bootstrap_tools_installing) printf 'Installing missing tools: %s' "${1-}" ;;
    bootstrap_dry_run) printf 'Would bootstrap: %s' "${1-}" ;;
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
    selection_conflict) printf '選取選項（--prompt, --profile, --groups, --interactive, --all）不可同時使用。' ;;
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
        group_invalid_kind) printf '無效的 manifest：群組 %s 的「kind」無效。' "${2-}" ;;
        fonts_not_array) printf '無效的 manifest：「fonts」必須是陣列。' ;;
        font_not_object) printf '無效的 manifest：字型項目 %s 必須是物件。' "${2-}" ;;
        font_missing_cask) printf '無效的 manifest：字型 %s 缺少「cask」。' "${2-}" ;;
        font_invalid_cask) printf '無效的 manifest：無效的字型 cask「%s」。' "${2-}" ;;
        font_duplicate_cask) printf '無效的 manifest：重複的字型 cask「%s」。' "${2-}" ;;
        font_missing_family) printf '無效的 manifest：字型 %s 缺少「family」。' "${2-}" ;;
        font_empty_family) printf '無效的 manifest：字型 %s 的 family 不能為空。' "${2-}" ;;
        font_control_char) printf '無效的 manifest：字型 %s 的 family 包含控制字元、Tab 或換行。' "${2-}" ;;
        font_missing_description) printf '無效的 manifest：字型 %s 缺少「description」。' "${2-}" ;;
        font_unknown_key) printf '無效的 manifest：字型 %s 包含未知鍵值。' "${2-}" ;;
        brew_not_array) printf '無效的 manifest：「brew」必須是陣列。' ;;
        brew_not_object) printf '無效的 manifest：brew 項目 %s 必須是物件。' "${2-}" ;;
        brew_missing_name) printf '無效的 manifest：brew 項目 %s 缺少「name」。' "${2-}" ;;
        brew_invalid_name) printf '無效的 manifest：無效的 brew 名稱「%s」。' "${2-}" ;;
        brew_duplicate_name) printf '無效的 manifest：重複的 brew 名稱「%s」。' "${2-}" ;;
        brew_invalid_cask) printf '無效的 manifest：brew 項目 %s 的「cask」必須是布林值。' "${2-}" ;;
        brew_missing_description) printf '無效的 manifest：brew 項目 %s 缺少「description」。' "${2-}" ;;
        brew_unknown_key) printf '無效的 manifest：brew 項目 %s 包含未知鍵值。' "${2-}" ;;
        group_invalid_brew) printf '無效的 manifest：群組 %s 的「brew」相依項目無效。' "${2-}" ;;
        group_unknown_brew) printf '無效的 manifest：群組 %s 引用了未宣告的 brew 相依項目「%s」。' "${2-}" "${3-}" ;;
        group_preview_not_array) printf '無效的 manifest：群組 %s 的「preview」必須是陣列。' "${2-}" ;;
        group_preview_line_not_array) printf '無效的 manifest：群組 %s preview 第 %s 行必須是陣列。' "${2-}" "${3-}" ;;
        group_preview_segment_not_object) printf '無效的 manifest：群組 %s preview 第 %s 行第 %s 個片段必須是物件。' "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_missing_text) printf '無效的 manifest：群組 %s preview 第 %s 行第 %s 個片段缺少「text」。' "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_invalid_text) printf '無效的 manifest：群組 %s preview 第 %s 行第 %s 個片段的「text」必須是字串。' "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_invalid_color) printf '無效的 manifest：群組 %s preview 第 %s 行第 %s 個片段的「color」必須是字串。' "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_invalid_bg) printf '無效的 manifest：群組 %s preview 第 %s 行第 %s 個片段的「bg」必須是字串。' "${2-}" "${3-}" "${4-}" ;;
        group_preview_segment_unknown_key) printf '無效的 manifest：群組 %s preview 第 %s 行第 %s 個片段包含未知鍵值。' "${2-}" "${3-}" "${4-}" ;;
        font_invalid_preview) printf '無效的 manifest：字型 %s 的「preview」必須是字串。' "${2-}" ;;
        features_not_array) printf '無效的 manifest：「features」必須是陣列。' ;;
        feature_not_object) printf '無效的 manifest：feature 項目 %s 必須是物件。' "${2-}" ;;
        feature_missing_name) printf '無效的 manifest：feature %s 缺少「name」。' "${2-}" ;;
        feature_invalid_name) printf '無效的 manifest：無效的 feature 名稱「%s」。' "${2-}" ;;
        feature_duplicate_name) printf '無效的 manifest：重複的 feature 名稱「%s」。' "${2-}" ;;
        feature_invalid_macos) printf '無效的 manifest：feature %s 的「macos」必須是布林值。' "${2-}" ;;
        feature_missing_description) printf '無效的 manifest：feature %s 缺少「description」。' "${2-}" ;;
        feature_invalid_notes) printf '無效的 manifest：feature %s 的「notes」必須是物件。' "${2-}" ;;
        notes_not_object) printf '無效的 manifest：feature %s 的「notes」必須是物件。' "${2-}" ;;
        notes_missing_en) printf '無效的 manifest：feature %s 的 notes 缺少「en」。' "${2-}" ;;
        notes_missing_zhtw) printf '無效的 manifest：feature %s 的 notes 缺少「zh-TW」。' "${2-}" ;;
        notes_empty_en) printf '無效的 manifest：feature %s 的 notes.en 不能為空。' "${2-}" ;;
        notes_empty_zhtw) printf '無效的 manifest：feature %s 的 notes.zh-TW 不能為空。' "${2-}" ;;
        notes_control_char) printf '無效的 manifest：feature %s 的 notes 包含控制字元、Tab 或換行。' "${2-}" ;;
        notes_unknown_key) printf '無效的 manifest：feature %s 的 notes 包含未知鍵值。' "${2-}" ;;
        feature_brew_not_array) printf '無效的 manifest：feature %s 的「brew」必須是陣列。' "${2-}" ;;
        feature_brew_not_object) printf '無效的 manifest：feature %s 的 brew 項目 %s 必須是物件。' "${2-}" "${3-}" ;;
        feature_brew_missing_name) printf '無效的 manifest：feature %s 的 brew 項目 %s 缺少「name」。' "${2-}" "${3-}" ;;
        feature_brew_invalid_name) printf '無效的 manifest：feature %s 包含無效的 brew 名稱「%s」。' "${2-}" "${3-}" ;;
        feature_brew_invalid_cask) printf '無效的 manifest：feature %s 的 brew 項目 %s 的「cask」必須是布林值。' "${2-}" "${3-}" ;;
        feature_brew_unknown_key) printf '無效的 manifest：feature %s 的 brew 項目 %s 包含未知鍵值。' "${2-}" "${3-}" ;;
        feature_copy_not_array) printf '無效的 manifest：feature %s 的「copy」必須是陣列。' "${2-}" ;;
        feature_copy_not_object) printf '無效的 manifest：feature %s 的 copy 項目 %s 必須是物件。' "${2-}" "${3-}" ;;
        feature_copy_missing_from) printf '無效的 manifest：feature %s 的 copy 項目 %s 缺少「from」。' "${2-}" "${3-}" ;;
        feature_copy_invalid_from) printf '無效的 manifest：feature %s 的 copy 項目 %s 來源無效或不存在「%s」。' "${2-}" "${3-}" "${4-}" ;;
        feature_copy_missing_to) printf '無效的 manifest：feature %s 的 copy 項目 %s 缺少「to」。' "${2-}" "${3-}" ;;
        feature_copy_invalid_to) printf '無效的 manifest：feature %s 的 copy 項目 %s 目的端路徑無效「%s」。' "${2-}" "${3-}" "${4-}" ;;
        feature_copy_unknown_key) printf '無效的 manifest：feature %s 的 copy 項目 %s 包含未知鍵值。' "${2-}" "${3-}" ;;
        feature_hotkeys_not_array) printf '無效的 manifest：feature %s 的「hotkeys」必須是陣列。' "${2-}" ;;
        feature_hotkey_not_object) printf '無效的 manifest：feature %s 的 hotkey 項目 %s 必須是物件。' "${2-}" "${3-}" ;;
        feature_hotkey_missing_id) printf '無效的 manifest：feature %s 的 hotkey 項目 %s 缺少「id」。' "${2-}" "${3-}" ;;
        feature_hotkey_invalid_id) printf '無效的 manifest：feature %s 的 hotkey 項目 %s 的「id」必須是整數。' "${2-}" "${3-}" ;;
        feature_hotkey_invalid_enabled) printf '無效的 manifest：feature %s 的 hotkey 項目 %s 的「enabled」必須是布林值。' "${2-}" "${3-}" ;;
        feature_hotkey_missing_params) printf '無效的 manifest：feature %s 的 hotkey 項目 %s 缺少必要參數（ascii, keycode, modifiers）。' "${2-}" "${3-}" ;;
        feature_hotkey_invalid_param) printf '無效的 manifest：feature %s 的 hotkey 項目 %s 的參數「%s」必須是整數。' "${2-}" "${3-}" "${4-}" ;;
        feature_hotkey_unknown_key) printf '無效的 manifest：feature %s 的 hotkey 項目 %s 包含未知鍵值。' "${2-}" "${3-}" ;;
        feature_unknown_key) printf '無效的 manifest：feature %s 包含未知鍵值。' "${2-}" ;;
        *) printf '無效的 manifest：%s' "${1-}" ;;
      esac
      ;;
    unknown_profile) printf '未知的設定檔「%s」。' "${1-}" ;;
    unknown_prompt) printf '未知的提示字元群組「%s」。' "${1-}" ;;
    no_default_profile) printf 'manifest 未定義 default 設定檔，無法使用 --prompt。' ;;
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
    invalid_repository) printf '無效或不支援的儲存庫來源：%s' "${1-}" ;;
    custom_repo_requires_ref) printf '指定自訂 --repo 時必須一併指定 --ref，或使用 OWNER/REPO/tree/REF 形式。' ;;
    repo_tree_ref_conflict) printf '%s' '--repo 的 /tree/REF 與 --ref 不可同時使用。' ;;
    invalid_ref) printf '無效的 Git 參照：%s' "${1-}" ;;
    ambiguous_ref) printf '來源上的參照「%s」具歧義（同時符合分支與標籤）。' "${1-}" ;;
    ref_not_found) printf '在遠端來源找不到參照「%s」。' "${1-}" ;;
    invalid_git_config) printf '無效或不允許的 Git 設定：%s' "${1-}" ;;
    invalid_git_admin) printf '無效的 Git 管理目錄或狀態：%s' "${1-}" ;;
    dirty_checkout) printf '工作目錄有未提交變更或包含未追蹤/已忽略的檔案。' ;;
    invalid_submodule) printf '無效或不允許的子模組定義：%s' "${1-}" ;;
    submodule_failed) printf '初始化子模組「%s」失敗。' "${1-}" ;;
    git_operation_failed) printf 'Git 操作失敗（%s）。' "${1-}" ;;
    invalid_package_tree) printf '套件樹包含不安全、重複或衝突的路徑。' ;;
    invalid_targets) printf '目標包含不安全路徑、重疊或跨裝置衝突。' ;;
    backup_root) printf '備份根目錄：%s' "${1-}" ;;
    manual_restore) printf '手動還原指令：mv %s %s' "${1-}" "${2-}" ;;
    invalid_font) printf '無效的字型「%s」。未在 manifest 中宣告。' "${1-}" ;;
    invalid_brew) printf '無效的 Homebrew 套件「%s」。未在 manifest 中宣告。' "${1-}" ;;
    invalid_lang) printf '無效的語言「%s」。' "${1-}" ;;
    invalid_feature) printf '無效的 feature「%s」。未在 manifest 中宣告。' "${1-}" ;;
    copy_failed) printf '複製 feature 檔案失敗「%s」（%s）。' "${1-}" "${2-}" ;;
    hotkey_failed) printf '設定快捷鍵失敗「%s」（%s）。' "${1-}" "${2-}" ;;
    activate_settings_failed) printf '無法套用設定。請登出並重新登入以讓快捷鍵變更生效。' ;;
    warning_prefix) printf '警告' ;;
    prompt_conflict) printf '選取了多個提示字元群組。最多只能選取一個提示字元群組。' ;;
    brew_bundle_failed) printf 'brew bundle 執行失敗（%s）。' "${1-}" ;;
    unknown_mise_tools) printf 'mise 不認識這些工具：%s — 參考 https://mise.jdx.dev/registry.html' "${1-}" ;;
    mise_install_failed) printf 'mise install 執行失敗（%s）。' "${1-}" ;;
    bootstrap_failed) printf '引導安裝失敗：%s' "${1-}" ;;
    bootstrap_brew_installing) printf '正在安裝 Homebrew...' ;;
    bootstrap_tools_installing) printf '正在安裝缺少工具：%s' "${1-}" ;;
    bootstrap_dry_run) printf '將會引導安裝：%s' "${1-}" ;;
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

trim_whitespace() {
  var=$1
  while case "$var" in [[:space:]]*) var="${var#[[:space:]]}"; true ;; *) false ;; esac; do :; done
  while case "$var" in *[[:space:]]) var="${var%[[:space:]]}"; true ;; *) false ;; esac; do :; done
  printf '%s' "$var"
}

validate_langs() {
  test -n "$SELECTED_LANGS" || return 0
  cur="$SELECTED_LANGS"
  deduped_langs=''
  seen_langs=''
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
    test -n "$trimmed" || die invalid_lang '<empty>'
    is_valid_lang "$trimmed" || die invalid_lang "$trimmed"
    case " $seen_langs " in
      *" $trimmed "*) ;;
      *)
        if test -z "$seen_langs"; then
          seen_langs="$trimmed"
          deduped_langs="$trimmed"
        else
          seen_langs="$seen_langs $trimmed"
          deduped_langs="$deduped_langs,$trimmed"
        fi
        ;;
    esac
    test "$has_more" -eq 0 && break
  done
  SELECTED_LANGS="$deduped_langs"
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
  repo_explicit=0
  ref_explicit=0
  tree_ref=''
  while test $# -gt 0; do
    arg=$1
    shift
    case "$arg" in
      -h|--help)
        usage
        exit 0
        ;;
      --prompt|--prompt=*)
        if test "$arg" = '--prompt'; then
          test $# -gt 0 || die missing_option_value '--prompt'
          val=$1
          shift
        else
          val=${arg#--prompt=}
        fi
        test -n "$val" || die missing_option_value '--prompt'
        SELECTION_MODE='prompt'
        SELECTION_VALUE="$val"
        selection_count=$((selection_count + 1))
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
        case "$val" in
          */tree/*)
            tree_ref=${val#*/tree/}
            test -n "$tree_ref" || die invalid_repository "$val"
            val=${val%%/tree/*}
            ;;
        esac
        REPOSITORY="$val"
        repo_explicit=1
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
        ref_explicit=1
        ;;
      --dir|--dir=*)
        if test "$arg" = '--dir'; then
          test $# -gt 0 || die missing_option_value '--dir'
          val=$1
          shift
        else
          val=${arg#--dir=}
        fi
        test -n "$val" || die missing_option_value '--dir'
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
      --font|--font=*)
        if test "$arg" = '--font'; then
          test $# -gt 0 || die missing_option_value '--font'
          val=$1
          shift
        else
          val=${arg#--font=}
        fi
        test -n "$val" || die missing_option_value '--font'
        SELECTED_FONT="$val"
        ;;
      --brew|--brew=*)
        if test "$arg" = '--brew'; then
          test $# -gt 0 || die missing_option_value '--brew'
          val=$1
          shift
        else
          val=${arg#--brew=}
        fi
        test -n "$val" || die missing_option_value '--brew'
        SELECTED_BREW="$val"
        ;;
      --langs|--langs=*)
        if test "$arg" = '--langs'; then
          test $# -gt 0 || die missing_option_value '--langs'
          val=$1
          shift
        else
          val=${arg#--langs=}
        fi
        test -n "$val" || die missing_option_value '--langs'
        SELECTED_LANGS="$val"
        ;;
      --features|--features=*)
        if test "$arg" = '--features'; then
          test $# -gt 0 || die missing_option_value '--features'
          val=$1
          shift
        else
          val=${arg#--features=}
        fi
        test -n "$val" || die missing_option_value '--features'
        SELECTED_FEATURES="$val"
        ;;
      --stow-only)
        STOW_ONLY=1
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

  if test -n "$tree_ref"; then
    test "$ref_explicit" -eq 0 || die repo_tree_ref_conflict
    REQUESTED_REF="$tree_ref"
    ref_explicit=1
  fi

  if test "$repo_explicit" -eq 1 && test "$ref_explicit" -eq 0; then
    if test "$REPOSITORY" != "$DEFAULT_REPOSITORY"; then
      die custom_repo_requires_ref
    fi
  fi
  validate_langs
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

  owner_uid=$(/usr/bin/stat -f '%u' "$raw_home" 2>/dev/null) || die invalid_home "$raw_home"
  curr_uid=$(/usr/bin/id -u 2>/dev/null) || die invalid_home "$raw_home"
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
        *) die invalid_targets "XDG_STATE_HOME must be absolute: $xdg_state" ;;
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
  curr_uid=$(/usr/bin/id -u 2>/dev/null) || die lock_failed "$LOCK_DIR"
  LOCK_DIR="/private/tmp/kaisian-$curr_uid.lock"

  test -d '/private/tmp' || die lock_failed "$LOCK_DIR"
  tmp_owner=$(/usr/bin/stat -f '%u' '/private/tmp' 2>/dev/null) || die lock_failed "$LOCK_DIR"
  test "$tmp_owner" = '0' || die lock_failed "$LOCK_DIR"
  test -k '/private/tmp' || die lock_failed "$LOCK_DIR"
  check_path_overlap_with_lock "$CHECKOUT_DIR"
  check_path_overlap_with_lock "$STATE_ROOT"

  if ! ( umask 077 && /bin/mkdir "$LOCK_DIR" 2>/dev/null ); then
    die lock_failed "$LOCK_DIR"
  fi

  RECORDED_LOCK_DEV_INO=$(/usr/bin/stat -f '%d %i' "$LOCK_DIR" 2>/dev/null)
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
  RECORDED_SANDBOX_DEV_INO=$(/usr/bin/stat -f '%d %i' "$SANDBOX" 2>/dev/null)
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

  curr_lock_dev_ino=$(/usr/bin/stat -f '%d %i' "$LOCK_DIR" 2>/dev/null || true)
  if test "$curr_lock_dev_ino" != "$RECORDED_LOCK_DEV_INO"; then
    return 0
  fi

  if test -n "$SANDBOX" && test -n "$RECORDED_SANDBOX_DEV_INO"; then
    curr_sb_dev_ino=$(/usr/bin/stat -f '%d %i' "$SANDBOX" 2>/dev/null || true)
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
      GIT_ALLOW_PROTOCOL=https \
      ${GIT_INDEX_FILE:+GIT_INDEX_FILE="$GIT_INDEX_FILE"} \
      KAISIAN_TESTING=1 \
      KAISIAN_FAKE_GIT_MAP="${KAISIAN_FAKE_GIT_MAP-}" \
      KAISIAN_GIT_TRACE_LOG="${KAISIAN_GIT_TRACE_LOG-}" \
      KAISIAN_FAKE_GIT_FAIL_ON_CONFIG_ORIGIN="${KAISIAN_FAKE_GIT_FAIL_ON_CONFIG_ORIGIN-}" \
      KAISIAN_FAKE_GIT_FAIL_MARKER="${KAISIAN_FAKE_GIT_FAIL_MARKER-}" \
      "$git_bin" "$@"
  else
    git_bin="${GIT_EXEC:-/usr/bin/git}"
    runner_path='/usr/bin:/bin:/usr/sbin:/sbin'
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
      GIT_ALLOW_PROTOCOL=https \
      ${GIT_INDEX_FILE:+GIT_INDEX_FILE="$GIT_INDEX_FILE"} \
      "$git_bin" "$@"
  fi
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

get_tool_exec() {
  tool_name=$1
  case "$tool_name" in
    git)
      if test -n "${KAISIAN_GIT_EXEC-}"; then
        printf '%s\n' "$KAISIAN_GIT_EXEC"
        return 0
      elif test "${KAISIAN_GIT_EXEC+x}" = 'x'; then
        return 1
      fi
      ;;
    stow)
      if test -n "${KAISIAN_STOW_EXEC-}"; then
        printf '%s\n' "$KAISIAN_STOW_EXEC"
        return 0
      elif test "${KAISIAN_STOW_EXEC+x}" = 'x'; then
        return 1
      fi
      ;;
    fzf)
      if test -n "${KAISIAN_FZF_EXEC-}"; then
        printf '%s\n' "$KAISIAN_FZF_EXEC"
        return 0
      elif test "${KAISIAN_FZF_EXEC+x}" = 'x'; then
        return 1
      fi
      ;;
    plutil)
      if test -n "${KAISIAN_PLUTIL_EXEC-}"; then
        printf '%s\n' "$KAISIAN_PLUTIL_EXEC"
        return 0
      elif test "${KAISIAN_PLUTIL_EXEC+x}" = 'x'; then
        return 1
      fi
      ;;
    brew)
      if test -n "${KAISIAN_BREW_EXEC-}"; then
        printf '%s\n' "$KAISIAN_BREW_EXEC"
        return 0
      elif test "${KAISIAN_BREW_EXEC+x}" = 'x'; then
        return 1
      fi
      ;;
    mise)
      if test -n "${KAISIAN_MISE_EXEC-}"; then
        printf '%s\n' "$KAISIAN_MISE_EXEC"
        return 0
      elif test "${KAISIAN_MISE_EXEC+x}" = 'x'; then
        return 1
      fi
      ;;
  esac
  raw=$(discover_executable "$tool_name") && {
    printf '%s\n' "$raw"
    return 0
  }
  case "$tool_name" in
    brew)
      if test -f '/opt/homebrew/bin/brew' && test -x '/opt/homebrew/bin/brew'; then
        printf '/opt/homebrew/bin/brew\n'
        return 0
      elif test -f '/usr/local/bin/brew' && test -x '/usr/local/bin/brew'; then
        printf '/usr/local/bin/brew\n'
        return 0
      fi
      ;;
  esac
  return 1
}

bootstrap_prerequisites() {
  # 1. Discover or bootstrap Homebrew
  BREW_EXEC=$(get_tool_exec brew) || true
  if test -z "$BREW_EXEC"; then
    if test "$DRY_RUN" -eq 1; then
      msg=$(message bootstrap_dry_run "Homebrew" 2>/dev/null) || msg="Would bootstrap: Homebrew"
      printf '%s\n' "$msg"
    else
      if test -n "${KAISIAN_BREW_INSTALLER-}"; then
        eval "$KAISIAN_BREW_INSTALLER" || die bootstrap_failed 'Homebrew installation failed'
      else
        /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die bootstrap_failed 'Homebrew installation failed'
      fi
      if test -d '/opt/homebrew/bin'; then
        PATH="/opt/homebrew/bin:$PATH"
        export PATH
      fi
      if test -d '/usr/local/bin'; then
        PATH="/usr/local/bin:$PATH"
        export PATH
      fi
      BREW_EXEC=$(get_tool_exec brew) || die bootstrap_failed 'Homebrew executable not found after installation'
    fi
  fi

  # 2. Discover git and stow
  GIT_EXEC=$(get_tool_exec git) || true
  STOW_EXEC=$(get_tool_exec stow) || true

  missing_pkgs=''
  if test -z "$GIT_EXEC"; then
    missing_pkgs='git'
  fi
  if test -z "$STOW_EXEC"; then
    if test -z "$missing_pkgs"; then
      missing_pkgs='stow'
    else
      missing_pkgs="$missing_pkgs stow"
    fi
  fi

  if test -n "$missing_pkgs"; then
    if test "$DRY_RUN" -eq 1; then
      msg=$(message bootstrap_dry_run "brew install $missing_pkgs" 2>/dev/null) || msg="Would bootstrap: brew install $missing_pkgs"
      printf '%s\n' "$msg"
    else
      test -n "$BREW_EXEC" || die bootstrap_failed "Homebrew is required to install: $missing_pkgs"
      "$BREW_EXEC" install $missing_pkgs || die bootstrap_failed "brew install $missing_pkgs failed"
      if test "${KAISIAN_GIT_EXEC+x}" = 'x' && test -z "$KAISIAN_GIT_EXEC"; then
        KAISIAN_GIT_EXEC="$BREW_EXEC"
      fi
      if test "${KAISIAN_STOW_EXEC+x}" = 'x' && test -z "$KAISIAN_STOW_EXEC"; then
        KAISIAN_STOW_EXEC="$BREW_EXEC"
      fi
      GIT_EXEC=$(get_tool_exec git) || die bootstrap_failed 'git executable not found after installation'
      STOW_EXEC=$(get_tool_exec stow) || die bootstrap_failed 'stow executable not found after installation'
    fi
  fi
}

require_prerequisites() {
  os_name=$(/usr/bin/uname -s 2>/dev/null) || die unsupported_os
  test "$os_name" = 'Darwin' || die unsupported_os

  PLUTIL_EXEC=$(get_tool_exec plutil) || die missing_tools 'plutil'

  bootstrap_prerequisites

  if test "$SELECTION_MODE" = 'interactive'; then
    FZF_EXEC=$(get_tool_exec fzf) || die missing_tools 'fzf'
  else
    FZF_EXEC=$(get_tool_exec fzf 2>/dev/null || true)
  fi

  if test "$DRY_RUN" -eq 1 && test -z "$STOW_EXEC"; then
    return 0
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

is_pure_ascii() {
  LC_ALL=C
  test -n "${1-}" || return 1
  case "$1" in
    *[!a-zA-Z0-9._:/-]*) return 1 ;;
    *) return 0 ;;
  esac
}

canonicalize_repository() {
  local raw_repo=${1-}
  local rest host_part path_part canon_host old_ifs seg_count seg canon_path owner_part repo_part
  test -n "$raw_repo" || die invalid_repository '<empty>'

  case "$raw_repo" in
    *[!a-zA-Z0-9_.-/:]*)
      die invalid_repository "$raw_repo"
      ;;
  esac

  case "$raw_repo" in
    -*|*@*|*\?*|*#*|*%*|*\\*)
      die invalid_repository "$raw_repo"
      ;;
  esac

  case "$raw_repo" in
    *://*)
      case "$raw_repo" in
        https://*) ;;
        *) die invalid_repository "$raw_repo" ;;
      esac
      ;;
    *:*)
      die invalid_repository "$raw_repo"
      ;;
  esac

  if case "$raw_repo" in https://*) true ;; *) false ;; esac; then
    rest=${raw_repo#https://}
    case "$rest" in
      */*)
        host_part=${rest%%/*}
        path_part=/${rest#*/}
        ;;
      *)
        die invalid_repository "$raw_repo"
        ;;
    esac

    case "$host_part" in
      *:*|*@*|'') die invalid_repository "$raw_repo" ;;
    esac
    case "$host_part" in
      *[!a-zA-Z0-9.-]*) die invalid_repository "$raw_repo" ;;
      .*|-*|*.|*-|*..*) die invalid_repository "$raw_repo" ;;
    esac

    canon_host=$(printf '%s' "$host_part" | /usr/bin/tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')

    test -n "$path_part" || die invalid_repository "$raw_repo"
    case "$path_part" in
      /*) ;;
      *) die invalid_repository "$raw_repo" ;;
    esac

    case "$path_part" in
      *//*) die invalid_repository "$raw_repo" ;;
    esac

    case "$path_part" in
      */) path_part=${path_part%/} ;;
    esac
    test -n "$path_part" || die invalid_repository "$raw_repo"

    case "$path_part" in
      *.git) path_part=${path_part%.git} ;;
    esac
    test -n "$path_part" || die invalid_repository "$raw_repo"

    old_ifs=$IFS
    IFS='/'
    set -- $path_part
    IFS=$old_ifs

    seg_count=0
    for seg in "$@"; do
      test -n "$seg" || continue
      seg_count=$((seg_count + 1))
      case "$seg" in
        .|..) die invalid_repository "$raw_repo" ;;
        -*|*@*|*:*) die invalid_repository "$raw_repo" ;;
        *[!a-zA-Z0-9_.-]*) die invalid_repository "$raw_repo" ;;
      esac
    done
    test "$seg_count" -ge 1 || die invalid_repository "$raw_repo"

    canon_path=''
    for seg in "$@"; do
      test -n "$seg" || continue
      canon_path="$canon_path/$seg"
    done

    printf 'https://%s%s\n' "$canon_host" "$canon_path"
    return 0
  else
    case "$raw_repo" in
      *//*) die invalid_repository "$raw_repo" ;;
    esac

    case "$raw_repo" in
      */*)
        owner_part=${raw_repo%%/*}
        repo_part=${raw_repo#*/}
        ;;
      *)
        die invalid_repository "$raw_repo"
        ;;
    esac

    case "$repo_part" in
      */*) die invalid_repository "$raw_repo" ;;
    esac

    case "$repo_part" in
      *.git) repo_part=${repo_part%.git} ;;
    esac

    test -n "$owner_part" || die invalid_repository "$raw_repo"
    test -n "$repo_part" || die invalid_repository "$raw_repo"

    case "$owner_part" in
      .|..|-*|*[!a-zA-Z0-9_.-]*) die invalid_repository "$raw_repo" ;;
    esac
    case "$repo_part" in
      .|..|-*|*[!a-zA-Z0-9_.-]*) die invalid_repository "$raw_repo" ;;
    esac

    printf 'https://github.com/%s/%s\n' "$owner_part" "$repo_part"
    return 0
  fi
}

resolve_remote_ref() {
  local ls_output sha refname peeled_target peeled_sha tag_sha
  local branch_match tag_match tag_peeled_match target_branch target_tag target_tag_peeled is_40_hex
  test -n "$REPOSITORY" || die invalid_repository '<empty>'
  CANONICAL_REPO=$(canonicalize_repository "$REPOSITORY") || exit 1
  test -n "$REQUESTED_REF" || die invalid_ref '<empty>'

  case "$REQUESTED_REF" in
    *[!a-zA-Z0-9_.-/^{}]*)
      die invalid_ref "$REQUESTED_REF"
      ;;
    -*|*:*|*..*|*//*|*.lock|*/)
      die invalid_ref "$REQUESTED_REF"
      ;;
  esac

  ls_output=$(run_git ls-remote "$CANONICAL_REPO" 2>/dev/null) || die ref_not_found "$REQUESTED_REF"

  RESOLVED_FETCH_REF=''
  EXPECTED_COMMIT_SHA=''

  if test "$REQUESTED_REF" = 'HEAD'; then
    while IFS="$(printf '\t')" read -r sha refname || test -n "$sha"; do
      if test "$refname" = 'HEAD'; then
        RESOLVED_FETCH_REF='HEAD'
        EXPECTED_COMMIT_SHA="$sha"
        break
      fi
    done << EOF
$ls_output
EOF
    test -n "$RESOLVED_FETCH_REF" || die ref_not_found 'HEAD'
    return 0
  fi

  case "$REQUESTED_REF" in
    refs/heads/*)
      while IFS="$(printf '\t')" read -r sha refname || test -n "$sha"; do
        if test "$refname" = "$REQUESTED_REF"; then
          RESOLVED_FETCH_REF="$REQUESTED_REF"
          EXPECTED_COMMIT_SHA="$sha"
          break
        fi
      done << EOF
$ls_output
EOF
      test -n "$RESOLVED_FETCH_REF" || die ref_not_found "$REQUESTED_REF"
      return 0
      ;;
    refs/tags/*)
      peeled_target="${REQUESTED_REF}^{}"
      peeled_sha=''
      tag_sha=''
      while IFS="$(printf '\t')" read -r sha refname || test -n "$sha"; do
        if test "$refname" = "$peeled_target"; then
          peeled_sha="$sha"
        elif test "$refname" = "$REQUESTED_REF"; then
          tag_sha="$sha"
        fi
      done << EOF
$ls_output
EOF
      if test -n "$peeled_sha"; then
        RESOLVED_FETCH_REF="$REQUESTED_REF"
        EXPECTED_COMMIT_SHA="$peeled_sha"
      elif test -n "$tag_sha"; then
        RESOLVED_FETCH_REF="$REQUESTED_REF"
        EXPECTED_COMMIT_SHA="$tag_sha"
      else
        die ref_not_found "$REQUESTED_REF"
      fi
      return 0
      ;;
  esac

  branch_match=''
  tag_match=''
  tag_peeled_match=''
  target_branch="refs/heads/$REQUESTED_REF"
  target_tag="refs/tags/$REQUESTED_REF"
  target_tag_peeled="refs/tags/${REQUESTED_REF}^{}"

  is_40_hex=0
  case "$REQUESTED_REF" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      is_40_hex=1
      ;;
  esac

  while IFS="$(printf '\t')" read -r sha refname || test -n "$sha"; do
    if test "$refname" = "$target_branch"; then
      branch_match="$sha"
    elif test "$refname" = "$target_tag_peeled"; then
      tag_peeled_match="$sha"
    elif test "$refname" = "$target_tag"; then
      tag_match="$sha"
    fi
  done << EOF
$ls_output
EOF

  if test -n "$branch_match" && { test -n "$tag_match" || test -n "$tag_peeled_match"; }; then
    die ambiguous_ref "$REQUESTED_REF"
  fi

  if test -n "$branch_match"; then
    RESOLVED_FETCH_REF="$target_branch"
    EXPECTED_COMMIT_SHA="$branch_match"
    return 0
  fi

  if test -n "$tag_peeled_match"; then
    RESOLVED_FETCH_REF="$target_tag"
    EXPECTED_COMMIT_SHA="$tag_peeled_match"
    return 0
  fi

  if test -n "$tag_match"; then
    RESOLVED_FETCH_REF="$target_tag"
    EXPECTED_COMMIT_SHA="$tag_match"
    return 0
  fi

  if test "$is_40_hex" -eq 1; then
    advertised_sha=''
    while IFS="$(printf '\t')" read -r sha refname || test -n "$sha"; do
      if test "$sha" = "$REQUESTED_REF"; then
        advertised_sha="$sha"
        break
      fi
    done << EOF
$ls_output
EOF
    if test -n "$advertised_sha"; then
      RESOLVED_FETCH_REF="$REQUESTED_REF"
      EXPECTED_COMMIT_SHA="$REQUESTED_REF"
      return 0
    fi
  fi

  die ref_not_found "$REQUESTED_REF"
}

validate_git_admin() {
  local chk_dir=${1:-$CHECKOUT_DIR}
  local is_bare git_dir canon_chk canon_git_dir common_dir canon_common op replace_loose hook_f symlink_f
  test -n "$chk_dir" || die invalid_git_admin 'checkout directory path required'
  test -d "$chk_dir" || die invalid_git_admin "not a directory: $chk_dir"
  test ! -L "$chk_dir" || die invalid_git_admin "checkout directory is a symlink: $chk_dir"

  test -d "$chk_dir/.git" || die invalid_git_admin "missing .git directory: $chk_dir"
  test ! -L "$chk_dir/.git" || die invalid_git_admin ".git is a symlink: $chk_dir"
  test ! -f "$chk_dir/.git" || die invalid_git_admin ".git is a gitfile/linked worktree: $chk_dir"

  is_bare=$(run_git -C "$chk_dir" rev-parse --is-bare-repository 2>/dev/null) || die invalid_git_admin "$chk_dir"
  test "$is_bare" = 'false' || die invalid_git_admin "bare repository not supported: $chk_dir"

  git_dir=$(run_git -C "$chk_dir" rev-parse --absolute-git-dir 2>/dev/null) || die invalid_git_admin "$chk_dir"
  canon_chk=$(canonicalize_path "$chk_dir") || die invalid_git_admin "$chk_dir"
  canon_git_dir=$(canonicalize_path "$git_dir") || die invalid_git_admin "$chk_dir"
  test "$canon_git_dir" = "$canon_chk/.git" || die invalid_git_admin "separate gitdir: $git_dir != $canon_chk/.git"

  common_dir=$(run_git -C "$chk_dir" rev-parse --git-common-dir 2>/dev/null) || die invalid_git_admin "$chk_dir"
  case "$common_dir" in
    /*) ;;
    *) common_dir="$chk_dir/$common_dir" ;;
  esac
  canon_common=$(canonicalize_path "$common_dir") || die invalid_git_admin "$chk_dir"
  test "$canon_common" = "$canon_chk/.git" || die invalid_git_admin "common dir mismatch: $canon_common"

  symlink_f=$(/usr/bin/find "$chk_dir/.git" -type l 2>/dev/null || true)
  test -z "$symlink_f" || die invalid_git_admin "administrative symlink detected: $symlink_f"

  if test -d "$chk_dir/.git/hooks"; then
    for hook_f in "$chk_dir/.git/hooks"/*; do
      test -e "$hook_f" || continue
      case "$hook_f" in
        *.sample) ;;
        *) die invalid_git_admin "active git hook detected: $hook_f" ;;
      esac
    done
  fi

  for op in MERGE_HEAD MERGE_MSG MERGE_MODE rebase-apply rebase-merge CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer AUTO_MERGE; do
    if test -e "$chk_dir/.git/$op"; then
      die invalid_git_admin "in-progress git operation marker detected: $op"
    fi
  done

  if test -d "$chk_dir/.git/refs/replace"; then
    replace_loose=$(/bin/ls -A "$chk_dir/.git/refs/replace" 2>/dev/null || true)
    test -z "$replace_loose" || die invalid_git_admin 'refs/replace ref detected'
  fi
  if test -f "$chk_dir/.git/packed-refs"; then
    if /usr/bin/grep -Fq 'refs/replace/' "$chk_dir/.git/packed-refs" 2>/dev/null; then
      die invalid_git_admin 'refs/replace ref detected'
    fi
  fi
  test ! -e "$chk_dir/.git/info/grafts" || die invalid_git_admin 'info/grafts detected'
  test ! -e "$chk_dir/.git/info/attributes" || die invalid_git_admin 'info/attributes detected'
  test ! -e "$chk_dir/.git/objects/info/alternates" || die invalid_git_admin 'objects/info/alternates detected'
  return 0
}

validate_git_config() {
  local chk_dir=${1:-$CHECKOUT_DIR}
  local expected_url=${2:-$CANONICAL_REPO}
  local cfg_list key val norm_key canon_val
  local origin_url_count=0 origin_fetch_count=0
  test -n "$chk_dir" || die invalid_git_config 'checkout directory required'

  cfg_list=$(run_git -C "$chk_dir" config --local --list 2>/dev/null) || die invalid_git_config 'failed to read local git config'

  while IFS='=' read -r key val || test -n "$key"; do
    test -n "$key" || continue
    norm_key=$(printf '%s' "$key" | /usr/bin/tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')

    case "$norm_key" in
      core.repositoryformatversion)
        test "$val" = '0' || die invalid_git_config "$key=$val"
        ;;
      core.bare)
        test "$val" = 'false' || die invalid_git_config "$key=$val"
        ;;
      core.logallrefupdates)
        test "$val" = 'true' || die invalid_git_config "$key=$val"
        ;;
      core.filemode|core.ignorecase|core.precomposeunicode)
        case "$val" in
          true|false) ;;
          *) die invalid_git_config "$key=$val" ;;
        esac
        ;;
      core.symlinks)
        test "$val" = 'true' || die invalid_git_config "$key=$val"
        ;;
      core.protecthfs|core.protectntfs)
        test "$val" = 'true' || die invalid_git_config "$key=$val"
        ;;
      remote.origin.url)
        if test -n "$expected_url"; then
          canon_val=$(canonicalize_repository "$val" 2>/dev/null) || die invalid_git_config "$key=$val"
          test "$canon_val" = "$expected_url" || die invalid_git_config "$key=$val"
          origin_url_count=$((origin_url_count + 1))
        fi
        ;;
      remote.origin.fetch)
        test "$val" = '+refs/heads/*:refs/remotes/origin/*' || die invalid_git_config "$key=$val"
        origin_fetch_count=$((origin_fetch_count + 1))
        ;;
      branch.*.remote)
        test "$val" = 'origin' || die invalid_git_config "$key=$val"
        ;;
      branch.*.merge)
        case "$val" in
          refs/heads/*) ;;
          *) die invalid_git_config "$key=$val" ;;
        esac
        ;;
      submodule.*.url)
        canon_val=$(canonicalize_repository "$val" 2>/dev/null) || die invalid_git_config "$key=$val"
        ;;
      submodule.*.active)
        case "$val" in
          true|false) ;;
          *) die invalid_git_config "$key=$val" ;;
        esac
        ;;
      submodule.*.update)
        case "$val" in
          checkout|'') ;;
          *) die invalid_git_config "$key=$val" ;;
        esac
        ;;
      *)
        die invalid_git_config "$key=$val"
        ;;
    esac
  done << EOF
$cfg_list
EOF

  if test -n "$expected_url"; then
    test "$origin_url_count" -eq 1 || die invalid_git_config "expected exactly one remote.origin.url entry (found $origin_url_count)"
    test "$origin_fetch_count" -eq 1 || die invalid_git_config "expected exactly one remote.origin.fetch entry (found $origin_fetch_count)"
  fi

  return 0
}

verify_clean_tree() {
  local chk_dir=${1:-$CHECKOUT_DIR}
  local fresh_idx porcelain_out
  local meta filepath mode entry_type obj_sha actual_sha actual_link expected_link sub_dir sub_head
  test -n "$chk_dir" || die dirty_checkout

  run_git -C "$chk_dir" diff-index --quiet HEAD -- 2>/dev/null || die dirty_checkout

  test -n "$SANDBOX" || die lock_failed 'sandbox not initialized'
  fresh_idx="$SANDBOX/verify-index-$$"
  /bin/rm -f "$fresh_idx" 2>/dev/null || true

  GIT_INDEX_FILE="$fresh_idx" run_git -C "$chk_dir" read-tree HEAD 2>/dev/null || {
    /bin/rm -f "$fresh_idx" 2>/dev/null || true
    die dirty_checkout
  }
  GIT_INDEX_FILE="$fresh_idx" run_git -C "$chk_dir" update-index -q --refresh 2>/dev/null || true
  GIT_INDEX_FILE="$fresh_idx" run_git -C "$chk_dir" diff-index --quiet HEAD -- 2>/dev/null || {
    /bin/rm -f "$fresh_idx" 2>/dev/null || true
    die dirty_checkout
  }
  /bin/rm -f "$fresh_idx" 2>/dev/null || true

  while IFS="$(printf '\t')" read -r meta filepath || test -n "$meta"; do
    test -n "$meta" || continue
    mode=$(printf '%s' "$meta" | /usr/bin/awk '{print $1}')
    entry_type=$(printf '%s' "$meta" | /usr/bin/awk '{print $2}')
    obj_sha=$(printf '%s' "$meta" | /usr/bin/awk '{print $3}')

    case "$entry_type" in
      blob)
        if test "$mode" = '120000'; then
          test -L "$chk_dir/$filepath" || die dirty_checkout
          actual_link=$(/usr/bin/readlink "$chk_dir/$filepath" 2>/dev/null || true)
          expected_link=$(run_git -C "$chk_dir" cat-file blob "$obj_sha" 2>/dev/null || true)
          test "$actual_link" = "$expected_link" || die dirty_checkout
        else
          test -f "$chk_dir/$filepath" && test ! -L "$chk_dir/$filepath" || die dirty_checkout
          if test "$mode" = '100755'; then
            test -x "$chk_dir/$filepath" || die dirty_checkout
          elif test "$mode" = '100644'; then
            test ! -x "$chk_dir/$filepath" || die dirty_checkout
          fi
          actual_sha=$(run_git -C "$chk_dir" hash-object "$chk_dir/$filepath" 2>/dev/null || true)
          test "$actual_sha" = "$obj_sha" || die dirty_checkout
        fi
        ;;
      commit)
        sub_dir="$chk_dir/$filepath"
        test -d "$sub_dir/.git" || die dirty_checkout
        sub_head=$(run_git -C "$sub_dir" rev-parse HEAD 2>/dev/null || true)
        test "$sub_head" = "$obj_sha" || die dirty_checkout
        ;;
    esac
  done << EOF
$(run_git -C "$chk_dir" ls-tree -r HEAD 2>/dev/null)
EOF

  porcelain_out=$(run_git -C "$chk_dir" status --porcelain=v1 --untracked-files=all --ignored=matching --ignore-submodules=none 2>/dev/null) || die dirty_checkout
  test -z "$porcelain_out" || die dirty_checkout

  return 0
}

validate_submodules_spec() {
  local chk_dir=$1
  local commit_sha=$2
  local subm_file subm_list subm_names sname key val prop
  local spath surl supdate canon_surl tree_entry entry_mode entry_type entry_sha
  local manifest_file manifest_groups g_count g_idx g_name first_comp seen_paths seen_p plutil_bin
  local path_count url_count update_count
  local tree_gitlinks tree_gitlink_count has_gitmodules validated_subm_count meta gpath gmode gtype

  test -n "$chk_dir" || return 0
  test -n "$commit_sha" || return 0

  tree_gitlinks=''
  tree_gitlink_count=0
  while IFS="$(printf '\t')" read -r meta gpath || test -n "$meta"; do
    test -n "$meta" || continue
    gmode=$(printf '%s' "$meta" | /usr/bin/awk '{print $1}')
    gtype=$(printf '%s' "$meta" | /usr/bin/awk '{print $2}')
    if test "$gmode" = '160000' && test "$gtype" = 'commit'; then
      tree_gitlinks="$tree_gitlinks $gpath "
      tree_gitlink_count=$((tree_gitlink_count + 1))
    fi
  done << EOF
$(run_git -C "$chk_dir" ls-tree -r "$commit_sha" 2>/dev/null)
EOF

  has_gitmodules=0
  if run_git -C "$chk_dir" cat-file -e "${commit_sha}:.gitmodules" 2>/dev/null; then
    has_gitmodules=1
  fi

  if test "$has_gitmodules" -eq 0; then
    if test "$tree_gitlink_count" -gt 0; then
      die invalid_submodule "gitlink present in commit tree without .gitmodules"
    fi
    return 0
  fi

  test -n "$SANDBOX" || die lock_failed 'sandbox not initialized'
  subm_file="$SANDBOX/gitmodules-spec-$$"
  run_git -C "$chk_dir" cat-file blob "${commit_sha}:.gitmodules" > "$subm_file" 2>/dev/null || {
    /bin/rm -f "$subm_file" 2>/dev/null || true
    die invalid_submodule 'failed to extract .gitmodules from commit'
  }

  subm_list=$(run_git config --file "$subm_file" --list 2>/dev/null) || {
    /bin/rm -f "$subm_file" 2>/dev/null || true
    die invalid_submodule 'failed to parse .gitmodules'
  }
  /bin/rm -f "$subm_file" 2>/dev/null || true

  manifest_groups=''
  if run_git -C "$chk_dir" cat-file -e "${commit_sha}:.kaisian.json" 2>/dev/null; then
    manifest_file="$SANDBOX/manifest-spec-$$"
    run_git -C "$chk_dir" cat-file blob "${commit_sha}:.kaisian.json" > "$manifest_file" 2>/dev/null || true
    if test -f "$manifest_file"; then
      if test "${KAISIAN_TESTING-0}" = '1'; then
        plutil_bin="${KAISIAN_PLUTIL_EXEC:-${PLUTIL_EXEC:-/usr/bin/plutil}}"
      else
        plutil_bin="${PLUTIL_EXEC:-/usr/bin/plutil}"
      fi
      if "$plutil_bin" -convert json -o /dev/null -- "$manifest_file" 2>/dev/null; then
        g_count=$("$plutil_bin" -extract groups raw "$manifest_file" 2>/dev/null || echo 0)
        g_idx=0
        while test "$g_idx" -lt "$g_count"; do
          g_name=$("$plutil_bin" -extract "groups.$g_idx.name" raw "$manifest_file" 2>/dev/null || true)
          if test -n "$g_name"; then
            manifest_groups="$manifest_groups $g_name "
          fi
          g_idx=$((g_idx + 1))
        done
      fi
      /bin/rm -f "$manifest_file" 2>/dev/null || true
    fi
  fi

  subm_names=''
  while IFS='=' read -r key val || test -n "$key"; do
    test -n "$key" || continue
    case "$key" in
      submodule.*.path|submodule.*.url|submodule.*.update)
        sname=${key#submodule.}
        prop=${sname##*.}
        sname=${sname%.*}
        case "$sname" in
          *[!a-zA-Z0-9_.-]*|-*|''|.*) die invalid_submodule "invalid submodule name: $sname" ;;
        esac
        case " $subm_names " in
          *" $sname "*) ;;
          *) subm_names="$subm_names $sname" ;;
        esac
        ;;
      submodule.*)
        die invalid_submodule "unallowed submodule key '$key'"
        ;;
      *)
        die invalid_submodule "unallowed non-submodule key '$key'"
        ;;
    esac
  done << EOF
$subm_list
EOF

  seen_paths=''
  validated_subm_count=0
  for sname in $subm_names; do
    test -n "$sname" || continue

    spath=''
    surl=''
    supdate=''
    path_count=0
    url_count=0
    update_count=0

    while IFS='=' read -r key val || test -n "$key"; do
      case "$key" in
        submodule."$sname".path)
          spath="$val"
          path_count=$((path_count + 1))
          ;;
        submodule."$sname".url)
          surl="$val"
          url_count=$((url_count + 1))
          ;;
        submodule."$sname".update)
          supdate="$val"
          update_count=$((update_count + 1))
          ;;
      esac
    done << EOF
$subm_list
EOF

    test "$path_count" -eq 1 || die invalid_submodule "submodule '$sname' path count must be 1 (found $path_count)"
    test "$url_count" -eq 1 || die invalid_submodule "submodule '$sname' url count must be 1 (found $url_count)"
    test "$update_count" -le 1 || die invalid_submodule "duplicate update key in submodule '$sname'"

    case "$supdate" in
      ''|checkout) ;;
      *) die invalid_submodule "unallowed update mode '$supdate' for submodule $sname" ;;
    esac

    case "$spath" in
      *[!a-zA-Z0-9_.-/]*|*[[:space:]]*|*[[:cntrl:]]*|*\\*|*\*|*\?*|*\[*|*\]*|*~*)
        die invalid_submodule "unallowed characters in submodule path '$spath'"
        ;;
      /*|*/|..|../|../*|*/..|*/../*|*//*)
        die invalid_submodule "uncontained submodule path '$spath'"
        ;;
    esac

    old_ifs=$IFS
    IFS='/'
    set -- $spath
    IFS=$old_ifs
    for comp in "$@"; do
      test -n "$comp" || die invalid_submodule "empty component in submodule path '$spath'"
      case "$comp" in
        .|..) die invalid_submodule "relative segment in submodule path '$spath'" ;;
        *[!a-zA-Z0-9_.-]*) die invalid_submodule "invalid character in submodule component '$comp'" ;;
      esac
    done

    first_comp=${spath%%/*}
    if test -n "$manifest_groups"; then
      case "$manifest_groups" in
        *" $first_comp "*)
          die invalid_submodule "submodule root inside selectable package: $spath"
          ;;
      esac
    fi

    for seen_p in $seen_paths; do
      if test "$seen_p" = "$spath"; then
        die invalid_submodule "duplicate submodule path: $spath"
      fi
      case "$spath" in
        "$seen_p"/*) die invalid_submodule "overlapping submodule paths: '$seen_p' and '$spath'" ;;
      esac
      case "$seen_p" in
        "$spath"/*) die invalid_submodule "overlapping submodule paths: '$seen_p' and '$spath'" ;;
      esac
    done
    seen_paths="$seen_paths $spath"

    canon_surl=$(canonicalize_repository "$surl") || die invalid_submodule "invalid submodule url: $surl"

    if test -e "$chk_dir/$spath" || test -L "$chk_dir/$spath"; then
      if test -d "$chk_dir/$spath" && test ! -L "$chk_dir/$spath" && test -d "$chk_dir/$spath/.git" && test ! -L "$chk_dir/$spath/.git"; then
        :
      else
        die invalid_git_admin "existing path is not an initialized submodule repository: $chk_dir/$spath"
      fi
    fi

    tree_entry=$(run_git -C "$chk_dir" ls-tree "$commit_sha" "$spath" 2>/dev/null || true)
    test -n "$tree_entry" || die invalid_submodule "submodule path not found in commit tree: $spath"

    entry_mode=$(printf '%s' "$tree_entry" | /usr/bin/awk '{print $1}')
    entry_type=$(printf '%s' "$tree_entry" | /usr/bin/awk '{print $2}')
    entry_sha=$(printf '%s' "$tree_entry" | /usr/bin/awk '{print $3}')

    test "$entry_mode" = '160000' || die invalid_submodule "not a gitlink: $spath ($entry_mode)"
    test "$entry_type" = 'commit' || die invalid_submodule "not a commit object: $spath ($entry_type)"
    test -n "$entry_sha" || die invalid_submodule "missing commit SHA for gitlink: $spath"

    validated_subm_count=$((validated_subm_count + 1))
  done

  test "$validated_subm_count" -eq "$tree_gitlink_count" || die invalid_submodule "gitlink count in commit tree does not match .gitmodules ($tree_gitlink_count != $validated_subm_count)"

  return 0
}

initialize_submodules() {
  local chk_dir=${1:-$CHECKOUT_DIR}
  local subm_file subm_list subm_names key val sname spath surl supdate canon_surl
  local tree_entry entry_sha child_dir child_head child_fetched_sha
  test -n "$chk_dir" || return 0

  run_git -C "$chk_dir" cat-file -e "HEAD:.gitmodules" 2>/dev/null || return 0

  test -n "$SANDBOX" || die lock_failed 'sandbox not initialized'
  subm_file="$SANDBOX/gitmodules-$$"
  run_git -C "$chk_dir" cat-file blob "HEAD:.gitmodules" > "$subm_file" 2>/dev/null || {
    /bin/rm -f "$subm_file" 2>/dev/null || true
    die invalid_submodule 'failed to extract .gitmodules'
  }

  subm_list=$(run_git config --file "$subm_file" --list 2>/dev/null) || {
    /bin/rm -f "$subm_file" 2>/dev/null || true
    die invalid_submodule 'failed to parse .gitmodules'
  }
  /bin/rm -f "$subm_file" 2>/dev/null || true

  subm_names=''
  while IFS='=' read -r key val || test -n "$key"; do
    case "$key" in
      submodule.*.path)
        sname=${key#submodule.}
        sname=${sname%.path}
        case " $subm_names " in
          *" $sname "*) ;;
          *) subm_names="$subm_names $sname" ;;
        esac
        ;;
    esac
  done << EOF
$subm_list
EOF

  for sname in $subm_names; do
    test -n "$sname" || continue

    spath=''
    surl=''
    while IFS='=' read -r key val || test -n "$key"; do
      case "$key" in
        submodule."$sname".path) spath="$val" ;;
        submodule."$sname".url) surl="$val" ;;
      esac
    done << EOF
$subm_list
EOF

    canon_surl=$(canonicalize_repository "$surl") || die invalid_submodule "invalid submodule url: $surl"

    tree_entry=$(run_git -C "$chk_dir" ls-tree HEAD "$spath" 2>/dev/null || true)
    entry_sha=$(printf '%s' "$tree_entry" | /usr/bin/awk '{print $3}')

    child_dir="$chk_dir/$spath"
    if test -d "$child_dir/.git"; then
      validate_git_admin "$child_dir" || die submodule_failed "$sname"
      validate_git_config "$child_dir" "$canon_surl" || die submodule_failed "$sname"
      verify_clean_tree "$child_dir" || die submodule_failed "$sname"

      child_head=$(run_git -C "$child_dir" rev-parse HEAD 2>/dev/null || true)
      if test "$child_head" != "$entry_sha"; then
        run_git -C "$child_dir" fetch --no-tags --depth=1 "$canon_surl" "$entry_sha" >/dev/null 2>&1 || die submodule_failed "$sname"
        child_fetched_sha=$(run_git -C "$child_dir" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null) || die submodule_failed "$sname"
        test "$child_fetched_sha" = "$entry_sha" || die submodule_failed "$sname"
        validate_submodules_spec "$child_dir" "$entry_sha"
        run_git -C "$child_dir" checkout --detach "$entry_sha" -- >/dev/null 2>&1 || die submodule_failed "$sname"
        validate_git_config "$child_dir" "$canon_surl" || die submodule_failed "$sname"
        validate_git_admin "$child_dir" || die submodule_failed "$sname"
      else
        validate_submodules_spec "$child_dir" "$entry_sha"
      fi
    else
      /bin/mkdir -p "$child_dir" 2>/dev/null || true
      run_git init "$child_dir" >/dev/null 2>&1 || die submodule_failed "$sname"
      validate_git_admin "$child_dir" || die submodule_failed "$sname"
      run_git -C "$child_dir" config --local remote.origin.url "$canon_surl" >/dev/null 2>&1 || die submodule_failed "$sname"
      run_git -C "$child_dir" config --local remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" >/dev/null 2>&1 || die submodule_failed "$sname"

      run_git -C "$child_dir" fetch --no-tags --depth=1 "$canon_surl" "$entry_sha" >/dev/null 2>&1 || die submodule_failed "$sname"
      child_fetched_sha=$(run_git -C "$child_dir" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null) || die submodule_failed "$sname"
      test "$child_fetched_sha" = "$entry_sha" || die submodule_failed "$sname"

      validate_submodules_spec "$child_dir" "$entry_sha"

      run_git -C "$child_dir" checkout --detach "$entry_sha" -- >/dev/null 2>&1 || die submodule_failed "$sname"
      validate_git_config "$child_dir" "$canon_surl" || die submodule_failed "$sname"
      validate_git_admin "$child_dir" || die submodule_failed "$sname"
    fi

    initialize_submodules "$child_dir" || die submodule_failed "$sname"
    verify_clean_tree "$child_dir" || die submodule_failed "$sname"
  done
  return 0
}

initialize_repository() {
  local chk_dir=${1:-$CHECKOUT_DIR}
  local chk_parent
  test -n "$chk_dir" || die git_operation_failed 'checkout directory required'

  case "$chk_dir" in
    /*) ;;
    *) die git_operation_failed "checkout directory must be absolute: $chk_dir" ;;
  esac

  check_path_overlap_with_lock "$chk_dir"

  test -n "$CANONICAL_REPO" || die invalid_repository 'canonical repository not set'
  test -n "$RESOLVED_FETCH_REF" || die invalid_ref 'fetch ref not resolved'

  chk_parent=$(/usr/bin/dirname "$chk_dir")
  test -d "$chk_parent" || /bin/mkdir -p "$chk_parent" 2>/dev/null || die git_operation_failed "failed to create $chk_parent"

  run_git init "$chk_dir" >/dev/null 2>&1 || die git_operation_failed 'git init failed'
  run_git -C "$chk_dir" config --local remote.origin.url "$CANONICAL_REPO" >/dev/null 2>&1 || die git_operation_failed 'failed to set origin url'
  run_git -C "$chk_dir" config --local remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" >/dev/null 2>&1 || die git_operation_failed 'failed to set origin fetch'

  run_git -C "$chk_dir" fetch --no-tags --depth=1 "$CANONICAL_REPO" "$RESOLVED_FETCH_REF" >/dev/null 2>&1 || die git_operation_failed 'git fetch failed'

  RESOLVED_COMMIT=$(run_git -C "$chk_dir" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null) || die git_operation_failed 'failed to peel FETCH_HEAD'
  test "$RESOLVED_COMMIT" = "$EXPECTED_COMMIT_SHA" || die git_operation_failed "fetched commit mismatch: $RESOLVED_COMMIT != $EXPECTED_COMMIT_SHA"

  validate_submodules_spec "$chk_dir" "$RESOLVED_COMMIT"

  validate_git_admin "$chk_dir"
  validate_git_config "$chk_dir"

  run_git -C "$chk_dir" checkout --detach "$RESOLVED_COMMIT" -- >/dev/null 2>&1 || die git_operation_failed 'git checkout failed'

  initialize_submodules "$chk_dir"

  validate_git_admin "$chk_dir"
  validate_git_config "$chk_dir"
  verify_clean_tree "$chk_dir"

  return 0
}

update_repository() {
  local chk_dir=${1:-$CHECKOUT_DIR}
  test -n "$chk_dir" || die git_operation_failed 'checkout directory required'

  case "$chk_dir" in
    /*) ;;
    *) die git_operation_failed "checkout directory must be absolute: $chk_dir" ;;
  esac

  check_path_overlap_with_lock "$chk_dir"

  validate_git_admin "$chk_dir"
  validate_git_config "$chk_dir"
  verify_clean_tree "$chk_dir"

  test -n "$CANONICAL_REPO" || die invalid_repository 'canonical repository not set'
  test -n "$RESOLVED_FETCH_REF" || die invalid_ref 'fetch ref not resolved'

  run_git -C "$chk_dir" fetch --no-tags --depth=1 "$CANONICAL_REPO" "$RESOLVED_FETCH_REF" >/dev/null 2>&1 || die git_operation_failed 'git fetch failed'

  RESOLVED_COMMIT=$(run_git -C "$chk_dir" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null) || die git_operation_failed 'failed to peel FETCH_HEAD'
  test "$RESOLVED_COMMIT" = "$EXPECTED_COMMIT_SHA" || die git_operation_failed "fetched commit mismatch: $RESOLVED_COMMIT != $EXPECTED_COMMIT_SHA"

  validate_submodules_spec "$chk_dir" "$RESOLVED_COMMIT"
  run_git -C "$chk_dir" checkout --detach "$RESOLVED_COMMIT" -- >/dev/null 2>&1 || die git_operation_failed 'git checkout failed'
  initialize_submodules "$chk_dir"

  validate_git_admin "$chk_dir"
  validate_git_config "$chk_dir"
  verify_clean_tree "$chk_dir"

  return 0
}


is_valid_ascii_token() {
  case "$1" in
    *[!A-Za-z0-9._@+-]*|"") return 1 ;;
    *) return 0 ;;
  esac
}

is_valid_name() {
  case "$1" in
    [!abcdefghijklmnopqrstuvwxyz]* | *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
    "") return 1 ;;
    *) return 0 ;;
  esac
}

is_valid_lang() {
  token=$1
  test -n "$token" || return 1
  test ${#token} -le 64 || return 1
  case "$token" in
    *..*) return 1 ;;
    [!abcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;;
    *[!abcdefghijklmnopqrstuvwxyz0123456789._@+-]*) return 1 ;;
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
  "$plutil_bin" -insert root -xml "$(/bin/cat "$manifest_xml")" "$wrapper_xml" 2>/dev/null || die invalid_manifest malformed_syntax

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

  has_fonts=0
  fonts_type=$("$plutil_bin" -type root.fonts "$wrapper_xml" 2>/dev/null || true)
  if test -n "$fonts_type"; then
    has_fonts=1
  fi

  has_brew=0
  brew_type=$("$plutil_bin" -type root.brew "$wrapper_xml" 2>/dev/null || true)
  if test -n "$brew_type"; then
    has_brew=1
  fi

  has_features=0
  features_type=$("$plutil_bin" -type root.features "$wrapper_xml" 2>/dev/null || true)
  if test -n "$features_type"; then
    has_features=1
  fi

  # 3. Schema validation
  test "$schema_type" = 'integer' || die invalid_manifest schema_not_integer
  schema_val=$("$plutil_bin" -extract schema raw "$manifest" 2>/dev/null || true)
  test "$schema_val" = '1' || test "$schema_val" = '2' || die invalid_manifest unsupported_schema "$schema_val"

  # Unknown top-level key check via plutil residual validation
  root_check_xml="$SANDBOX/manifest_root_check.xml"
  /bin/cp "$wrapper_xml" "$root_check_xml"
  "$plutil_bin" -remove root.schema "$root_check_xml" 2>/dev/null || true
  "$plutil_bin" -remove root.groups "$root_check_xml" 2>/dev/null || true
  if test "$has_profiles" -eq 1; then
    "$plutil_bin" -remove root.profiles "$root_check_xml" 2>/dev/null || true
  fi
  if test "$schema_val" = '2'; then
    if test "$has_fonts" -eq 1; then
      "$plutil_bin" -remove root.fonts "$root_check_xml" 2>/dev/null || true
    fi
    if test "$has_brew" -eq 1; then
      "$plutil_bin" -remove root.brew "$root_check_xml" 2>/dev/null || true
    fi
    if test "$has_features" -eq 1; then
      "$plutil_bin" -remove root.features "$root_check_xml" 2>/dev/null || true
    fi
  fi
  residual_root=$("$plutil_bin" -extract root json -o - "$root_check_xml" 2>/dev/null || true)
  test "$residual_root" = '{}' || die invalid_manifest unknown_top_key "$residual_root"
  /bin/rm -f "$root_check_xml" 2>/dev/null || true
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
  prompt_groups_txt="$SANDBOX/prompt_groups.txt"
  : > "$prompt_groups_txt"
  fonts_tsv="$SANDBOX/fonts.tsv"
  : > "$fonts_tsv"
  brew_tsv="$SANDBOX/brew.tsv"
  : > "$brew_tsv"
  group_brew_deps_tsv="$SANDBOX/group_brew_deps.tsv"
: > "$group_brew_deps_tsv"
  features_tsv="$SANDBOX/features.tsv"
  : > "$features_tsv"
  feature_brew_tsv="$SANDBOX/feature_brew.tsv"
  : > "$feature_brew_tsv"
  feature_copy_tsv="$SANDBOX/feature_copy.tsv"
  : > "$feature_copy_tsv"
  feature_hotkeys_tsv="$SANDBOX/feature_hotkeys.tsv"
  : > "$feature_hotkeys_tsv"
  feature_notes_tsv="$SANDBOX/feature_notes.tsv"
  : > "$feature_notes_tsv"
  seen_feature_copy_dirs=''
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
    # Name validation
    test "$gname_type" = 'string' || die invalid_manifest group_invalid_name "$i"
    gname=$("$plutil_bin" -extract "groups.$i.name" raw "$manifest" 2>/dev/null || true)
    if test "$schema_val" = '1'; then
      is_valid_name "$gname" || die invalid_manifest group_invalid_name "$gname"
    else
      is_valid_ascii_token "$gname" || die invalid_manifest group_invalid_name "$gname"
    fi

    # Check kind
    has_kind=$("$plutil_bin" -type "groups.$i.kind" "$manifest" 2>/dev/null || true)
    kind_val=''
    if test -n "$has_kind"; then
      if test "$schema_val" = '1'; then
        :
      else
        test "$has_kind" = 'string' || die invalid_manifest group_invalid_kind "$i"
        kind_val=$("$plutil_bin" -extract "groups.$i.kind" raw "$manifest" 2>/dev/null || true)
        test "$kind_val" = 'prompt' || die invalid_manifest group_invalid_kind "$i"
      fi
    fi

    # Check brew dependencies
    has_group_brew=$("$plutil_bin" -type "groups.$i.brew" "$manifest" 2>/dev/null || true)
    if test -n "$has_group_brew"; then
      if test "$schema_val" = '1'; then
        :
      else
        test "$has_group_brew" = 'array' || die invalid_manifest group_invalid_brew "$i"
        gb_count=$("$plutil_bin" -extract "groups.$i.brew" raw "$manifest" 2>/dev/null || true)
        case "$gb_count" in
          [0-9]*) ;;
          *) die invalid_manifest group_invalid_brew "$i" ;;
        esac
        l=0
        while test "$l" -lt "$gb_count"; do
          gb_item_type=$("$plutil_bin" -type "groups.$i.brew.$l" "$manifest" 2>/dev/null || true)
          test "$gb_item_type" = 'string' || die invalid_manifest group_invalid_brew "$i"
          gb_item=$("$plutil_bin" -extract "groups.$i.brew.$l" raw "$manifest" 2>/dev/null || true)
          is_valid_ascii_token "$gb_item" || die invalid_manifest group_invalid_brew "$i"
          printf '%s\t%s\n' "$gname" "$gb_item" >> "$group_brew_deps_tsv"
          l=$((l + 1))
        done
      fi
    fi

    # Check preview
    has_group_preview=$("$plutil_bin" -type "groups.$i.preview" "$manifest" 2>/dev/null || true)
    if test -n "$has_group_preview"; then
      if test "$schema_val" = '1'; then
        :
      else
        test "$has_group_preview" = 'array' || die invalid_manifest group_preview_not_array "$i"
        gp_count=$("$plutil_bin" -extract "groups.$i.preview" raw "$manifest" 2>/dev/null || true)
        case "$gp_count" in
          [0-9]*) ;;
          *) die invalid_manifest group_preview_not_array "$i" ;;
        esac
        l_idx=0
        while test "$l_idx" -lt "$gp_count"; do
          line_type=$("$plutil_bin" -type "groups.$i.preview.$l_idx" "$manifest" 2>/dev/null || true)
          test "$line_type" = 'array' || die invalid_manifest group_preview_line_not_array "$i" "$l_idx"
          seg_count=$("$plutil_bin" -extract "groups.$i.preview.$l_idx" raw "$manifest" 2>/dev/null || true)
          case "$seg_count" in
            [0-9]*) ;;
            *) die invalid_manifest group_preview_line_not_array "$i" "$l_idx" ;;
          esac
          s_idx=0
          while test "$s_idx" -lt "$seg_count"; do
            seg_type=$("$plutil_bin" -type "groups.$i.preview.$l_idx.$s_idx" "$manifest" 2>/dev/null || true)
            test "$seg_type" = 'dictionary' || die invalid_manifest group_preview_segment_not_object "$i" "$l_idx" "$s_idx"

            text_type=$("$plutil_bin" -type "groups.$i.preview.$l_idx.$s_idx.text" "$manifest" 2>/dev/null || true)
            test -n "$text_type" || die invalid_manifest group_preview_segment_missing_text "$i" "$l_idx" "$s_idx"
            test "$text_type" = 'string' || die invalid_manifest group_preview_segment_invalid_text "$i" "$l_idx" "$s_idx"

            color_type=$("$plutil_bin" -type "groups.$i.preview.$l_idx.$s_idx.color" "$manifest" 2>/dev/null || true)
            if test -n "$color_type"; then
              test "$color_type" = 'string' || die invalid_manifest group_preview_segment_invalid_color "$i" "$l_idx" "$s_idx"
            fi

            bg_type=$("$plutil_bin" -type "groups.$i.preview.$l_idx.$s_idx.bg" "$manifest" 2>/dev/null || true)
            if test -n "$bg_type"; then
              test "$bg_type" = 'string' || die invalid_manifest group_preview_segment_invalid_bg "$i" "$l_idx" "$s_idx"
            fi

            seg_check_xml="$SANDBOX/seg_check_${i}_${l_idx}_${s_idx}.xml"
            /bin/cp "$manifest_xml" "$seg_check_xml"
            "$plutil_bin" -remove "groups.$i.preview.$l_idx.$s_idx.text" "$seg_check_xml" 2>/dev/null || true
            if test -n "$color_type"; then
              "$plutil_bin" -remove "groups.$i.preview.$l_idx.$s_idx.color" "$seg_check_xml" 2>/dev/null || true
            fi
            if test -n "$bg_type"; then
              "$plutil_bin" -remove "groups.$i.preview.$l_idx.$s_idx.bg" "$seg_check_xml" 2>/dev/null || true
            fi
            residual_seg=$("$plutil_bin" -extract "groups.$i.preview.$l_idx.$s_idx" json -o - "$seg_check_xml" 2>/dev/null || true)
            test "$residual_seg" = '{}' || die invalid_manifest group_preview_segment_unknown_key "$i" "$l_idx" "$s_idx"
            /bin/rm -f "$seg_check_xml" 2>/dev/null || true

            s_idx=$((s_idx + 1))
          done
          l_idx=$((l_idx + 1))
        done
      fi
    fi

    # Residual unknown-key check on group
    group_check_xml="$SANDBOX/group_check_$i.xml"
    /bin/cp "$manifest_xml" "$group_check_xml"
    "$plutil_bin" -remove "groups.$i.name" "$group_check_xml" 2>/dev/null || true
    "$plutil_bin" -remove "groups.$i.description" "$group_check_xml" 2>/dev/null || true
    if test "$schema_val" = '2'; then
      if test -n "$has_kind"; then
        "$plutil_bin" -remove "groups.$i.kind" "$group_check_xml" 2>/dev/null || true
      fi
      if test -n "$has_group_brew"; then
        "$plutil_bin" -remove "groups.$i.brew" "$group_check_xml" 2>/dev/null || true
      fi
      if test -n "$has_group_preview"; then
        "$plutil_bin" -remove "groups.$i.preview" "$group_check_xml" 2>/dev/null || true
      fi
    fi
    residual_group=$("$plutil_bin" -extract "groups.$i" json -o - "$group_check_xml" 2>/dev/null || true)
    test "$residual_group" = '{}' || die invalid_manifest group_unknown_key "$i"
    /bin/rm -f "$group_check_xml" 2>/dev/null || true
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
    /bin/cp "$manifest_xml" "$desc_check_xml"
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

    if test "$kind_val" = 'prompt'; then
      printf '%s\n' "$gname" >> "$prompt_groups_txt"
    fi
    printf '%s\t%s\t%s\n' "$gname" "$raw_desc_en" "$raw_desc_zh" >> "$groups_tsv"
    i=$((i + 1))
  done


  # 6. Profiles validation
  profiles_tsv="$SANDBOX/profiles.tsv"
  : > "$profiles_tsv"

  if test "$has_profiles" -eq 1; then
    test "$profiles_type" = 'dictionary' || die invalid_manifest profiles_not_object

    prof_check_xml="$SANDBOX/prof_check.xml"
    /bin/cp "$manifest_xml" "$prof_check_xml"

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
  # 7. Fonts validation (schema 2)
  if test "$schema_val" = '2' && test "$has_fonts" -eq 1; then
    test "$fonts_type" = 'array' || die invalid_manifest fonts_not_array
    font_count=$("$plutil_bin" -extract fonts raw "$manifest" 2>/dev/null || true)
    case "$font_count" in
      [0-9]*) ;;
      *) die invalid_manifest fonts_not_array ;;
    esac

    seen_font_casks=''
    k=0
    while test "$k" -lt "$font_count"; do
      ftype=$("$plutil_bin" -type "fonts.$k" "$manifest" 2>/dev/null || true)
      test "$ftype" = 'dictionary' || die invalid_manifest font_not_object "$k"

      cask_type=$("$plutil_bin" -type "fonts.$k.cask" "$manifest" 2>/dev/null || true)
      test -n "$cask_type" || die invalid_manifest font_missing_cask "$k"
      test "$cask_type" = 'string' || die invalid_manifest font_invalid_cask "$k"
      fcask=$("$plutil_bin" -extract "fonts.$k.cask" raw "$manifest" 2>/dev/null || true)
      is_valid_ascii_token "$fcask" || die invalid_manifest font_invalid_cask "$fcask"

      case " $seen_font_casks " in
        *" $fcask "*) die invalid_manifest font_duplicate_cask "$fcask" ;;
      esac
      if test -z "$seen_font_casks"; then
        seen_font_casks="$fcask"
      else
        seen_font_casks="$seen_font_casks $fcask"
      fi

      has_font_preview=$("$plutil_bin" -type "fonts.$k.preview" "$manifest" 2>/dev/null || true)
      if test -n "$has_font_preview"; then
        test "$has_font_preview" = 'string' || die invalid_manifest font_invalid_preview "$k"
      fi
      family_type=$("$plutil_bin" -type "fonts.$k.family" "$manifest" 2>/dev/null || true)
      test -n "$family_type" || die invalid_manifest font_missing_family "$k"
      test "$family_type" = 'string' || die invalid_manifest font_empty_family "$k"
      ffamily=$("$plutil_bin" -extract "fonts.$k.family" raw "$manifest" 2>/dev/null; printf 'x')
      ffamily=${ffamily%x}
      ffamily=${ffamily%"$nl"}
      test -n "$ffamily" || die invalid_manifest font_empty_family "$k"
      has_control_char "$ffamily" && die invalid_manifest font_control_char "$k"
      case "$ffamily" in
        *'	'*) die invalid_manifest font_control_char "$k" ;;
      esac

      fdesc_type=$("$plutil_bin" -type "fonts.$k.description" "$manifest" 2>/dev/null || true)
      test -n "$fdesc_type" || die invalid_manifest font_missing_description "$k"
      test "$fdesc_type" = 'dictionary' || die invalid_manifest description_not_object "$k"

      fen_type=$("$plutil_bin" -type "fonts.$k.description.en" "$manifest" 2>/dev/null || true)
      test -n "$fen_type" || die invalid_manifest description_missing_en "$k"
      fzhtw_type=$("$plutil_bin" -type "fonts.$k.description.zh-TW" "$manifest" 2>/dev/null || true)
      test -n "$fzhtw_type" || die invalid_manifest description_missing_zhtw "$k"

      font_check_xml="$SANDBOX/font_check_$k.xml"
      /bin/cp "$manifest_xml" "$font_check_xml"
      "$plutil_bin" -remove "fonts.$k.cask" "$font_check_xml" 2>/dev/null || true
      "$plutil_bin" -remove "fonts.$k.family" "$font_check_xml" 2>/dev/null || true
      if test -n "$has_font_preview"; then
        "$plutil_bin" -remove "fonts.$k.preview" "$font_check_xml" 2>/dev/null || true
      fi
      "$plutil_bin" -remove "fonts.$k.description.en" "$font_check_xml" 2>/dev/null || true
      "$plutil_bin" -remove "fonts.$k.description.zh-TW" "$font_check_xml" 2>/dev/null || true
      residual_fdesc=$("$plutil_bin" -extract "fonts.$k.description" json -o - "$font_check_xml" 2>/dev/null || true)
      test "$residual_fdesc" = '{}' || die invalid_manifest description_unknown_key "$k"
      "$plutil_bin" -remove "fonts.$k.description" "$font_check_xml" 2>/dev/null || true
      residual_font=$("$plutil_bin" -extract "fonts.$k" json -o - "$font_check_xml" 2>/dev/null || true)
      test "$residual_font" = '{}' || die invalid_manifest font_unknown_key "$k"
      /bin/rm -f "$font_check_xml" 2>/dev/null || true

      test "$fen_type" = 'string' || die invalid_manifest description_empty_en "$k"
      raw_fen=$("$plutil_bin" -extract "fonts.$k.description.en" raw "$manifest" 2>/dev/null; printf 'x')
      raw_fen=${raw_fen%x}
      raw_fen=${raw_fen%"$nl"}
      test -n "$raw_fen" || die invalid_manifest description_empty_en "$k"
      has_control_char "$raw_fen" && die invalid_manifest description_control_char "$k"

      test "$fzhtw_type" = 'string' || die invalid_manifest description_empty_zhtw "$k"
      raw_fzh=$("$plutil_bin" -extract "fonts.$k.description.zh-TW" raw "$manifest" 2>/dev/null; printf 'x')
      raw_fzh=${raw_fzh%x}
      raw_fzh=${raw_fzh%"$nl"}
      test -n "$raw_fzh" || die invalid_manifest description_empty_zhtw "$k"
      has_control_char "$raw_fzh" && die invalid_manifest description_control_char "$k"

      printf '%s\t%s\n' "$fcask" "$ffamily" >> "$fonts_tsv"
      k=$((k + 1))
    done
  fi

  # 8. Brew validation (schema 2)
  if test "$schema_val" = '2' && test "$has_brew" -eq 1; then
    test "$brew_type" = 'array' || die invalid_manifest brew_not_array
    brew_count=$("$plutil_bin" -extract brew raw "$manifest" 2>/dev/null || true)
    case "$brew_count" in
      [0-9]*) ;;
      *) die invalid_manifest brew_not_array ;;
    esac

    seen_brew_names=''
    m=0
    while test "$m" -lt "$brew_count"; do
      btype=$("$plutil_bin" -type "brew.$m" "$manifest" 2>/dev/null || true)
      test "$btype" = 'dictionary' || die invalid_manifest brew_not_object "$m"

      bname_type=$("$plutil_bin" -type "brew.$m.name" "$manifest" 2>/dev/null || true)
      test -n "$bname_type" || die invalid_manifest brew_missing_name "$m"
      test "$bname_type" = 'string' || die invalid_manifest brew_invalid_name "$m"
      bname=$("$plutil_bin" -extract "brew.$m.name" raw "$manifest" 2>/dev/null || true)
      is_valid_ascii_token "$bname" || die invalid_manifest brew_invalid_name "$bname"

      case " $seen_brew_names " in
        *" $bname "*) die invalid_manifest brew_duplicate_name "$bname" ;;
      esac
      if test -z "$seen_brew_names"; then
        seen_brew_names="$bname"
      else
        seen_brew_names="$seen_brew_names $bname"
      fi

      cask_val=0
      bcask_type=$("$plutil_bin" -type "brew.$m.cask" "$manifest" 2>/dev/null || true)
      if test -n "$bcask_type"; then
        test "$bcask_type" = 'bool' || test "$bcask_type" = 'boolean' || die invalid_manifest brew_invalid_cask "$m"
        raw_cask=$("$plutil_bin" -extract "brew.$m.cask" raw "$manifest" 2>/dev/null || true)
        if test "$raw_cask" = 'true' || test "$raw_cask" = '1'; then
          cask_val=1
        fi
      fi

      bdesc_type=$("$plutil_bin" -type "brew.$m.description" "$manifest" 2>/dev/null || true)
      test -n "$bdesc_type" || die invalid_manifest brew_missing_description "$m"
      test "$bdesc_type" = 'dictionary' || die invalid_manifest description_not_object "$m"

      ben_type=$("$plutil_bin" -type "brew.$m.description.en" "$manifest" 2>/dev/null || true)
      test -n "$ben_type" || die invalid_manifest description_missing_en "$m"
      bzhtw_type=$("$plutil_bin" -type "brew.$m.description.zh-TW" "$manifest" 2>/dev/null || true)
      test -n "$bzhtw_type" || die invalid_manifest description_missing_zhtw "$m"

      brew_check_xml="$SANDBOX/brew_check_$m.xml"
      /bin/cp "$manifest_xml" "$brew_check_xml"
      "$plutil_bin" -remove "brew.$m.name" "$brew_check_xml" 2>/dev/null || true
      if test -n "$bcask_type"; then
        "$plutil_bin" -remove "brew.$m.cask" "$brew_check_xml" 2>/dev/null || true
      fi
      "$plutil_bin" -remove "brew.$m.description.en" "$brew_check_xml" 2>/dev/null || true
      "$plutil_bin" -remove "brew.$m.description.zh-TW" "$brew_check_xml" 2>/dev/null || true
      residual_bdesc=$("$plutil_bin" -extract "brew.$m.description" json -o - "$brew_check_xml" 2>/dev/null || true)
      test "$residual_bdesc" = '{}' || die invalid_manifest description_unknown_key "$m"
      "$plutil_bin" -remove "brew.$m.description" "$brew_check_xml" 2>/dev/null || true
      residual_brew=$("$plutil_bin" -extract "brew.$m" json -o - "$brew_check_xml" 2>/dev/null || true)
      test "$residual_brew" = '{}' || die invalid_manifest brew_unknown_key "$m"
      /bin/rm -f "$brew_check_xml" 2>/dev/null || true

      test "$ben_type" = 'string' || die invalid_manifest description_empty_en "$m"
      raw_ben=$("$plutil_bin" -extract "brew.$m.description.en" raw "$manifest" 2>/dev/null; printf 'x')
      raw_ben=${raw_ben%x}
      raw_ben=${raw_ben%"$nl"}
      test -n "$raw_ben" || die invalid_manifest description_empty_en "$m"
      has_control_char "$raw_ben" && die invalid_manifest description_control_char "$m"

      test "$bzhtw_type" = 'string' || die invalid_manifest description_empty_zhtw "$m"
      raw_bzh=$("$plutil_bin" -extract "brew.$m.description.zh-TW" raw "$manifest" 2>/dev/null; printf 'x')
      raw_bzh=${raw_bzh%x}
      raw_bzh=${raw_bzh%"$nl"}
      test -n "$raw_bzh" || die invalid_manifest description_empty_zhtw "$m"
      has_control_char "$raw_bzh" && die invalid_manifest description_control_char "$m"

      printf '%s\t%s\n' "$bname" "$cask_val" >> "$brew_tsv"
      m=$((m + 1))
    done
  fi
  # 9. Validate group brew dependencies against catalog (schema 2)
  if test "$schema_val" = '2' && test -f "$group_brew_deps_tsv"; then
    while IFS='	' read -r dep_gname dep_bname || test -n "$dep_gname"; do
      test -n "$dep_gname" && test -n "$dep_bname" || continue
      found_catalog_brew=0
      if test -f "$brew_tsv"; then
        while IFS='	' read -r bcat_name bcat_cask || test -n "$bcat_name"; do
          if test "$bcat_name" = "$dep_bname"; then
            found_catalog_brew=1
            break
          fi
        done < "$brew_tsv"
      fi
      test "$found_catalog_brew" -eq 1 || die invalid_manifest group_unknown_brew "$dep_gname" "$dep_bname"
    done < "$group_brew_deps_tsv"
  fi

  # 10. Features validation (schema 2)
  if test "$schema_val" = '2' && test "$has_features" -eq 1; then
    test "$features_type" = 'array' || die invalid_manifest features_not_array
    feature_count=$("$plutil_bin" -extract features raw "$manifest" 2>/dev/null || true)
    case "$feature_count" in
      [0-9]*) ;;
      *) die invalid_manifest features_not_array ;;
    esac

    seen_feature_names=''
    fn_idx=0
    while test "$fn_idx" -lt "$feature_count"; do
      ftype=$("$plutil_bin" -type "features.$fn_idx" "$manifest" 2>/dev/null || true)
      test "$ftype" = 'dictionary' || die invalid_manifest feature_not_object "$fn_idx"

      fname_type=$("$plutil_bin" -type "features.$fn_idx.name" "$manifest" 2>/dev/null || true)
      test -n "$fname_type" || die invalid_manifest feature_missing_name "$fn_idx"
      test "$fname_type" = 'string' || die invalid_manifest feature_invalid_name "$fn_idx"
      fname=$("$plutil_bin" -extract "features.$fn_idx.name" raw "$manifest" 2>/dev/null || true)
      is_valid_ascii_token "$fname" || die invalid_manifest feature_invalid_name "$fname"

      case " $seen_feature_names " in
        *" $fname "*) die invalid_manifest feature_duplicate_name "$fname" ;;
      esac
      if test -z "$seen_feature_names"; then
        seen_feature_names="$fname"
      else
        seen_feature_names="$seen_feature_names $fname"
      fi

      f_macos=0
      fmacos_type=$("$plutil_bin" -type "features.$fn_idx.macos" "$manifest" 2>/dev/null || true)
      if test -n "$fmacos_type"; then
        test "$fmacos_type" = 'bool' || test "$fmacos_type" = 'boolean' || die invalid_manifest feature_invalid_macos "$fname"
        raw_macos=$("$plutil_bin" -extract "features.$fn_idx.macos" raw "$manifest" 2>/dev/null || true)
        if test "$raw_macos" = 'true' || test "$raw_macos" = '1'; then
          f_macos=1
        fi
      fi

      fdesc_type=$("$plutil_bin" -type "features.$fn_idx.description" "$manifest" 2>/dev/null || true)
      test -n "$fdesc_type" || die invalid_manifest feature_missing_description "$fname"
      test "$fdesc_type" = 'dictionary' || die invalid_manifest description_not_object "$fname"

      fden_type=$("$plutil_bin" -type "features.$fn_idx.description.en" "$manifest" 2>/dev/null || true)
      test -n "$fden_type" || die invalid_manifest description_missing_en "$fname"
      fdzhtw_type=$("$plutil_bin" -type "features.$fn_idx.description.zh-TW" "$manifest" 2>/dev/null || true)
      test -n "$fdzhtw_type" || die invalid_manifest description_missing_zhtw "$fname"

      test "$fden_type" = 'string' || die invalid_manifest description_empty_en "$fname"
      raw_fden=$("$plutil_bin" -extract "features.$fn_idx.description.en" raw "$manifest" 2>/dev/null; printf 'x')
      raw_fden=${raw_fden%x}
      raw_fden=${raw_fden%"$nl"}
      test -n "$raw_fden" || die invalid_manifest description_empty_en "$fname"
      has_control_char "$raw_fden" && die invalid_manifest description_control_char "$fname"

      test "$fdzhtw_type" = 'string' || die invalid_manifest description_empty_zhtw "$fname"
      raw_fdzh=$("$plutil_bin" -extract "features.$fn_idx.description.zh-TW" raw "$manifest" 2>/dev/null; printf 'x')
      raw_fdzh=${raw_fdzh%x}
      raw_fdzh=${raw_fdzh%"$nl"}
      test -n "$raw_fdzh" || die invalid_manifest description_empty_zhtw "$fname"
      has_control_char "$raw_fdzh" && die invalid_manifest description_control_char "$fname"

      has_fnotes=0
      raw_fnen=''
      raw_fnzh=''
      fnotes_type=$("$plutil_bin" -type "features.$fn_idx.notes" "$manifest" 2>/dev/null || true)
      if test -n "$fnotes_type"; then
        has_fnotes=1
        test "$fnotes_type" = 'dictionary' || die invalid_manifest feature_invalid_notes "$fname"
        fnen_type=$("$plutil_bin" -type "features.$fn_idx.notes.en" "$manifest" 2>/dev/null || true)
        test -n "$fnen_type" || die invalid_manifest notes_missing_en "$fname"
        fnzhtw_type=$("$plutil_bin" -type "features.$fn_idx.notes.zh-TW" "$manifest" 2>/dev/null || true)
        test -n "$fnzhtw_type" || die invalid_manifest notes_missing_zhtw "$fname"

        test "$fnen_type" = 'string' || die invalid_manifest notes_empty_en "$fname"
        raw_fnen=$("$plutil_bin" -extract "features.$fn_idx.notes.en" raw "$manifest" 2>/dev/null; printf 'x')
        raw_fnen=${raw_fnen%x}
        raw_fnen=${raw_fnen%"$nl"}
        test -n "$raw_fnen" || die invalid_manifest notes_empty_en "$fname"
        has_control_char "$raw_fnen" && die invalid_manifest notes_control_char "$fname"

        test "$fnzhtw_type" = 'string' || die invalid_manifest notes_empty_zhtw "$fname"
        raw_fnzh=$("$plutil_bin" -extract "features.$fn_idx.notes.zh-TW" raw "$manifest" 2>/dev/null; printf 'x')
        raw_fnzh=${raw_fnzh%x}
        raw_fnzh=${raw_fnzh%"$nl"}
        test -n "$raw_fnzh" || die invalid_manifest notes_empty_zhtw "$fname"
        has_control_char "$raw_fnzh" && die invalid_manifest notes_control_char "$fname"
      fi

      has_fbrew=0
      fbrew_type=$("$plutil_bin" -type "features.$fn_idx.brew" "$manifest" 2>/dev/null || true)
      if test -n "$fbrew_type"; then
        has_fbrew=1
        test "$fbrew_type" = 'array' || die invalid_manifest feature_brew_not_array "$fname"
        fbrew_cnt=$("$plutil_bin" -extract "features.$fn_idx.brew" raw "$manifest" 2>/dev/null || true)
        case "$fbrew_cnt" in
          [0-9]*) ;;
          *) die invalid_manifest feature_brew_not_array "$fname" ;;
        esac
        fb_i=0
        while test "$fb_i" -lt "$fbrew_cnt"; do
          fb_type=$("$plutil_bin" -type "features.$fn_idx.brew.$fb_i" "$manifest" 2>/dev/null || true)
          test "$fb_type" = 'dictionary' || die invalid_manifest feature_brew_not_object "$fname" "$fb_i"

          fb_name_type=$("$plutil_bin" -type "features.$fn_idx.brew.$fb_i.name" "$manifest" 2>/dev/null || true)
          test -n "$fb_name_type" || die invalid_manifest feature_brew_missing_name "$fname" "$fb_i"
          test "$fb_name_type" = 'string' || die invalid_manifest feature_brew_invalid_name "$fname" "$fb_i"
          fb_name=$("$plutil_bin" -extract "features.$fn_idx.brew.$fb_i.name" raw "$manifest" 2>/dev/null || true)
          is_valid_ascii_token "$fb_name" || die invalid_manifest feature_brew_invalid_name "$fname" "$fb_name"

          fb_cask=0
          fb_cask_type=$("$plutil_bin" -type "features.$fn_idx.brew.$fb_i.cask" "$manifest" 2>/dev/null || true)
          if test -n "$fb_cask_type"; then
            test "$fb_cask_type" = 'bool' || test "$fb_cask_type" = 'boolean' || die invalid_manifest feature_brew_invalid_cask "$fname" "$fb_i"
            raw_fbcask=$("$plutil_bin" -extract "features.$fn_idx.brew.$fb_i.cask" raw "$manifest" 2>/dev/null || true)
            if test "$raw_fbcask" = 'true' || test "$raw_fbcask" = '1'; then
              fb_cask=1
            fi
          fi

          fb_check_xml="$SANDBOX/fb_check_${fn_idx}_${fb_i}.xml"
          /bin/cp "$manifest_xml" "$fb_check_xml"
          "$plutil_bin" -remove "features.$fn_idx.brew.$fb_i.name" "$fb_check_xml" 2>/dev/null || true
          if test -n "$fb_cask_type"; then
            "$plutil_bin" -remove "features.$fn_idx.brew.$fb_i.cask" "$fb_check_xml" 2>/dev/null || true
          fi
          residual_fb=$("$plutil_bin" -extract "features.$fn_idx.brew.$fb_i" json -o - "$fb_check_xml" 2>/dev/null || true)
          test "$residual_fb" = '{}' || die invalid_manifest feature_brew_unknown_key "$fname" "$fb_i"
          /bin/rm -f "$fb_check_xml" 2>/dev/null || true

          printf '%s\t%s\t%s\n' "$fname" "$fb_name" "$fb_cask" >> "$feature_brew_tsv"
          fb_i=$((fb_i + 1))
        done
      fi

      has_fcopy=0
      fcopy_type=$("$plutil_bin" -type "features.$fn_idx.copy" "$manifest" 2>/dev/null || true)
      if test -n "$fcopy_type"; then
        has_fcopy=1
        test "$fcopy_type" = 'array' || die invalid_manifest feature_copy_not_array "$fname"
        fcopy_cnt=$("$plutil_bin" -extract "features.$fn_idx.copy" raw "$manifest" 2>/dev/null || true)
        case "$fcopy_cnt" in
          [0-9]*) ;;
          *) die invalid_manifest feature_copy_not_array "$fname" ;;
        esac
        fc_i=0
        while test "$fc_i" -lt "$fcopy_cnt"; do
          fc_type=$("$plutil_bin" -type "features.$fn_idx.copy.$fc_i" "$manifest" 2>/dev/null || true)
          test "$fc_type" = 'dictionary' || die invalid_manifest feature_copy_not_object "$fname" "$fc_i"

          fc_from_type=$("$plutil_bin" -type "features.$fn_idx.copy.$fc_i.from" "$manifest" 2>/dev/null || true)
          test -n "$fc_from_type" || die invalid_manifest feature_copy_missing_from "$fname" "$fc_i"
          test "$fc_from_type" = 'string' || die invalid_manifest feature_copy_invalid_from "$fname" "$fc_i"
          fc_from=$("$plutil_bin" -extract "features.$fn_idx.copy.$fc_i.from" raw "$manifest" 2>/dev/null || true)

          test -n "$fc_from" || die invalid_manifest feature_copy_invalid_from "$fname" '<empty>'
          has_control_char "$fc_from" && die invalid_manifest feature_copy_invalid_from "$fname" "$fc_from"
          case "$fc_from" in
            /*|..|*/..|../*|*/../*) die invalid_manifest feature_copy_invalid_from "$fname" "$fc_from" ;;
          esac
          src_file="$checkout_dir/$fc_from"
          test -f "$src_file" && test ! -d "$src_file" || die invalid_manifest feature_copy_invalid_from "$fname" "$fc_from"

          fc_to_type=$("$plutil_bin" -type "features.$fn_idx.copy.$fc_i.to" "$manifest" 2>/dev/null || true)
          test -n "$fc_to_type" || die invalid_manifest feature_copy_missing_to "$fname" "$fc_i"
          test "$fc_to_type" = 'string' || die invalid_manifest feature_copy_invalid_to "$fname" "$fc_i"
          fc_to=$("$plutil_bin" -extract "features.$fn_idx.copy.$fc_i.to" raw "$manifest" 2>/dev/null || true)

          test -n "$fc_to" || die invalid_manifest feature_copy_invalid_to "$fname" '<empty>'
          has_control_char "$fc_to" && die invalid_manifest feature_copy_invalid_to "$fname" "$fc_to"
          case "$fc_to" in
            /*|..|*/..|../*|*/../*) die invalid_manifest feature_copy_invalid_to "$fname" "$fc_to" ;;
          esac

          fc_top="${fc_from%%/*}"
          if test -n "$fc_top"; then
            case " $seen_feature_copy_dirs " in
              *" $fc_top "*) ;;
              *) seen_feature_copy_dirs="$seen_feature_copy_dirs $fc_top" ;;
            esac
          fi

          fc_check_xml="$SANDBOX/fc_check_${fn_idx}_${fc_i}.xml"
          /bin/cp "$manifest_xml" "$fc_check_xml"
          "$plutil_bin" -remove "features.$fn_idx.copy.$fc_i.from" "$fc_check_xml" 2>/dev/null || true
          "$plutil_bin" -remove "features.$fn_idx.copy.$fc_i.to" "$fc_check_xml" 2>/dev/null || true
          residual_fc=$("$plutil_bin" -extract "features.$fn_idx.copy.$fc_i" json -o - "$fc_check_xml" 2>/dev/null || true)
          test "$residual_fc" = '{}' || die invalid_manifest feature_copy_unknown_key "$fname" "$fc_i"
          /bin/rm -f "$fc_check_xml" 2>/dev/null || true

          printf '%s\t%s\t%s\n' "$fname" "$fc_from" "$fc_to" >> "$feature_copy_tsv"
          fc_i=$((fc_i + 1))
        done
      fi

      has_fhotkeys=0
      fhk_type=$("$plutil_bin" -type "features.$fn_idx.hotkeys" "$manifest" 2>/dev/null || true)
      if test -n "$fhk_type"; then
        has_fhotkeys=1
        test "$fhk_type" = 'array' || die invalid_manifest feature_hotkeys_not_array "$fname"
        fhk_cnt=$("$plutil_bin" -extract "features.$fn_idx.hotkeys" raw "$manifest" 2>/dev/null || true)
        case "$fhk_cnt" in
          [0-9]*) ;;
          *) die invalid_manifest feature_hotkeys_not_array "$fname" ;;
        esac
        fhk_i=0
        while test "$fhk_i" -lt "$fhk_cnt"; do
          hk_type=$("$plutil_bin" -type "features.$fn_idx.hotkeys.$fhk_i" "$manifest" 2>/dev/null || true)
          test "$hk_type" = 'dictionary' || die invalid_manifest feature_hotkey_not_object "$fname" "$fhk_i"

          hk_id_type=$("$plutil_bin" -type "features.$fn_idx.hotkeys.$fhk_i.id" "$manifest" 2>/dev/null || true)
          test -n "$hk_id_type" || die invalid_manifest feature_hotkey_missing_id "$fname" "$fhk_i"
          test "$hk_id_type" = 'integer' || die invalid_manifest feature_hotkey_invalid_id "$fname" "$fhk_i"
          hk_id=$("$plutil_bin" -extract "features.$fn_idx.hotkeys.$fhk_i.id" raw "$manifest" 2>/dev/null || true)
          case "$hk_id" in
            +-*[0-9]*|[0-9]*) ;;
            *) die invalid_manifest feature_hotkey_invalid_id "$fname" "$fhk_i" ;;
          esac

          hk_en_type=$("$plutil_bin" -type "features.$fn_idx.hotkeys.$fhk_i.enabled" "$manifest" 2>/dev/null || true)
          test -n "$hk_en_type" || die invalid_manifest feature_hotkey_invalid_enabled "$fname" "$fhk_i"
          test "$hk_en_type" = 'bool' || test "$hk_en_type" = 'boolean' || die invalid_manifest feature_hotkey_invalid_enabled "$fname" "$fhk_i"
          raw_hken=$("$plutil_bin" -extract "features.$fn_idx.hotkeys.$fhk_i.enabled" raw "$manifest" 2>/dev/null || true)
          hk_enabled=0
          if test "$raw_hken" = 'true' || test "$raw_hken" = '1'; then
            hk_enabled=1
          fi

          hk_ascii=''
          hk_keycode=''
          hk_modifiers=''
          has_ascii=0
          has_kc=0
          has_mod=0

          hk_ascii_type=$("$plutil_bin" -type "features.$fn_idx.hotkeys.$fhk_i.ascii" "$manifest" 2>/dev/null || true)
          if test -n "$hk_ascii_type"; then
            has_ascii=1
            test "$hk_ascii_type" = 'integer' || die invalid_manifest feature_hotkey_invalid_param "$fname" "$fhk_i" "ascii"
            hk_ascii=$("$plutil_bin" -extract "features.$fn_idx.hotkeys.$fhk_i.ascii" raw "$manifest" 2>/dev/null || true)
          fi

          hk_kc_type=$("$plutil_bin" -type "features.$fn_idx.hotkeys.$fhk_i.keycode" "$manifest" 2>/dev/null || true)
          if test -n "$hk_kc_type"; then
            has_kc=1
            test "$hk_kc_type" = 'integer' || die invalid_manifest feature_hotkey_invalid_param "$fname" "$fhk_i" "keycode"
            hk_keycode=$("$plutil_bin" -extract "features.$fn_idx.hotkeys.$fhk_i.keycode" raw "$manifest" 2>/dev/null || true)
          fi

          hk_mod_type=$("$plutil_bin" -type "features.$fn_idx.hotkeys.$fhk_i.modifiers" "$manifest" 2>/dev/null || true)
          if test -n "$hk_mod_type"; then
            has_mod=1
            test "$hk_mod_type" = 'integer' || die invalid_manifest feature_hotkey_invalid_param "$fname" "$fhk_i" "modifiers"
            hk_modifiers=$("$plutil_bin" -extract "features.$fn_idx.hotkeys.$fhk_i.modifiers" raw "$manifest" 2>/dev/null || true)
          fi

          if test "$hk_enabled" -eq 1; then
            test "$has_ascii" -eq 1 && test "$has_kc" -eq 1 && test "$has_mod" -eq 1 || die invalid_manifest feature_hotkey_missing_params "$fname" "$fhk_i"
          fi

          fhk_check_xml="$SANDBOX/fhk_check_${fn_idx}_${fhk_i}.xml"
          /bin/cp "$manifest_xml" "$fhk_check_xml"
          "$plutil_bin" -remove "features.$fn_idx.hotkeys.$fhk_i.id" "$fhk_check_xml" 2>/dev/null || true
          "$plutil_bin" -remove "features.$fn_idx.hotkeys.$fhk_i.enabled" "$fhk_check_xml" 2>/dev/null || true
          if test "$has_ascii" -eq 1; then
            "$plutil_bin" -remove "features.$fn_idx.hotkeys.$fhk_i.ascii" "$fhk_check_xml" 2>/dev/null || true
          fi
          if test "$has_kc" -eq 1; then
            "$plutil_bin" -remove "features.$fn_idx.hotkeys.$fhk_i.keycode" "$fhk_check_xml" 2>/dev/null || true
          fi
          if test "$has_mod" -eq 1; then
            "$plutil_bin" -remove "features.$fn_idx.hotkeys.$fhk_i.modifiers" "$fhk_check_xml" 2>/dev/null || true
          fi
          residual_fhk=$("$plutil_bin" -extract "features.$fn_idx.hotkeys.$fhk_i" json -o - "$fhk_check_xml" 2>/dev/null || true)
          test "$residual_fhk" = '{}' || die invalid_manifest feature_hotkey_unknown_key "$fname" "$fhk_i"
          /bin/rm -f "$fhk_check_xml" 2>/dev/null || true

          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$fname" "$hk_id" "$hk_enabled" "$hk_ascii" "$hk_keycode" "$hk_modifiers" >> "$feature_hotkeys_tsv"
          fhk_i=$((fhk_i + 1))
        done
      fi

      feat_check_xml="$SANDBOX/feat_check_$fn_idx.xml"
      /bin/cp "$manifest_xml" "$feat_check_xml"
      "$plutil_bin" -remove "features.$fn_idx.name" "$feat_check_xml" 2>/dev/null || true
      if test -n "$fmacos_type"; then
        "$plutil_bin" -remove "features.$fn_idx.macos" "$feat_check_xml" 2>/dev/null || true
      fi
      "$plutil_bin" -remove "features.$fn_idx.description.en" "$feat_check_xml" 2>/dev/null || true
      "$plutil_bin" -remove "features.$fn_idx.description.zh-TW" "$feat_check_xml" 2>/dev/null || true
      residual_fdesc=$("$plutil_bin" -extract "features.$fn_idx.description" json -o - "$feat_check_xml" 2>/dev/null || true)
      test "$residual_fdesc" = '{}' || die invalid_manifest description_unknown_key "$fname"
      "$plutil_bin" -remove "features.$fn_idx.description" "$feat_check_xml" 2>/dev/null || true

      if test "$has_fnotes" -eq 1; then
        "$plutil_bin" -remove "features.$fn_idx.notes.en" "$feat_check_xml" 2>/dev/null || true
        "$plutil_bin" -remove "features.$fn_idx.notes.zh-TW" "$feat_check_xml" 2>/dev/null || true
        residual_fnotes=$("$plutil_bin" -extract "features.$fn_idx.notes" json -o - "$feat_check_xml" 2>/dev/null || true)
        test "$residual_fnotes" = '{}' || die invalid_manifest notes_unknown_key "$fname"
        "$plutil_bin" -remove "features.$fn_idx.notes" "$feat_check_xml" 2>/dev/null || true
        printf '%s\t%s\t%s\n' "$fname" "$raw_fnen" "$raw_fnzh" >> "$feature_notes_tsv"
      fi

      if test "$has_fbrew" -eq 1; then
        "$plutil_bin" -remove "features.$fn_idx.brew" "$feat_check_xml" 2>/dev/null || true
      fi
      if test "$has_fcopy" -eq 1; then
        "$plutil_bin" -remove "features.$fn_idx.copy" "$feat_check_xml" 2>/dev/null || true
      fi
      if test "$has_fhotkeys" -eq 1; then
        "$plutil_bin" -remove "features.$fn_idx.hotkeys" "$feat_check_xml" 2>/dev/null || true
      fi

      residual_feat=$("$plutil_bin" -extract "features.$fn_idx" json -o - "$feat_check_xml" 2>/dev/null || true)
      test "$residual_feat" = '{}' || die invalid_manifest feature_unknown_key "$fname"
      /bin/rm -f "$feat_check_xml" 2>/dev/null || true

      printf '%s\t%s\t%s\t%s\n' "$fname" "$f_macos" "$raw_fden" "$raw_fdzh" >> "$features_tsv"
      fn_idx=$((fn_idx + 1))
    done
  fi

  # 11. Package directory alignment
  for g in $seen_group_names; do
    test -d "$checkout_dir/$g" && test ! -L "$checkout_dir/$g" || die invalid_manifest missing_package_dir "$g"
  done

  for entry in "$checkout_dir"/*; do
    test -e "$entry" || continue
    if test -d "$entry" && test ! -L "$entry"; then
      entry_name="${entry##*/}"
      case " $seen_group_names $seen_feature_copy_dirs " in
        *" $entry_name "*) ;;
        *) die invalid_manifest undeclared_package_dir "$entry_name" ;;
      esac
    fi
  done
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

lookup_profile_groups() {
  test -f "$SANDBOX/profiles.tsv" || return 1
  while IFS='	' read -r pname pgroups || test -n "$pname"; do
    if test "$pname" = "$1"; then
      printf '%s\n' "$pgroups"
      return 0
    fi
  done < "$SANDBOX/profiles.tsv"
  return 1
}

is_prompt_group() {
  test -f "$SANDBOX/prompt_groups.txt" || return 1
  while IFS= read -r pgrp || test -n "$pgrp"; do
    test "$pgrp" = "$1" && return 0
  done < "$SANDBOX/prompt_groups.txt"
  return 1
}

select_all_groups() {
  : > "$SANDBOX/selected.txt"
  : > "$SANDBOX/unselected.txt"
  while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
    test -n "$gname" || continue
    printf '%s\n' "$gname" >> "$SANDBOX/selected.txt"
  done < "$SANDBOX/groups.tsv"
}

# Writes selected/unselected in manifest order from a space-separated group set.
write_selection_set() {
  : > "$SANDBOX/selected.txt"
  : > "$SANDBOX/unselected.txt"
  while IFS='	' read -r gname desc_en desc_zh || test -n "$gname"; do
    test -n "$gname" || continue
    case " $1 " in
      *" $gname "*) printf '%s\n' "$gname" >> "$SANDBOX/selected.txt" ;;
      *) printf '%s\n' "$gname" >> "$SANDBOX/unselected.txt" ;;
    esac
  done < "$SANDBOX/groups.tsv"
}

resolve_selection() {
  test -n "$SANDBOX" || die lock_failed "$SANDBOX"
  test -f "$SANDBOX/groups.tsv" || die invalid_manifest groups_not_found

  case "$SELECTION_MODE" in
    none)
      if profile_groups=$(lookup_profile_groups 'default'); then
        write_selection_set "$profile_groups"
      else
        select_all_groups
      fi
      ;;
    all)
      select_all_groups
      ;;
    profile)
      test -n "$SELECTION_VALUE" || die missing_option_value '--profile'
      profile_groups=$(lookup_profile_groups "$SELECTION_VALUE") || die unknown_profile "$SELECTION_VALUE"
      write_selection_set "$profile_groups"
      ;;
    prompt)
      test -n "$SELECTION_VALUE" || die missing_option_value '--prompt'
      profile_groups=$(lookup_profile_groups 'default') || die no_default_profile
      is_prompt_group "$SELECTION_VALUE" || die unknown_prompt "$SELECTION_VALUE"

      selected_set="$SELECTION_VALUE"
      for gname in $profile_groups; do
        is_prompt_group "$gname" && continue
        selected_set="$selected_set $gname"
      done
      write_selection_set "$selected_set"
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

  if test -f "$SANDBOX/prompt_groups.txt" && test -s "$SANDBOX/prompt_groups.txt"; then
    prompt_sel_count=0
    while IFS= read -r sel || test -n "$sel"; do
      test -n "$sel" || continue
      while IFS= read -r pgrp || test -n "$pgrp"; do
        if test "$sel" = "$pgrp"; then
          prompt_sel_count=$((prompt_sel_count + 1))
          break
        fi
      done < "$SANDBOX/prompt_groups.txt"
    done < "$SANDBOX/selected.txt"
    test "$prompt_sel_count" -le 1 || die prompt_conflict
  fi
}
validate_custom_selections() {
  if test -n "$SELECTED_FONT"; then
    found_font=0
    if test -f "$SANDBOX/fonts.tsv"; then
      while IFS='	' read -r fcask ffamily || test -n "$fcask"; do
        if test "$fcask" = "$SELECTED_FONT"; then
          found_font=1
          break
        fi
      done < "$SANDBOX/fonts.tsv"
    fi
    test "$found_font" -eq 1 || die invalid_font "$SELECTED_FONT"
  fi

  if test -n "$SELECTED_BREW"; then
    cur="$SELECTED_BREW"
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
      test -n "$trimmed" || die invalid_brew '<empty>'
      found_brew=0
      if test -f "$SANDBOX/brew.tsv"; then
        while IFS='	' read -r bname bcask || test -n "$bname"; do
          if test "$bname" = "$trimmed"; then
            found_brew=1
            break
          fi
        done < "$SANDBOX/brew.tsv"
      fi
      test "$found_brew" -eq 1 || die invalid_brew "$trimmed"
      test "$has_more" -eq 0 && break
    done
  fi

  selected_features_file="$SANDBOX/selected_features.txt"
  : > "$selected_features_file"
  if test -n "$SELECTED_FEATURES"; then
    cur="$SELECTED_FEATURES"
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
      test -n "$trimmed" || die invalid_feature '<empty>'
      found_feature=0
      if test -f "$SANDBOX/features.tsv"; then
        while IFS='	' read -r fname fmacos fden fdzh || test -n "$fname"; do
          if test "$fname" = "$trimmed"; then
            found_feature=1
            break
          fi
        done < "$SANDBOX/features.tsv"
      fi
      test "$found_feature" -eq 1 || die invalid_feature "$trimmed"
      if ! /usr/bin/grep -F -x -q -e "$trimmed" "$selected_features_file" 2>/dev/null; then
        printf '%s\n' "$trimmed" >> "$selected_features_file"
      fi
      test "$has_more" -eq 0 && break
    done
  fi
}

stow_selected_packages() {
  test -f "$SANDBOX/selected.txt" || return 0
  test -s "$SANDBOX/selected.txt" || return 0

  pkgs=''
  while IFS= read -r pkg || test -n "$pkg"; do
    test -n "$pkg" || continue
    if test -z "$pkgs"; then
      pkgs="$pkg"
    else
      pkgs="$pkgs $pkg"
    fi
  done < "$SANDBOX/selected.txt"
  test -n "$pkgs" || return 0

  if test "$DRY_RUN" -eq 1; then
    printf 'Would stow packages: %s\n' "$pkgs"
    return 0
  fi

  # shellcheck disable=SC2086
  run_stow -d "$CHECKOUT_DIR" -t "$PHYSICAL_HOME" --dotfiles --no-folding $pkgs || die unsupported_stow 'stow execution failed'
}

write_font_override() {
  test -n "$SELECTED_FONT" || return 0

  font_family=''
  if test -f "$SANDBOX/fonts.tsv"; then
    while IFS='	' read -r fcask ffamily || test -n "$fcask"; do
      if test "$fcask" = "$SELECTED_FONT"; then
        font_family="$ffamily"
        break
      fi
    done < "$SANDBOX/fonts.tsv"
  fi
  test -n "$font_family" || die invalid_font "$SELECTED_FONT"

  if test "$DRY_RUN" -eq 1; then
    printf 'Would write font override %s/.config/ghostty/kaisian.conf: font-family = "%s"\n' "$PHYSICAL_HOME" "$font_family"
    return 0
  fi

  ghostty_dir="$PHYSICAL_HOME/.config/ghostty"
  /bin/mkdir -p "$ghostty_dir" 2>/dev/null || die invalid_targets "failed to create $ghostty_dir"
  font_conf="$ghostty_dir/kaisian.conf"
  /bin/rm -f "$font_conf" 2>/dev/null || true
  ( umask 022 && printf 'font-family = "%s"\n' "$font_family" > "$font_conf" ) || die invalid_targets "failed to write $font_conf"
  /bin/chmod 644 "$font_conf" 2>/dev/null || true
}

apply_feature_copies() {
  test -f "$SANDBOX/selected_features.txt" || return 0
  test -f "$SANDBOX/feature_copy.tsv" || return 0
  test -s "$SANDBOX/selected_features.txt" || return 0
  test -s "$SANDBOX/feature_copy.tsv" || return 0

  while IFS= read -r sel_feat || test -n "$sel_feat"; do
    test -n "$sel_feat" || continue
    while IFS='	' read -r fname fc_from fc_to || test -n "$fname"; do
      test "$fname" = "$sel_feat" || continue
      test -n "$fc_from" && test -n "$fc_to" || continue

      src_file="$CHECKOUT_DIR/$fc_from"
      dst_file="$PHYSICAL_HOME/$fc_to"

      if test "$DRY_RUN" -eq 1; then
        printf 'Would copy %s to %s\n' "$src_file" "$dst_file"
      else
        dst_dir="${dst_file%/*}"
        if test ! -d "$dst_dir"; then
          /bin/mkdir -p "$dst_dir" 2>/dev/null || die copy_failed "$fc_to" "failed to create directory"
        fi
        if test -L "$dst_file"; then
          /bin/rm -f "$dst_file" 2>/dev/null || true
        fi
        /bin/cp -f "$src_file" "$dst_file" 2>/dev/null || die copy_failed "$fc_to" "failed to copy file"
        test -f "$dst_file" && test ! -L "$dst_file" || die copy_failed "$fc_to" "destination is not a regular file"
        case "$fc_to" in
          .config/karabiner/*|.config/karabiner)
            /bin/chmod 600 "$dst_file" 2>/dev/null || die copy_failed "$fc_to" "failed to chmod"
            ;;
          *)
            /bin/chmod 644 "$dst_file" 2>/dev/null || die copy_failed "$fc_to" "failed to chmod"
            ;;
        esac
      fi
    done < "$SANDBOX/feature_copy.tsv"
  done < "$SANDBOX/selected_features.txt"
}

apply_feature_hotkeys() {
  test -f "$SANDBOX/selected_features.txt" || return 0
  test -f "$SANDBOX/feature_hotkeys.tsv" || return 0
  test -s "$SANDBOX/selected_features.txt" || return 0
  test -s "$SANDBOX/feature_hotkeys.tsv" || return 0

  defaults_bin='/usr/bin/defaults'
  if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_DEFAULTS_EXEC-}"; then
    defaults_bin="$KAISIAN_DEFAULTS_EXEC"
  elif test -n "${KAISIAN_DEFAULTS_EXEC-}"; then
    defaults_bin="$KAISIAN_DEFAULTS_EXEC"
  fi

  activate_settings_bin='/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings'
  if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_ACTIVATE_SETTINGS_EXEC-}"; then
    activate_settings_bin="$KAISIAN_ACTIVATE_SETTINGS_EXEC"
  elif test -n "${KAISIAN_ACTIVATE_SETTINGS_EXEC-}"; then
    activate_settings_bin="$KAISIAN_ACTIVATE_SETTINGS_EXEC"
  fi

  applied_any_hotkey=0
  existing_hotkeys=''
  read_existing=0

  while IFS= read -r sel_feat || test -n "$sel_feat"; do
    test -n "$sel_feat" || continue
    while IFS='	' read -r fname hk_id hk_enabled hk_ascii hk_keycode hk_modifiers || test -n "$fname"; do
      test "$fname" = "$sel_feat" || continue
      test -n "$hk_id" || continue

      applied_any_hotkey=1

      if test "$hk_enabled" -eq 1; then
        dict_val="{ enabled = 1; value = { type = standard; parameters = ( $hk_ascii, $hk_keycode, $hk_modifiers ); }; }"
      else
        if test -n "$hk_ascii" && test -n "$hk_keycode" && test -n "$hk_modifiers"; then
          dict_val="{ enabled = 0; value = { type = standard; parameters = ( $hk_ascii, $hk_keycode, $hk_modifiers ); }; }"
        else
          if test "$read_existing" -eq 0; then
            existing_hotkeys=$("$defaults_bin" read com.apple.symbolichotkeys AppleSymbolicHotKeys 2>/dev/null || true)
            read_existing=1
          fi

          existing_params=''
          if test -n "$existing_hotkeys"; then
            existing_params=$(printf '%s\n' "$existing_hotkeys" | /usr/bin/awk -v id="$hk_id" '
              $1 == id && $2 == "=" { in_id = 1; depth = 0; next }
              in_id {
                if ($0 ~ /\{/) depth++
                if ($0 ~ /parameters[[:space:]]*=/) in_params = 1
                if (in_params && $0 ~ /[0-9]+/) {
                  gsub(/[^0-9]/, "", $0)
                  if (length($0) > 0) params = (params ? params ", " : "") $0
                }
                if (in_params && $0 ~ /\)/) in_params = 0
                if ($0 ~ /\}/) {
                  depth--
                  if (depth <= 0) { in_id = 0 }
                }
              }
              END { print params }
            ')
          fi

          if test -n "$existing_params"; then
            dict_val="{ enabled = 0; value = { type = standard; parameters = ( $existing_params ); }; }"
          else
            dict_val="{ enabled = 0; }"
          fi
        fi
      fi

      if test "$DRY_RUN" -eq 1; then
        printf 'Would configure symbolic hotkey %s: %s\n' "$hk_id" "$dict_val"
      else
        "$defaults_bin" write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$hk_id" "$dict_val" 2>/dev/null || die hotkey_failed "$hk_id" "defaults write failed"
      fi
    done < "$SANDBOX/feature_hotkeys.tsv"
  done < "$SANDBOX/selected_features.txt"

  if test "$applied_any_hotkey" -eq 1 && test "$DRY_RUN" -eq 0; then
    if ! "$activate_settings_bin" -u 2>/dev/null; then
      warn_pfx=$(message warning_prefix 2>/dev/null) || warn_pfx='Warning'
      warn_msg=$(message activate_settings_failed 2>/dev/null) || warn_msg='Failed to activate settings. Please log out and log back in for hotkey changes to take effect.'
      printf '%s: %s\n' "$warn_pfx" "$warn_msg" >&2
    fi
  fi
}

generate_install_inputs() {
  test "$STOW_ONLY" -eq 0 || return 0

  if test -z "$RUN_TIMESTAMP"; then
    if test "${KAISIAN_TESTING-0}" = '1' && test -n "${KAISIAN_TEST_TIME-}"; then
      RUN_TIMESTAMP="$KAISIAN_TEST_TIME"
    else
      RUN_TIMESTAMP=$(/bin/date -u '+%Y%m%dT%H%M%SZ')
    fi
  fi

  run_dir="$STATE_ROOT/$RUN_TIMESTAMP"
  brewfile_path="$run_dir/Brewfile"
  mise_config_path="$run_dir/mise.toml"

  if test "$DRY_RUN" -eq 1; then
    printf 'Would generate %s and %s\n' "$brewfile_path" "$mise_config_path"
    return 0
  fi

  /bin/mkdir -p "$run_dir" 2>/dev/null || die invalid_targets "failed to create $run_dir"

  # 1. Brewfile
  : > "$brewfile_path"
  seen_emitted_brew=''
  # Font cask if selected
  if test -n "$SELECTED_FONT"; then
    printf 'cask "%s"\n' "$SELECTED_FONT" >> "$brewfile_path"
    seen_emitted_brew="$SELECTED_FONT"
  fi
  # Gather brew items: CLI selections + selected group dependencies
  all_brew_items=''

  # CLI selections
  if test -n "$SELECTED_BREW"; then
    cur="$SELECTED_BREW"
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
      if test -n "$trimmed"; then
        case " $all_brew_items " in
          *" $trimmed "*) ;;
          *)
            if test -z "$all_brew_items"; then
              all_brew_items="$trimmed"
            else
              all_brew_items="$all_brew_items $trimmed"
            fi
            ;;
        esac
      fi
      test "$has_more" -eq 0 && break
    done
  fi

  # Group brew dependencies for selected groups
  if test -f "$SANDBOX/group_brew_deps.tsv" && test -f "$SANDBOX/selected.txt"; then
    while IFS= read -r sel_grp || test -n "$sel_grp"; do
      test -n "$sel_grp" || continue
      while IFS='	' read -r dep_grp dep_pkg || test -n "$dep_grp"; do
        if test "$dep_grp" = "$sel_grp" && test -n "$dep_pkg"; then
          case " $all_brew_items " in
            *" $dep_pkg "*) ;;
            *)
              if test -z "$all_brew_items"; then
                all_brew_items="$dep_pkg"
              else
                all_brew_items="$all_brew_items $dep_pkg"
              fi
              ;;
          esac
        fi
      done < "$SANDBOX/group_brew_deps.tsv"
    done < "$SANDBOX/selected.txt"
  fi

  # Emit brew / cask lines
  for item in $all_brew_items; do
    case " $seen_emitted_brew " in
      *" $item "*) ;;
      *)
        seen_emitted_brew="$seen_emitted_brew $item"
        is_cask=0
        if test -f "$SANDBOX/brew.tsv"; then
          while IFS='	' read -r bname bcask || test -n "$bname"; do
            if test "$bname" = "$item"; then
              test "$bcask" = '1' && is_cask=1
              break
            fi
          done < "$SANDBOX/brew.tsv"
        fi
        if test "$is_cask" -eq 1; then
          printf 'cask "%s"\n' "$item" >> "$brewfile_path"
        else
          printf 'brew "%s"\n' "$item" >> "$brewfile_path"
        fi
        ;;
    esac
  done

  # Feature brew dependencies
  if test -f "$SANDBOX/feature_brew.tsv" && test -f "$SANDBOX/selected_features.txt"; then
    while IFS= read -r sel_feat || test -n "$sel_feat"; do
      test -n "$sel_feat" || continue
      while IFS='	' read -r ffeat fpkg fcask || test -n "$ffeat"; do
        if test "$ffeat" = "$sel_feat" && test -n "$fpkg"; then
          case " $seen_emitted_brew " in
            *" $fpkg "*) ;;
            *)
              seen_emitted_brew="$seen_emitted_brew $fpkg"
              if test "$fcask" = '1'; then
                printf 'cask "%s"\n' "$fpkg" >> "$brewfile_path"
              else
                printf 'brew "%s"\n' "$fpkg" >> "$brewfile_path"
              fi
              ;;
          esac
        fi
      done < "$SANDBOX/feature_brew.tsv"
    done < "$SANDBOX/selected_features.txt"
  fi
  /bin/chmod 644 "$brewfile_path" 2>/dev/null || true

  # 2. mise.toml
  printf '[tools]\n' > "$mise_config_path"
  seen_mise_tools=''
  if test -n "$SELECTED_LANGS"; then
    cur="$SELECTED_LANGS"
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
      if test -n "$trimmed"; then
        if test "$trimmed" = 'elixir'; then
          case " $seen_mise_tools " in
            *" erlang "*) ;;
            *)
              seen_mise_tools="$seen_mise_tools erlang"
              printf 'erlang = "latest"\n' >> "$mise_config_path"
              ;;
          esac
          case " $seen_mise_tools " in
            *" elixir "*) ;;
            *)
              seen_mise_tools="$seen_mise_tools elixir"
              printf 'elixir = "latest"\n' >> "$mise_config_path"
              ;;
          esac
        else
          case " $seen_mise_tools " in
            *" $trimmed "*) ;;
            *)
              seen_mise_tools="$seen_mise_tools $trimmed"
              printf '%s = "latest"\n' "$trimmed" >> "$mise_config_path"
              ;;
          esac
        fi
      fi
      test "$has_more" -eq 0 && break
    done
  fi
  MISE_TOOLS="${seen_mise_tools# }"
  /bin/chmod 644 "$mise_config_path" 2>/dev/null || true
}

install_packages() {
  test "$STOW_ONLY" -eq 0 || return 0

  brewfile_path="$STATE_ROOT/$RUN_TIMESTAMP/Brewfile"

  if test "$DRY_RUN" -eq 1; then
    printf 'Would run brew bundle --file=%s\n' "$brewfile_path"
    return 0
  fi

  test -s "$brewfile_path" || return 0
  test -n "$BREW_EXEC" || die bootstrap_failed 'Homebrew is required to install packages'
  "$BREW_EXEC" bundle --file="$brewfile_path" || die brew_bundle_failed "$?"
}

install_languages() {
  test "$STOW_ONLY" -eq 0 || return 0

  mise_config_path="$STATE_ROOT/$RUN_TIMESTAMP/mise.toml"
  mise_conf_dir="$PHYSICAL_HOME/.config/mise/conf.d"
  mise_conf="$mise_conf_dir/kaisian.toml"

  if test "$DRY_RUN" -eq 1; then
    printf 'Would install %s and run mise install\n' "$mise_conf"
    return 0
  fi

  MISE_EXEC=$(get_tool_exec mise) || true
  if test -z "$MISE_EXEC"; then
    test -n "$BREW_EXEC" || die bootstrap_failed 'Homebrew is required to install: mise'
    "$BREW_EXEC" install mise || die bootstrap_failed 'brew install mise failed'
    # An empty override means "absent"; after installing, discover normally.
    if test "${KAISIAN_MISE_EXEC+x}" = 'x' && test -z "$KAISIAN_MISE_EXEC"; then
      unset KAISIAN_MISE_EXEC
    fi
    MISE_EXEC=$(get_tool_exec mise) || die bootstrap_failed 'mise executable not found after installation'
  fi

  if test -n "$MISE_TOOLS"; then
    nl=$(printf '\n.')
    nl=${nl%.}
    registry="$nl$("$MISE_EXEC" registry 2>/dev/null | /usr/bin/awk 'NF {print $1}')$nl"
    unknown_tools=''
    for tool in $MISE_TOOLS; do
      case "$registry" in
        *"$nl$tool$nl"*) ;;
        *) unknown_tools="$unknown_tools $tool" ;;
      esac
    done
    test -z "$unknown_tools" || die unknown_mise_tools "${unknown_tools# }"
  fi

  /bin/mkdir -p "$mise_conf_dir" 2>/dev/null || die invalid_targets "failed to create $mise_conf_dir"
  /bin/cp "$mise_config_path" "$mise_conf" || die invalid_targets "failed to write $mise_conf"
  /bin/chmod 644 "$mise_conf" 2>/dev/null || true

  test -n "$MISE_TOOLS" || return 0
  "$MISE_EXEC" install || die mise_install_failed "$?"
}

print_feature_notes() {
  test -f "$SANDBOX/selected_features.txt" || return 0
  test -f "$SANDBOX/feature_notes.tsv" || return 0
  test -s "$SANDBOX/selected_features.txt" || return 0
  test -s "$SANDBOX/feature_notes.tsv" || return 0

  while IFS= read -r sel_feat || test -n "$sel_feat"; do
    test -n "$sel_feat" || continue
    while IFS='	' read -r fname notes_en notes_zh || test -n "$fname"; do
      test "$fname" = "$sel_feat" || continue
      case "$LANGUAGE" in
        zh-TW|zh_TW)
          if test -n "$notes_zh"; then
            printf '%s\n' "$notes_zh"
          fi
          ;;
        *)
          if test -n "$notes_en"; then
            printf '%s\n' "$notes_en"
          fi
          ;;
      esac
    done < "$SANDBOX/feature_notes.tsv"
  done < "$SANDBOX/selected_features.txt"
}

main() {
  resolve_language ''
  parse_args "$@"
  validate_home
  acquire_lock
  require_prerequisites

  if test -z "$CHECKOUT_DIR"; then
    CHECKOUT_DIR="$PHYSICAL_HOME/.dotfiles"
  fi

  CANONICAL_REPO=$(canonicalize_repository "$REPOSITORY") || exit 1
  resolve_remote_ref

  if test -e "$CHECKOUT_DIR" || test -L "$CHECKOUT_DIR"; then
    test -d "$CHECKOUT_DIR" && test ! -L "$CHECKOUT_DIR" || die invalid_git_admin "checkout directory is not a real directory: $CHECKOUT_DIR"
    test -d "$CHECKOUT_DIR/.git" && test ! -L "$CHECKOUT_DIR/.git" || die invalid_git_admin "existing checkout directory is not a git repository: $CHECKOUT_DIR"
    update_repository "$CHECKOUT_DIR"
  else
    initialize_repository "$CHECKOUT_DIR"
  fi

  parse_manifest "$CHECKOUT_DIR/.kaisian.json" "$CHECKOUT_DIR"
  resolve_selection
  validate_custom_selections
  build_package_map || die invalid_package_tree
  validate_typed_tree || die invalid_package_tree
  preflight_targets || die invalid_targets
  confirm_conflicts || exit 1
  test "${CONFIRMED-0}" -eq 1 || return 0
  move_conflicts || exit 1
  stow_selected_packages
  write_font_override
  apply_feature_copies
  apply_feature_hotkeys
  generate_install_inputs
  install_packages
  install_languages
  print_feature_notes
  return 0
}
if test "${KAISIAN_TESTING-0}" != 1; then
  main "$@"
fi
