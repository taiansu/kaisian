# kaisian

A macOS setup entry point for dotfiles, terminal fonts, Homebrew tools,
programming languages, and AI CLIs.

## Get your setup

Visit [kaisian.phx.tw](https://kaisian.phx.tw) to choose what to install and
copy a ready-to-run setup command. For example:

```sh
curl -fsSL https://kaisian.phx.tw | bash -s -- --yes --prompt prompt-pure --font font-sauce-code-pro-nerd-font --brew ripgrep,fzf --langs python,node --lang en
```

Review [setup.sh](https://github.com/taiansu/kaisian/blob/main/setup.sh) before running it. kaisian bootstraps Homebrew, git, and stow,
clones the dotfiles repository, backs up conflicting files, and stows the selected
groups into your home directory. It writes a Ghostty font override, then installs
the selected Homebrew packages with `brew bundle` and the selected languages with
mise. Selected AI CLIs are installed afterward using their official installers.
Homebrew, git, stow, and mise are always included, not selectable tools.
Homebrew installation may require a sudo password.

## Options

| Flag | Purpose |
| --- | --- |
| `--prompt NAME` | Use the default profile with its prompt group swapped for `NAME`. |
| `--groups NAME[,NAME...]` | Select stow groups exactly; at most one `kind: "prompt"` group. |
| `--profile NAME` | Select a named profile. Without any selection flag the `default` profile is used (every group if the manifest has none). |
| `--interactive` | Select groups with fzf, if installed; optional terminal-only mode. |
| `--all` | Select every group; still subject to the one-prompt limit. |
| `--font CASK` | Select a cask from the manifest's `fonts` array. |
| `--multiline true\|false` | Put context and command input on two lines, or combine them on one line. |
| `--show-time true\|false` | Show or hide the prompt timestamp. When enabled explicitly, it appears at the input line's right edge. |
| `--brew NAME[,NAME...]` | Select catalog entries or add official Homebrew formula/cask names. Extra names are verified and classified by Homebrew before dotfiles are applied. |
| `--langs LANG[,LANG...]` | Select tools to install via mise (e.g. `python,node,go` or any tool in the mise registry); Elixir also installs Erlang. |
| `--agents ID[,ID...]` | Run selected official AI CLI installers: `codex`, `claude`, `pi`, `omp`. |
| `--features NAME[,NAME...]` | Select features from the manifest's `features` array. |
| `--stow-only` | Bootstrap and stow, and write selected font/prompt preferences, but do not install packages, languages, or AI CLIs. |
| `--dry-run` | Preview changes, bootstrap requirements, and generated inputs without installing anything. |
| `--lang en\|zh-TW` | Set the installer language. |
| `--repo URL\|OWNER/REPO[/tree/REF]` | Use another dotfiles source; requires a ref via `/tree/REF` or `--ref`. |
| `--ref REF` | Choose a repository reference; defaults to the `kaisian` branch of `taiansu/dotfiles`. |
| `--dir PATH` | Set the local checkout directory. |
| `--yes` | Auto-confirm conflict backups; required for `curl \| bash` since stdin is the script. |
| `-h`, `--help` | Show usage. |

Selection flags (`--prompt`, `--groups`, `--profile`, `--interactive`, `--all`) are
mutually exclusive. Optional font, brew, language, and AI CLI selections default
to empty in the CLI. mise is installed even with empty selections.
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
each tool name is checked against the mise registry. Kaisian itself does not
rewrite shell rc files; selected upstream AI installers may adjust shell profiles
as part of their own PATH handling.

For local testing, `KAISIAN_MISE_EXEC` selects a replacement mise executable,
`KAISIAN_BREW_EXEC` selects a replacement brew executable,
`KAISIAN_BREW_INSTALLER` replaces the Homebrew installer command,
`KAISIAN_DEFAULTS_EXEC` replaces defaults, and
`KAISIAN_ACTIVATE_SETTINGS_EXEC` replaces activateSettings.
`KAISIAN_AGENT_DOWNLOADER` replaces AI installer downloads only when
`KAISIAN_TESTING=1`; production always uses the fixed official URLs.

## Prompt preferences

The page defaults to a single-line prompt with time enabled. The two checkboxes
apply to all six themes, keep their values when changing themes, fonts, or
languages, and emit explicit `--multiline false --show-time true` arguments.
The font selector displays the selected font's localized feature description.
Prompt and font cards share the same desktop row height.

Both flags accept only `true` or `false`, in spaced or `--flag=value` form.
When neither is supplied, the CLI leaves stored preferences untouched; a fresh
installation retains each theme's native layout and time defaults.
Explicit settings are written to
`${XDG_CONFIG_HOME:-$HOME/.config}/zsh/kaisian-prompt.zsh` as
`KAISIAN_PROMPT_MULTILINE` and `KAISIAN_PROMPT_SHOW_TIME`. Partial updates keep
the other stored setting. This file is loaded before `local.zsh`, so personal
overrides still win. The installer does not source the stored file.

Explicitly enabled time uses `HH:MM:SS` on `RPROMPT`, in the input row for both
layouts. It records the prompt-render time, not a continuously updating clock.
The web preview uses a fixed sample time and hides it when the row is too narrow,
as zsh does for an overlapping right prompt. Disabling time does not remove
Default's SSH indicator. Switching Tokyo Night to a single line moves its native
inline timestamp to the right, without leaving a colored time segment behind.

Default, Pure, Bracketed, and Nerd Font use the same Smyck-inspired foreground colors
in their real zsh layouts and manifest previews; the other themes retain their
existing palettes. `--dry-run` reports preference writes without changing the
configuration; `--stow-only` applies selected preferences without installing tools.

## AI CLI installers

All four AI CLI checkboxes are unchecked by default. The browser emits only
selected IDs in `--agents`; unknown IDs and empty list entries are rejected.
These installers are independent of the dotfiles manifest and use a fixed
official-source allowlist in `setup.sh`, not arbitrary script URLs.

| ID | Official name | Official macOS installer |
| --- | --- | --- |
| `codex` | [Codex CLI](https://learn.chatgpt.com/docs/codex/cli.md) | `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` |
| `claude` | [Claude Code](https://code.claude.com/docs/en/setup) | `curl -fsSL https://claude.ai/install.sh \| bash` |
| `pi` | [Pi](https://pi.dev/docs/latest/quickstart) | `curl -fsSL https://pi.dev/install.sh \| sh` |
| `omp` | [omp](https://omp.sh/) | `curl -fsSL https://omp.sh/install \| sh` |

Kaisian downloads each selected script completely into its private sandbox
before executing it with the official shell. Download or execution errors stop
the installer; partial downloads are never executed. `--dry-run` shows the
selected commands without downloading or executing them, and `--stow-only`
skips this stage. Installation does not add login commands or API-key setup.

The AI CLI section marks Codex CLI and Pi with matching footnotes:

- **Codex CLI:** its official installer can modify a shell profile or PATH,
  including a stowed profile, and can offer migration from another installation.
- **Pi:** requires Node.js 22.19+ and npm. Its installer can prompt about missing
  dependencies, reinstalling or migrating an existing installation, and starting Pi.

Upstream prompts remain interactive; Kaisian does not automatically choose
uninstallation or launch the installed agents.

Agent subprocesses receive `~/.local/bin` and the installed Node/Bun runtimes
selected by this run's mise configuration on PATH. Runtime paths come from
`mise where`; unavailable selected runtimes fail rather than guessing a different
version. For omp's Bun-based installation, the child defaults `BUN_INSTALL_BIN`
to `~/.local/bin`, unless the caller explicitly supplied another nonempty value.

The AI CLI rows use inline SVG brand marks at `1em` height, scaling with the
label font size while preserving aspect ratio. Checkboxes, marks, and labels are
vertically centered without changing multi-line tool choices elsewhere.
Logo sources: [OpenAI Blossom](https://openai.com/brand/),
[Claude](https://claude.com/icon.svg), [Pi](https://pi.dev/favicon.svg), and
[omp](https://omp.sh/favicon.svg). The marks identify their respective tools
and do not imply endorsement.

The always-installed section spans both desktop columns. Its tools and
descriptions form a responsive grid, stacking into one column on narrow screens.
macOS tweak setup notes are separated from the bullet list and use bold,
non-italic text.

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
    {"name": "gitstatus", "tap": {"name": "romkatv/gitstatus", "trusted": true}, "description": {"en": "Async git status daemon", "zh-TW": "非同步 git 狀態 daemon"}},
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
`brew` are optional arrays. A brew entry's `cask` defaults to `false`.

A catalog brew entry may declare `tap: {"name": "owner/repo", "trusted": true}`.
Tap names use two lowercase ASCII name segments separated by one `/`; URLs,
whitespace, leading punctuation, and `..` are rejected. `trusted` is optional and
defaults to `false`. Only selected catalog entries add taps; an explicit
`trusted: true` grants Homebrew trust to that tap, not to unrelated taps.
The generated Brewfile declares each selected tap once before its packages and
uses fully qualified names, for example `romkatv/gitstatus/gitstatus`.
If selected entries share a tap, any selected entry's explicit trust applies to
that tap; unselected entries never grant trust. No global trust-disable switch is
used, and `--dry-run` does not grant trust.

`features` is an optional array of opt-in macOS tweaks and configuration file copies. Each feature
has a `name`, required `description`, and optional `macos` (boolean), `brew` (inline
tool objects with optional `cask`), `copy` (array of `{from, to}` relative file paths
where `from` is relative to the repository checkout and `to` is relative to `$HOME`),
`hotkeys` (array of `{id, enabled, ascii?, keycode?, modifiers?}` symbolic hotkey
entries), and `notes` (localized post-install guidance). Schema 1 manifests without
`kind`, `fonts`, `brew`, or `features` remain supported. Do not list Homebrew, git,
stow, or mise as optional tools.

Prompt `preview` data separates context and the input marker into two segment
arrays. Do not embed time or alignment-padding spaces in these arrays: the page
combines the rows and positions the optional timestamp. Font `description`
contains the localized feature summary shown below the selector.

Publish installer support for new manifest fields before publishing a dotfiles
manifest that uses them. The default installer reads the dotfiles `kaisian`
branch; editing only dotfiles `main` does not change the released manifest.

### Editing the installer

Edit manifest validation in `installer/manifest.js` and group selection in
`installer/selection.js`. Both use the same in-memory manifest. `installer/run.js`
connects them to the macOS filesystem and fzf using `/usr/bin/osascript`; users
do not need Node or Bun. Bash still consumes the plan's `selected.txt`,
`unselected.txt`, and package tables.

After changing these sources, run `bash scripts/assemble-setup.sh` and commit the
updated `setup.sh` alongside them. Only the marked JavaScript block is generated;
edit the surrounding Bash directly. `bash tests/setup_test.sh` checks that the
embedded version is current before exercising the single-file installer.

## Web page and deployment

The single-file page uses no framework or build step. In production it fetches
the manifest from the dotfiles repository's **kaisian branch**; change
`REMOTE_MANIFEST_URL` at the top of the script in `web/index.html` when that
layout is published elsewhere. The installer source and selected dotfiles ref
must also contain the matching manifest and package layout before generated
commands can be used end to end.
For prompt-option releases, publish the updated dotfiles `kaisian` branch and
matching two-part preview metadata before deploying the new page; otherwise the
released shell layouts will not read the generated prompt preferences.

Local preview (Python 3):

```sh
python3 -m http.server 8765 --directory web
```

Open `http://localhost:8765/`. On localhost the page loads
`fixtures/manifest.json` without browser caching; keep that fixture identical to
the canonical `.kaisian.json` in the dotfiles repository. `?manifest=<url>` can
point to another manifest (cross-origin URLs need CORS). English / Traditional
Chinese selection is remembered locally. The page defaults to the default
profile, the first font, every optional Homebrew tool, Python, and Node. Custom
Homebrew and mise names are validated against the installer's format rules;
invalid input disables command copying. Homebrew performs authoritative
existence and formula/cask classification during installer preflight. Empty
flags are omitted, and the copy button has a manual-copy fallback.
The language card keeps its format-rule help at the bottom of the desktop card;
on narrow screens it follows the custom-tool input in normal flow.

Deploy to Cloudflare Workers with Wrangler:

```sh
bun x wrangler login
bun x wrangler dev
bun x wrangler deploy
```

`wrangler.jsonc` imports HTML and SVG as text and declares `kaisian.phx.tw` as a Workers
Custom Domain. `wrangler deploy` deploys the Worker and binds that domain; the
logged-in Cloudflare account must own the `phx.tw` zone.
The page loads the GA4 Google tag with measurement ID `G-B6SP0HZDEN` from its
HTML `<head>`. It does not install a Google Tag Manager container.
Clicking the command's Copy button emits the GA4 custom event
`copy_command_click` once per click, regardless of clipboard success; no command
text is sent with the event.
Cloudflare Web Analytics uses the manually installed beacon before `</body>`;
keep automatic snippet injection disabled for this site to avoid duplicate page views.
`/favicon.svg` and `/favicon.ico` both return the site's SVG mark with
`image/svg+xml`, regardless of the `Accept` header. These image routes are handled
before content negotiation so browser icon requests never redirect to the installer.
For other paths, requests whose `Accept` header includes `text/html` receive the page;
other requests receive a 302 redirect to
`https://raw.githubusercontent.com/taiansu/kaisian/main/setup.sh`.
The local fixture is for the Python preview and is not served by the Worker.
For `wrangler dev`, override the local default with
`?manifest=https://raw.githubusercontent.com/taiansu/dotfiles/kaisian/.kaisian.json`.
Local Wrangler build artifacts and caches under `.wrangler/` are git-ignored.
