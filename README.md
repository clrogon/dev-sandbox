# dev-sandbox

Unattended developer-toolchain provisioners for a Claude Code / opencode / MCP
sandbox — one script per platform, same dependency order, same fail-isolated
stage model.

| Platform | Script |
|---|---|
| Windows / Windows Sandbox | [`windows/Setup-ClaudeCodeSandbox.ps1`](windows/Setup-ClaudeCodeSandbox.ps1) |
| macOS (Intel / x86_64 only — see below) | [`macos/Setup-ClaudeCodeSandbox.sh`](macos/Setup-ClaudeCodeSandbox.sh) |

Both scripts install, in dependency order: Git → Python → Node.js (Tier 1),
uv/Bun/Deno (Tier 2), GitHub CLI / Claude Code / opencode / Vite / Grok /
Supabase CLI / Strix (Tier 3), six MCP servers registered with opencode
(Tier 3.5), VS Code / PostgreSQL / platform GUI tools (Tier 4), language
servers — pyright, ruff, black, isort, mypy, typescript-language-server,
eslint, gopls, rust-analyzer (Tier 4.5), git identity / Strix / Sentry env
(Tier 5), Docker Desktop opt-in (Tier 6), and a workspace folder tree with
`gh auth login` and an interactive repo picker (Tier 7).

Every stage is fail-isolated (one tool failing doesn't abort the run), every
stage is idempotent (safe to re-run), and every stage honors `-DryRun`.

## ⚠️ Platform constraint: macOS script is Intel/x86_64 only

`macos/Setup-ClaudeCodeSandbox.sh` checks `uname -m` at startup and **exits
immediately on Apple Silicon (arm64)** — it does not attempt Rosetta or an
arm64 code path. The direct-download URLs and dynamic resolvers it uses are
not architecture-aware. If you're on an M-series Mac, this script is not
usable as-is; either run it under Rosetta 2 with an x86_64 shell, or treat it
as a reference for what an arm64 branch would need to cover (Homebrew-based
installs for Python/Node/VS Code use the same paths on both architectures,
but the pinned fallback URLs for Git/Node/Python etc. do not).

## Usage

```powershell
# Windows -- fully unattended
.\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll `
    -GitUserName 'YOUR-NAME' -GitUserEmail 'you@example.com' `
    -StrixLlm 'anthropic/claude-sonnet-4-6' -StrixApiKey $env:ANTHROPIC_API_KEY

# Windows -- see what would happen first
.\windows\Setup-ClaudeCodeSandbox.ps1 -DryRun
```

```bash
# macOS (Intel) -- fully unattended
./macos/Setup-ClaudeCodeSandbox.sh -AcceptAll \
    -GitUserName 'YOUR-NAME' -GitUserEmail 'you@example.com'

# macOS -- see what would happen first
./macos/Setup-ClaudeCodeSandbox.sh -DryRun
```

`-GithubUser` is optional on both platforms. If omitted, Tier 7's repo
picker resolves it from whichever account `gh auth login` authenticated —
it does **not** default to a hardcoded username, so it never silently lists
someone else's repositories.

## Key parameters

| Parameter | Purpose |
|---|---|
| `-AcceptAll` | No interactive prompts; apply safe unattended defaults everywhere. |
| `-DryRun` | Print what each stage would do; no installs, no writes. |
| `-Force` | Reinstall/overwrite even if a tool is already present. |
| `-GitUserName` / `-GitUserEmail` | Git commit identity. Falls back to `"Sandbox User" <sandbox@localhost.invalid>` under `-AcceptAll` if not supplied. |
| `-GithubUser` | GitHub account for the Tier 7 repo picker. Optional — auto-resolved from `gh auth status` when omitted. |
| `-StrixLlm` / `-StrixApiKey` / `-StrixApiBase` / `-PerplexityApiKey` | Strix security-scan agent configuration. |
| `-SentryAuthToken` / `-SentryOrg` | Sentry MCP server configuration. |
| `-WorkspaceRoot` | Root of the provisioned folder tree (default `C:\Git\clrogon` / `~/Git/clrogon`). |
| `-PostgresVersion` | Override the PostgreSQL version to install. |
| `-InstallDocker` | Opt in to Docker Desktop (Tier 6, last — its installer can request a reboot). |
| `-Skip<Tool>` | One flag per tool/tier (`-SkipNode`, `-SkipMcp`, `-SkipLsp`, `-SkipVSCode`, `-SkipGitIdentity`, `-SkipWorkspace`, `-SkipRepoClone`, ...) to omit that stage entirely. |

Run either script with no arguments and no `-AcceptAll` for interactive
prompts, or see the script's own header comment / `Get-Help` for the full
parameter reference.

## MCP server list: single source of truth

Both scripts install the same six MCP servers and register them with
opencode. The list lives in one place, [`config/mcp-packages.json`](config/mcp-packages.json):

```json
{
  "servers": [
    { "key": "github", "package": "@modelcontextprotocol/server-github" },
    ...
  ]
}
```

At startup, each script resolves this file relative to its own location
(`../config/mcp-packages.json`) and loads it — the PS1 script via
`ConvertFrom-Json`, the SH script via a small grep/sed parser (no
node/python3 dependency, since this runs before Tier 1 may have installed
Node.js). If the file is missing or unparseable, each script falls back to
an embedded copy of the same list, so a lone downloaded script still works
outside a clone of this repo. **To add, remove, or rename an MCP server,
edit `config/mcp-packages.json` and update both scripts' embedded fallback
copies to match** — everything that installs or registers servers
(`Install-McpServers`/`install_mcp_servers`,
`Configure-OpencodeMcp`/`configure_opencode_mcp`) reads from the same loaded
list, so there's nothing else to change.

## Known limitations

- **macOS = Intel only.** See the platform constraint above.
- **MCP config**: only opencode gets a config file written
  (`~/.config/opencode/opencode.json`) — there is currently no equivalent
  wiring for Claude Code's own MCP registration. A prior `mcp-config.json`
  generator was removed because nothing actually consumed it; re-adding
  Claude Code MCP registration is tracked as future work, most likely via
  `claude mcp add-json` rather than hand-writing Claude Code's config file.
- Pinned fallback download URLs (Git, Python, Node, Notepad++, GH CLI,
  Supabase CLI, 7-Zip) are checked weekly by
  [`.github/workflows/link-check.yml`](.github/workflows/link-check.yml),
  but are otherwise only used when the dynamic resolver fails at runtime —
  the resolvers, not these pins, are the source of truth.

See [CHANGELOG.md](CHANGELOG.md) for version history.
