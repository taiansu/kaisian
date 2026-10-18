# kaisian

A setup entry point for macOS and for Windows 11 with WSL: choose dotfile groups, a
terminal font, Homebrew tools, and programming languages at **https://kaisian.phx.tw**,
then run one command.

```sh
curl -fsSL https://kaisian.phx.tw | bash -s -- --yes --prompt prompt-pure --font font-sauce-code-pro-nerd-font --brew ripgrep,fzf --langs python,node --lang en
```

Review `setup.sh` before running it. kaisian bootstraps Homebrew, git, and stow,
clones the dotfiles repository, backs up conflicting files, and stows the selected
groups into your home directory. It writes a Ghostty font override, then installs
the selected Homebrew packages with `brew bundle` and the selected languages with
mise. Homebrew, git, stow, and mise are always included,
not selectable tools. Homebrew installation may require a sudo password.

## Windows 11 and WSL

Run the command from the page's Windows tab in PowerShell (Windows PowerShell 5.1
or PowerShell 7):

```powershell
& ([scriptblock]::Create((irm https://kaisian.phx.tw/win))) -NerdFont SourceCodePro -FontFamily 'SauceCodePro NFM' -- --yes --brew 'ripgrep,fzf' --langs 'python,node' --lang en
```

`setup.ps1` prepares Windows, then runs `setup.sh` inside WSL with every argument
after `--`; quote comma lists, since PowerShell turns bare `a,b` into an array.
Review both scripts before running them. In order, `setup.ps1`:

1. Requires Windows 11 (build 22000 or later).
2. Installs WSL with the distribution if either is missing (`wsl --install`, with an
   administrator prompt), then stops: restart if asked, open the distribution once to
   create your Linux user, and run the same command again.
3. Downloads `<NerdFont>.zip` from the latest Nerd Fonts release and installs its
   `*NerdFontMono-*` files for the current user, unless `-FontFamily` is installed.
4. Installs Windows Terminal with winget if it is missing.
5. Writes the JSON fragment
   `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\kaisian\kaisian.json`, which
   sets the distribution profile's `font.face`; `settings.json` is never edited.
6. Makes Windows Terminal the default terminal application
   (`HKCU\Console\%%Startup`).
7. Runs `setup.sh` in WSL and stops on failure.
8. Upgrades a Windows Terminal that was already installed. This runs last because
   the upgrade can close the window running the script.

| Parameter | Purpose |
| --- | --- |
| `-NerdFont NAME` | Nerd Fonts release asset name (ASCII letters and digits); requires `-FontFamily`. |
| `-FontFamily NAME` | Font family for the Windows Terminal profile; requires `-NerdFont`. |
| `-SkipTerminalUpgrade` | Do not upgrade an already installed Windows Terminal. |
| `-KeepDefaultTerminal` | Do not change the default terminal application. |
| `-Distro NAME` | WSL distribution to install and use; defaults to `Ubuntu`. |

`setup.ps1` reads `--lang` and `--dry-run` from the forwarded arguments; a dry run
reports the Windows steps without performing them and still forwards `--dry-run`.
The script sets `$LASTEXITCODE` instead of calling `exit`, so failures keep the
window open. `KAISIAN_SETUP_URL` overrides the `setup.sh` source.

Inside WSL, `setup.sh` takes the same options with these differences:

- Run it as your regular user, not root. Missing `build-essential procps curl file
  git jq zsh` packages are installed with `sudo apt-get`, then Homebrew on Linux at
  `/home/linuxbrew/.linuxbrew`; GNU Stow comes from Homebrew because Ubuntu's 2.3.1
  fails the `--dotfiles` probe.
- After installation, `chsh` makes `/usr/bin/zsh` the login shell; new WSL sessions
  use it.
- `--font` is rejected; the font belongs to `setup.ps1`. Casks and `macos: true`
  features are rejected when selected and skipped when a group pulls them in.
- The manifest is parsed with jq in place of `plutil`. A dry run on a system
  without jq previews the apt step and stops there.

## Options

| Flag | Purpose |
| --- | --- |
| `--prompt NAME` | Use the default profile with its prompt group swapped for `NAME`. |
| `--groups NAME[,NAME...]` | Select stow groups exactly; at most one `kind: "prompt"` group. |
| `--profile NAME` | Select a named profile. Without any selection flag the `default` profile is used (every group if the manifest has none). |
| `--interactive` | Select groups with fzf, if installed; optional terminal-only mode. |
| `--all` | Select every group; still subject to the one-prompt limit. |
| `--font CASK` | Select a cask from the manifest's `fonts` array. |
| `--brew NAME[,NAME...]` | Select catalog entries or add official Homebrew formula/cask names. Extra names are verified and classified by Homebrew before dotfiles are applied. |
| `--langs LANG[,LANG...]` | Select tools to install via mise (e.g. `python,node` or any tool in the mise registry); Elixir also installs Erlang. |
| `--features NAME[,NAME...]` | Select features from the manifest's `features` array. |
| `--stow-only` | Bootstrap and stow, and write the font override, but do not install packages or languages. |
| `--dry-run` | Preview changes, bootstrap requirements, and generated inputs without installing anything. |
| `--lang en\|zh-TW` | Set the installer language. |
| `--repo URL\|OWNER/REPO[/tree/REF]` | Use another dotfiles source; requires a ref via `/tree/REF` or `--ref`. |
| `--ref REF` | Choose a repository reference; defaults to the `kaisian` branch of `taiansu/dotfiles`. |
| `--dir PATH` | Set the local checkout directory. |
| `--yes` | Auto-confirm conflict backups; required for `curl \| bash` since stdin is the script. |
| `-h`, `--help` | Show usage. |

Selection flags (`--prompt`, `--groups`, `--profile`, `--interactive`, `--all`) are
mutually exclusive. Optional font, brew, and language selections default to empty in
the CLI. mise is installed even with empty selections.
The web generator omits the selection flag when the chosen prompt is the default
profile's prompt and emits `--prompt NAME` otherwise.

The selected font writes `~/.config/ghostty/kaisian.conf` with `font-family = ""`
followed by `font-family = "<family>"`: Ghostty loads `config-file` includes after
the main file and treats repeated `font-family` as fallbacks, so the reset makes the
chosen font primary. Your stowed Ghostty configuration should include
`config-file = ?~/.config/ghostty/kaisian.conf`; put CJK or emoji fallbacks in a
second include listed after it. Generated inputs are stored under the installer's
state directory at `<run-timestamp>/{Brewfile,mise.toml}`. Catalog Homebrew
entries use their manifest type; additional `--brew` names must use lowercase
Homebrew package syntax without third-party tap paths (`/`). Before moving
conflicts or applying dotfiles, the installer asks Homebrew to verify each
additional name and classify it as a formula or cask, then writes the complete
Brewfile and installs it with `brew bundle`. The mise configuration is copied
to `~/.config/mise/conf.d/kaisian.toml` and applied with `mise install` after
tool name is checked against the mise registry. Shell rc files are never edited;
shell integration belongs to your dotfiles.

For local testing, `KAISIAN_MISE_EXEC` selects a replacement mise executable,
`KAISIAN_BREW_EXEC` selects a replacement brew executable,
`KAISIAN_BREW_INSTALLER` replaces the Homebrew installer command,
`KAISIAN_DEFAULTS_EXEC` replaces defaults,
`KAISIAN_ACTIVATE_SETTINGS_EXEC` replaces activateSettings,
`KAISIAN_JQ_EXEC` replaces jq, `KAISIAN_SUDO_EXEC` replaces sudo,
`KAISIAN_DPKG_QUERY_EXEC` replaces dpkg-query, and `KAISIAN_OSRELEASE_FILE`
replaces `/proc/sys/kernel/osrelease` for WSL detection.

Tests: `bash tests/setup_test.sh` runs on macOS. `bash tests/wsl_test.sh` runs the
WSL path in an Ubuntu container and checks the jq-based manifest parser against
`plutil`; it needs macOS, Docker, and network access. `tests/setup.Tests.ps1` is a
Pester 5 suite for `setup.ps1` that mocks every Windows operation, so it also runs
under PowerShell 7 on Linux or macOS.

## Dotfiles manifest

Place `.kaisian.json` at the dotfiles repository root. A group name is the name
of its top-level stow package directory.

```json
{
  "schema": 2,
  "groups": [
    {"name": "home", "description": {"en": "Core dotfiles", "zh-TW": "基本設定檔"}},
    {"name": "prompt-default", "kind": "prompt", "description": {"en": "Default prompt", "zh-TW": "預設提示字元"}},
    {"name": "prompt-pure", "kind": "prompt", "brew": ["gitstatus"], "description": {"en": "Pure prompt", "zh-TW": "Pure 提示字元"}}
  ],
  "profiles": {"default": ["home", "prompt-default"]},
  "fonts": [
    {"cask": "font-sauce-code-pro-nerd-font", "family": "SauceCodePro NFM", "nerd_font": "SourceCodePro", "description": {"en": "Source Code Pro", "zh-TW": "Source Code Pro 字型"}}
  ],
  "brew": [
    {"name": "ripgrep", "description": {"en": "Fast search", "zh-TW": "快速搜尋"}},
    {"name": "gitstatus", "description": {"en": "Async git status daemon", "zh-TW": "非同步 git 狀態 daemon"}},
    {"name": "ghostty", "cask": true, "description": {"en": "Terminal", "zh-TW": "終端機"}}
  ],
  "features": [
    {
      "name": "karabiner-ime",
      "macos": true,
      "brew": [{"name": "karabiner-elements", "cask": true}],
      "copy": [{"from": "home/dot-config/karabiner/karabiner.json", "to": ".config/karabiner/karabiner.json"}],
      "hotkeys": [
        {"id": 60, "enabled": true, "ascii": 32, "keycode": 49, "modifiers": 1310720},
        {"id": 61, "enabled": false}
      ],
      "description": {"en": "Caps Lock as IME switch", "zh-TW": "Caps Lock 當輸入法切換鍵"},
      "notes": {"en": "Approve driver in System Settings.", "zh-TW": "在系統設定核准驅動程式延伸功能。"}
    }
  ]
}
```

Names must match ASCII `[A-Za-z0-9._@+-]+` (no `/`). Groups may declare an optional
`brew` array of tool names required by that group (each matching an entry in the
top-level `brew` array); selecting the group automatically includes those tools in
the installation. `kind` is optional; its only valid value is `prompt`. `fonts` and
`brew` are optional arrays. A font's optional `nerd_font` names its Nerd Fonts release
asset (ASCII letters and digits, e.g. `IBMPlexMono` for Blex Mono); the Windows tab
only offers fonts that have one. A brew entry's `cask` defaults to `false`. `features` is
an optional array of opt-in macOS tweaks and configuration file copies. Each feature
has a `name`, required `description`, and optional `macos` (boolean), `brew` (inline
tool objects with optional `cask`), `copy` (array of `{from, to}` relative file paths
where `from` is relative to the repository checkout and `to` is relative to `$HOME`),
`hotkeys` (array of `{id, enabled, ascii?, keycode?, modifiers?}` symbolic hotkey
entries), and `notes` (localized post-install guidance). Schema 1 manifests without
`kind`, `fonts`, `brew`, or `features` remain supported. Do not list Homebrew, git,
stow, or mise as optional tools.

## Web page and deployment

The single-file page uses no framework or build step. In production it fetches
the manifest from the dotfiles repository's **kaisian branch**; change
`REMOTE_MANIFEST_URL` at the top of the script in `web/index.html` when that
layout is published elsewhere. The installer source and selected dotfiles ref
must also contain the matching manifest and package layout before generated
commands can be used end to end.

Local preview (Python 3):

```sh
python3 -m http.server 8765 --directory web
```

Open `http://localhost:8765/`. On localhost the page loads
`fixtures/manifest.json` without browser caching; keep that fixture identical to
the canonical `.kaisian.json` in the dotfiles repository. `?manifest=<url>` can
point to another manifest (cross-origin URLs need CORS). English / Traditional
Chinese selection is remembered locally, and so is the macOS / Windows platform
switch, which first follows the browser's OS; `?platform=mac` or
`?platform=windows` forces it. The page defaults to the default
profile, the first font, every optional Homebrew tool, Python, and Node. Custom
Homebrew and mise names are validated against the installer's format rules;
invalid input disables command copying. Homebrew performs authoritative
existence and formula/cask classification during installer preflight. Empty
flags are omitted, and the copy button has a manual-copy fallback. The Windows
command passes the font to `setup.ps1`, omits casks and macOS-only features, and
single-quotes every value PowerShell would otherwise reinterpret.

Deploy to Cloudflare Workers with Wrangler:

```sh
bun x wrangler login
bun x wrangler dev
bun x wrangler deploy
```

`wrangler.jsonc` imports HTML as text and declares `kaisian.phx.tw` as a Workers
Custom Domain. `wrangler deploy` deploys the Worker and binds that domain; the
logged-in Cloudflare account must own the `phx.tw` zone.
Requests for `/win` receive a 302 redirect to
`https://raw.githubusercontent.com/taiansu/kaisian/main/setup.ps1`. Other browser
requests whose `Accept` header includes `text/html` receive the page; the rest
receive a 302 redirect to
`https://raw.githubusercontent.com/taiansu/kaisian/main/setup.sh`.
The local fixture is for the Python preview and is not served by the Worker.
For `wrangler dev`, override the local default with
`?manifest=https://raw.githubusercontent.com/taiansu/dotfiles/kaisian/.kaisian.json`.
Local Wrangler build artifacts and caches under `.wrangler/` are git-ignored.
