# kaisian

A macOS setup entry point: choose dotfile groups, a terminal font, Homebrew tools,
and programming languages at **https://kaisian.phx.tw**, then run one command.

```sh
curl -fsSL https://kaisian.phx.tw | bash -s -- --yes --prompt prompt-pure --font font-sauce-code-pro-nerd-font --brew ripgrep,fzf --langs python,node --lang en
```

Review `setup.sh` before running it. kaisian bootstraps Homebrew, git, and stow,
clones the dotfiles repository, backs up conflicting files, and stows the selected
groups into your home directory. It writes a Ghostty font override, generates a
Brewfile and mise configuration, then hands them to [tsunpi](https://tsunpi.phx.tw)
for non-interactive installation. Homebrew, git, stow, and mise are always included,
not selectable tools. Homebrew installation may require a sudo password.

## Options

| Flag | Purpose |
| --- | --- |
| `--prompt NAME` | Use the default profile with its prompt group swapped for `NAME`. |
| `--groups NAME[,NAME...]` | Select stow groups exactly; at most one `kind: "prompt"` group. |
| `--profile NAME` | Select a named profile. Without any selection flag the `default` profile is used (every group if the manifest has none). |
| `--interactive` | Select groups with fzf, if installed; optional terminal-only mode. |
| `--all` | Select every group; still subject to the one-prompt limit. |
| `--font CASK` | Select a cask from the manifest's `fonts` array. |
| `--brew NAME[,NAME...]` | Select names from the manifest's `brew` array. |
| `--langs LANG[,LANG...]` | Select tools to install via mise (e.g. `python,node` or any tool in the mise registry); Elixir also installs Erlang. |
| `--features NAME[,NAME...]` | Select features from the manifest's `features` array. |
| `--no-tsunpi` | Bootstrap and stow, and write the font override, but do not generate or run tsunpi inputs. |
| `--dry-run` | Preview changes, bootstrap requirements, and generated inputs without installing or running tsunpi. |
| `--lang en\|zh-TW` | Set the installer language. |
| `--repo URL\|OWNER/REPO[/tree/REF]` | Use another dotfiles source; requires a ref via `/tree/REF` or `--ref`. |
| `--ref REF` | Choose a repository reference; defaults to the `kaisian` branch of `taiansu/dotfiles`. |
| `--dir PATH` | Set the local checkout directory. |
| `--yes` | Auto-confirm conflict backups; required for `curl \| bash` since stdin is the script. |
| `-h`, `--help` | Show usage. |

Selection flags (`--prompt`, `--groups`, `--profile`, `--interactive`, `--all`) are
mutually exclusive. Optional font, brew, and language selections default to empty in
the CLI. tsunpi still runs with empty selections to ensure mise is installed.
The web generator omits the selection flag when the chosen prompt is the default
profile's prompt and emits `--prompt NAME` otherwise.

The selected font writes `~/.config/ghostty/kaisian.conf` with
`font-family = "<family>"`. Your stowed Ghostty configuration should include
`config-file = ?~/.config/ghostty/kaisian.conf`. Generated inputs are stored under the installer's
state directory at `<run-timestamp>/tsunpi/{Brewfile,mise.toml}`. tsunpi receives
`--brewfile`, `--mise-config`, `--no-rc`, and the chosen locale, keeping shell
integration in your dotfiles rather than editing rc files.

For local testing, `KAISIAN_TSUNPI_EXEC` selects a replacement tsunpi executable,
`KAISIAN_BREW_EXEC` selects a replacement brew executable,
`KAISIAN_BREW_INSTALLER` replaces the Homebrew installer command,
`KAISIAN_DEFAULTS_EXEC` replaces defaults, and
`KAISIAN_ACTIVATE_SETTINGS_EXEC` replaces activateSettings.
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
    {"cask": "font-sauce-code-pro-nerd-font", "family": "SauceCodePro NFM", "description": {"en": "Source Code Pro", "zh-TW": "Source Code Pro 字型"}}
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
      "copy": [{"from": "karabiner/default.json", "to": ".config/karabiner/karabiner.json"}],
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
`brew` are optional arrays. A brew entry's `cask` defaults to `false`. `features` is
an optional array of opt-in macOS tweaks and configuration file copies. Each feature
has a `name`, required `description`, and optional `macos` (boolean), `brew` (inline
tool objects with optional `cask`), `copy` (array of `{from, to}` relative file paths
where `from` is relative to the repository checkout and `to` is relative to `$HOME`),
`hotkeys` (array of `{id, enabled, ascii?, keycode?, modifiers?}` symbolic hotkey
entries), and `notes` (localized post-install guidance). Schema 1 manifests without
`kind`, `fonts`, `brew`, or `features` remain supported. Do not list Homebrew, git,
stow, or mise as optional tools.

## Web page and deployment

The single-file page uses no framework or build step. It fetches the manifest
from the dotfiles repository's **kaisian branch**; change `MANIFEST_URL` at the
top of the script in `web/index.html` when that layout is published elsewhere.
The installer source and pinned dotfiles revision must also contain the matching
manifest and package layout before generated commands can be used end to end.

Local preview (Python 3):

```sh
python3 -m http.server 8765 --directory web
```

Open `http://localhost:8765/?manifest=fixtures/manifest.json`. The fixture includes
three fonts and eight optional tools; `?manifest=<url>` can point to another
manifest (cross-origin URLs need CORS). English / Traditional Chinese selection
is remembered locally. The page defaults to the default profile and
Python/Elixir/Node, omits empty flags, and offers a copy button with a manual-copy
fallback.

Deploy to Cloudflare Workers with Wrangler:

```sh
bun x wrangler login
bun x wrangler dev
bun x wrangler deploy
```

`wrangler.jsonc` imports HTML as text. Browser requests whose `Accept` header
includes `text/html` receive the page; other requests receive a 302 redirect to
`https://raw.githubusercontent.com/taiansu/kaisian/main/setup.sh`.
Attach `kaisian.phx.tw` as a custom domain to the `kaisian` Worker in Cloudflare.
The local fixture is for the Python preview and is not served by the Worker.
