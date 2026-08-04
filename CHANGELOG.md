# Changelog

Version numbers below are the ones embedded in each script's own header
comment (`# v3.x -- ...`), not this repo's own release tags — the two
scripts have historically been versioned together. v3.0 predates this repo
and its diff against v3.1 isn't available here; history starts at v3.1.

## Unreleased

Fixes from a review of the v3.1 → v3.2 diff, applied while setting up this
repo:

- **Fixed**: the Windows PS1 file had a UTF-8 BOM at byte 0. Running it
  directly as a `.ps1` file was unaffected (PowerShell's file loader strips
  BOMs), but it silently broke remote execution: fetching the raw text with
  `Invoke-RestMethod` and passing it to `[scriptblock]::Create()` — the
  pattern needed to support `irm <url> | iex`-style one-liner installs with
  arguments — failed with "Unexpected attribute 'CmdletBinding'" because the
  leading BOM character stopped the parser from recognizing the top-level
  `[CmdletBinding()]`/`param()` block. Reproduced against the real hosted
  file, fixed by stripping the BOM, then re-verified the complete script
  runs correctly end-to-end (`-DryRun`) via the exact one-liner pattern
  against the live raw URL. The macOS script never had a BOM.
- **Fixed**: `-GithubUser` no longer defaults to a hardcoded personal
  GitHub username on either platform. Tier 7's repo picker now resolves the
  account from `gh auth status`/`gh api user` when `-GithubUser` is omitted,
  so a fresh clone of this repo browses *your* repos, not the original
  author's. (Windows PS1 additionally had a second, independent instance of
  the same bug: the actual `gh repo clone` call was hardcoded to a literal
  username regardless of what `-GithubUser` was set to — fixed to use the
  resolved value.)
- **Fixed (macOS)**: `select_github_repository()` took the first
  tab-separated column of plain-text `gh repo list` output and used it
  directly as the repo name, but that column is actually `owner/repo`, not
  a bare name (verified live). Every downstream use already re-prepended
  `$GITHUB_USER` itself, so this produced `gh repo clone
  "clrogon/clrogon/dev-sandbox"` (invalid) and a destination path with an
  extra nested owner directory — reproduced the exact clone failure live.
  This predates all of this session's changes but sits inside the exact
  function the GithubUser fix above touched: the repo-clone feature has
  never worked on macOS, independent of how `GITHUB_USER` was set. The
  PS1 script doesn't have this bug — its `--json name` field is confirmed
  to already return the bare name.
- **Removed**: `install_notepad()` / `install_sevenzip()` dead stubs and
  their `-SkipNotepad` / `-SkipSevenZip` flags from the macOS script. Both
  functions only ever printed "Windows-only: skipped on macOS" — the
  Windows script already installs the real tools natively, so the macOS
  script no longer references them at all.
- **Removed**: the `mcp-config.json` generator (`Configure-McpJson` /
  `configure_mcp_json`). It wrote to `<workspace>/mcp/mcp-config.json`, but
  neither Claude Code nor opencode reads that path — opencode gets its own
  real config via `Configure-OpencodeMcp` / `configure_opencode_mcp`, and
  Claude Code had no consumer at all. Removed rather than left orphaned;
  re-adding real Claude Code MCP registration is future work.
- Minor doc cleanup: a duplicated "Tier 4.5 LSP layer" block in the PS1
  header comment, and a couple of header lines that described defaults
  ("Git identity (clrogon default)") that didn't match what the code
  actually falls back to (`"Sandbox User"`).
- **Refactored**: the MCP server list (6 servers) was previously hardcoded
  in four places (a flat array + an inline Node object per script). It now
  lives once in [`config/mcp-packages.json`](config/mcp-packages.json);
  both scripts load it at runtime relative to their own location and fall
  back to an embedded copy if it's missing, so a lone downloaded script
  still works standalone. `Install-McpServers`/`install_mcp_servers` and
  `Configure-OpencodeMcp`/`configure_opencode_mcp` now both read from the
  same loaded list instead of maintaining their own copy.
- **Fixed (macOS, Apple Silicon)**: the script no longer exits unconditionally
  on arm64. It now detects `$ARCH` once and picks the right asset for every
  tool that publishes an arch-specific build (GitHub CLI, Supabase CLI,
  VS Code, Docker Desktop, Go) — Git/Python/Node.js already ship
  universal/multi-arch installers, so those needed no change. GitHub CLI
  additionally had a broken dynamic-resolver pattern and a dead pinned
  fallback URL (`.tar.gz`, but GitHub CLI has published `.zip` on macOS for
  a while) — both fixed as part of the same change, on both architectures.
  Also fixed a latent, unrelated bug found while verifying installer URLs:
  the PostgreSQL DMG URL had a stale `-osx-x64.dmg` suffix that 404s on
  EDB's server regardless of architecture (EDB ships one universal `-osx.dmg`
  per version) — PostgreSQL install was broken on Intel too, not just arm64.
- **Fixed**: `get_github_asset_url()` (the shared dynamic-resolver helper
  behind both `install_gh` and `install_supabase`) only matched compact
  JSON (`"browser_download_url":"..."`). GitHub's API doesn't guarantee
  that formatting — it serves pretty-printed JSON with a space after the
  colon for some repos and compact for others, observed to depend on
  response size. This silently broke the dynamic resolver for GitHub CLI
  on every run (always falling through to the pinned fallback, never
  actually reaching GitHub's latest release), while Supabase CLI's
  resolver happened to keep working by luck of which format that repo's
  API response used. Found and fixed by running the exact production
  function against both live API responses, not just re-reading the code.
- **Fixed**: `persist_env()`/`add_to_path()` referenced `$ZSHENV`/`$ZSHRC`
  variables that were never defined anywhere in the script. Under `set -u`
  (active since line 1), the first call to either function — which happens
  early, e.g. right after installing Python — would abort the entire run
  with "unbound variable." Both functions now detect the user's actual
  login shell (`$SHELL`) and write to the file it really sources: zsh →
  `~/.zshenv`, bash → `~/.bash_profile`, fish → `~/.config/fish/config.fish`
  using fish's own `set -gx` syntax, anything else → `~/.zshenv` with an
  explicit warning naming the file. All "written to ~/.zshenv" log messages
  now reflect the actual resolved path instead of assuming zsh.
- **Fixed**: the shell-detection block created `$PROFILE_FILE` and its
  parent directory (e.g. `~/.config/fish/`) unconditionally at script-load
  time, before `main()` ever checked `-DryRun` — the one path that slipped
  through the otherwise-consistent dry-run gating (every actual
  `add_to_path`/`persist_env` call site was already correctly gated by its
  caller). Now skipped under `-DryRun` like everything else.
- Fixed a stale doc count: `Install-McpServers`'s docstring said "five"
  MCP servers; the list has always had six (predates this session's
  changes) and disagreed with `config/mcp-packages.json` and the
  neighboring `Configure-OpencodeMcp` docstring, which already said six.

## v3.2

- **Added Tier 3.5 (MCP layer)**: six MCP servers (GitHub, Sequential
  Thinking, Memory, Context7, Sentry, Supabase) installed as npm packages
  and registered with opencode's global config
  (`~/.config/opencode/opencode.json`), plus Sentry environment
  configuration.
- **Added Tier 4.5 (LSP / language tooling)**: pyright, ruff, black, isort,
  mypy (Python, via `uv tool install`); typescript-language-server,
  eslint, vscode-langservers-extracted (JS/TS, via `npm install -g`);
  gopls (Go); rust-analyzer (Rust, via rustup). Skippable with `-SkipLsp`;
  each stack auto-skips if its runtime (Node/uv/Go/Rust) isn't present.
- **Added Tier 7 (workspace + repo picker)**: provisions the recommended
  workspace folder tree, runs `gh auth login`, and presents an interactive
  numbered menu of the user's GitHub repos to clone.
- Bumped pinned fallback versions (Python 3.13.13 → 3.14.6, Node 22.11.0 →
  24.18.1) and added a dynamic Node.js LTS resolver
  (`nodejs.org/dist/index.json`) alongside the existing Git/Python
  resolvers, so pinned values are fallback-only.

## v3.1

Earliest version tracked in this repo. Tier 0–3 (preflight, runtimes,
toolchains, CLI layer) plus Tier 4 (VS Code, PostgreSQL, and — Windows
only — Notepad++/7-Zip), Tier 5 (git identity, Strix, Sentry env), and
Tier 6 (opt-in Docker Desktop, always last).
