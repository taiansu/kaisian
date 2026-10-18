#!/bin/bash
# Runs as root inside ubuntu:24.04 (started by tests/wsl_test.sh). The kernel release
# file is faked so setup.sh takes its WSL path; Homebrew and mise are the fixture fakes.
set -u

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

apt-get -qq update >/dev/null || exit 1
apt-get -qq install -y sudo ca-certificates make perl >/dev/null 2>&1 || exit 1
# Homebrew ships Stow 2.4; Ubuntu's 2.3.1 fails setup.sh's --dotfiles probe.
mkdir -p /tmp/stow-src
tar -xzf /work/stow.tar.gz -C /tmp/stow-src --strip-components=1 || exit 1
(cd /tmp/stow-src && ./configure --prefix=/usr/local >/dev/null 2>&1 && make install >/dev/null 2>&1) || exit 1
useradd -m -s /bin/bash tai || exit 1
echo 'tai ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tai
echo '5.15.167.4-microsoft-standard-WSL2' > /tmp/osrelease
chmod 644 /tmp/osrelease

as_wsl_user() {
  sudo -u tai -H env \
    KAISIAN_OSRELEASE_FILE=/tmp/osrelease \
    KAISIAN_BREW_EXEC=/repo/tests/fixtures/fake-brew \
    KAISIAN_BREW_LOG=/tmp/brew.log \
    KAISIAN_MISE_EXEC=/repo/tests/fixtures/fake-mise \
    PATH=/usr/local/bin:/usr/bin:/bin \
    bash /repo/setup.sh "$@"
}

apt_installed() {
  test "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = 'installed'
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) printf 'expected output to contain: %s\n--- output ---\n%s\n' "$2" "$1" >&2; return 1 ;;
  esac
}

non_wsl_linux_is_rejected() {
  out=$(sudo -u tai -H bash /repo/setup.sh --yes --dry-run 2>&1) && return 1
  contains "$out" 'requires macOS or WSL'
}

root_is_rejected() {
  out=$(env KAISIAN_OSRELEASE_FILE=/tmp/osrelease HOME=/root bash /repo/setup.sh --yes --dry-run 2>&1) && return 1
  contains "$out" 'not root'
}

font_flag_is_rejected() {
  out=$(as_wsl_user --yes --font font-sauce-code-pro-nerd-font 2>&1) && return 1
  contains "$out" 'setup.ps1 installs the font'
}

dry_run_on_fresh_ubuntu_installs_nothing() {
  out=$(as_wsl_user --yes --dry-run 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  contains "$out" 'Would bootstrap: sudo apt-get install -y' || return 1
  contains "$out" 'jq zsh' || return 1
  contains "$out" 'Stopping the dry run here' || return 1
  ! apt_installed jq && ! apt_installed zsh
}

full_run_bootstraps_wsl_and_stows_dotfiles() {
  out=$(as_wsl_user --yes --prompt prompt-pure --brew ripgrep --langs python 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  for pkg in build-essential procps curl file git jq zsh; do
    apt_installed "$pkg" || { printf 'apt package %s missing\n' "$pkg" >&2; return 1; }
  done
  test "$(getent passwd tai | cut -d: -f7)" = '/usr/bin/zsh' || { echo 'login shell is not zsh' >&2; return 1; }
  test -L /home/tai/.zshrc || { echo '~/.zshrc was not stowed' >&2; return 1; }
  brewfile=$(cat /home/tai/.local/state/kaisian/*/Brewfile)
  contains "$brewfile" 'brew "ripgrep"' || return 1
  case "$brewfile" in *cask*) printf 'Brewfile contains casks:\n%s\n' "$brewfile" >&2; return 1 ;; esac
  contains "$(cat /tmp/brew.log)" 'bundle --file='
}

macos_only_selections_are_rejected() {
  out=$(as_wsl_user --yes --brew ghostty 2>&1) && return 1
  contains "$out" "cask 'ghostty' is macOS-only" || return 1
  out=$(as_wsl_user --yes --features karabiner-ime 2>&1) && return 1
  contains "$out" "Feature 'karabiner-ime' is macOS-only"
}

rerun_skips_apt_and_chsh() {
  out=$(as_wsl_user --yes --prompt prompt-pure --langs python 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  case "$out" in
    *'Installing missing tools'*|*'Default login shell'*) printf 'rerun repeated bootstrap:\n%s\n' "$out" >&2; return 1 ;;
  esac
  return 0
}

# plutil_compat must answer every recorded plutil query the same way, modulo
# formatting validation never sees: JSON key order/escaping and dictionary key order.
plutil_compat_matches_plutil() {
  (
    export KAISIAN_TESTING=1
    . /repo/setup.sh
    PLATFORM='wsl'
    JQ_EXEC=/usr/bin/jq
    cd /work || exit 1
    total=$(jq length plutil.json)
    diffs=0
    i=0
    while test "$i" -lt "$total"; do
      mapfile -t args < <(jq -r ".[$i].args[]" plutil.json)
      want_rc=$(jq -r ".[$i].rc" plutil.json)
      want=$(jq -r ".[$i].out" plutil.json)
      got=$(plutil_compat "${args[@]}" 2>/dev/null)
      got_rc=$?
      test "$got_rc" -eq 0 || { got_rc=1; got=''; }
      case " ${args[*]} " in
        *' json -o - '*)
          # plutil cannot print scalars as JSON; validation only extracts containers.
          if test "$want_rc" = 1; then i=$((i + 1)); continue; fi
          want=$(printf '%s' "$want" | jq -cS .)
          got=$(printf '%s' "$got" | jq -cS . 2>/dev/null)
          ;;
        *' raw '*)
          want=$(printf '%s\n' "$want" | sort)
          got=$(printf '%s\n' "$got" | sort)
          ;;
      esac
      if test "$got_rc" != "$want_rc" || test "$got" != "$want"; then
        diffs=$((diffs + 1))
        printf 'plutil %s -> rc=%s [%s]; plutil_compat -> rc=%s [%s]\n' "${args[*]}" "$want_rc" "$want" "$got_rc" "$got" >&2
      fi
      i=$((i + 1))
    done
    test "$diffs" -eq 0
  )
}

run_case 'non-WSL Linux is rejected' non_wsl_linux_is_rejected
run_case 'root is rejected in WSL' root_is_rejected
run_case '--font is rejected in WSL' font_flag_is_rejected
run_case 'dry run on fresh Ubuntu previews apt and installs nothing' dry_run_on_fresh_ubuntu_installs_nothing
run_case 'full run installs apt packages, sets zsh, stows dotfiles, writes a cask-free Brewfile' full_run_bootstraps_wsl_and_stows_dotfiles
run_case 'macOS-only casks and features are rejected in WSL' macos_only_selections_are_rejected
run_case 'rerun skips apt install and chsh' rerun_skips_apt_and_chsh
run_case 'plutil_compat matches plutil on recorded manifest queries' plutil_compat_matches_plutil
printf '%s passed; %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
