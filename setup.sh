#!/bin/bash
set -u

readonly KAISIAN_VERSION='0.1.0'
readonly DEFAULT_REPOSITORY='taiansu/dotfiles'
readonly DEFAULT_DOTFILES_COMMIT='0b3b0c3f206e1f4fb35dac82794a871c5c18f405'

usage() {
  cat <<'USAGE'
setup.sh [OPTIONS]

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
  -h, --help
USAGE
}

main() {
  case ${1-} in
    -h|--help) usage; return 0 ;;
  esac
  printf '%s\n' 'Kaisian is not configured yet.' >&2
  return 1
}

if test "${KAISIAN_TESTING-0}" != 1; then
  main "$@"
fi
