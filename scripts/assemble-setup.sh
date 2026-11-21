#!/bin/bash
# Refresh the embedded planner without duplicating the installer's Bash source.
set -eu
cd "$(dirname "$0")/.."
case "${1-}" in ''|--check) ;; *) printf 'Usage: %s [--check]\n' "$0" >&2; exit 2 ;; esac

# Print the complete result before opening setup.sh for writing. --check only compares.
assemble() {
  /usr/bin/awk '
    /^\/\/ BEGIN generated planner$/ {
      if (begun++) exit 1
      print
      for (i = 1; i <= 3; ++i) {
        path = "installer/" (i == 1 ? "manifest" : i == 2 ? "selection" : "run") ".js"
        while ((n = (getline line < path)) > 0) {
          if (line == "KAISIAN_PLANNER_JS") exit 1
          print line
        }
        if (n < 0) exit 1
        close(path)
      }
      next
    }
    /^\/\/ END generated planner$/ { if (!begun || ended++) exit 1 }
    !begun || ended { print }
    END { if (begun != 1 || ended != 1) exit 1 }
  ' setup.sh
}
if test "${1-}" = --check; then
  set -o pipefail
  assemble | cmp - setup.sh || { printf 'Regenerate setup.sh with bash scripts/assemble-setup.sh\n' >&2; exit 1; }
else
  result=$(assemble) || exit 1
  printf '%s\n' "$result" > setup.sh
fi
