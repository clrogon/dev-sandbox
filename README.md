# dev-sandbox

One-command provisioners for an AI development workstation equipped with Claude Code, opencode, six MCP servers, and a complete developer toolchain. Two scripts, one per platform; identical dependency order; fail-isolated stages; always idempotent.

| Platform | Script |
|---|---|
| Windows / Windows Sandbox | [`windows/Setup-ClaudeCodeSandbox.ps1`](windows/Setup-ClaudeCodeSandbox.ps1) |
| macOS (Intel and Apple Silicon) | [`macos/Setup-ClaudeCodeSandbox.sh`](macos/Setup-ClaudeCodeSandbox.sh) |

## Why use this?

Set up a **complete AI development workstation in one command** with:
- Claude Code + opencode for local AI-driven development
- Six pre-configured MCP servers (GitHub, Sequential Thinking, Memory, Context7, Sentry, Supabase)
- A full-stack developer toolkit (Git, Python, Node.js, uv, Bun, Deno, Go, Rust, Docker Desktop)
- Language servers for Python, JavaScript/TypeScript, Go, Rust
- VS Code + PostgreSQL + CLI tools (GitHub CLI, Supabase CLI, Strix)
- A workspace folder tree and GitHub auth (with interactive repo picker)

Use it to:
- Provision fresh Windows/macOS machines from scratch
- Run inside Windows Sandbox for a throwaway sandbox environment
- Bootstrap a consistent developer environment across a team
- Test tools in isolation without affecting your main system

## What gets installed

Both scripts install the same seven-tier stack:

- **Tier 0**: Preflight checks (admin, OS, arch, logging)
- **Tier 1**: Runtimes — Git, Python, Node.js
- **Tier 2**: Toolchains — uv, Bun, Deno
- **Tier 3**: CLI layer — GitHub CLI, Claude Code, opencode, Vite, Grok Build, Supabase CLI, Strix
- **Tier 3.5**: MCP layer — six servers (GitHub, Sequential Thinking, Memory, Context7, Sentry, Supabase) installed and registered with opencode
- **Tier 4**: Heavy/GUI tools — VS Code, PostgreSQL, and platform-native tools (Windows: Notepad++, 7-Zip)
- **Tier 4.5**: Language servers — pyright, ruff, black, isort, mypy (Python); typescript-language-server, eslint, vscode-langservers-extracted (JS/TS); gopls (Go); rust-analyzer (Rust)
- **Tier 5**: Configuration — git identity, Strix environment, Sentry environment
- **Tier 6**: Optional Docker Desktop (must be last; can request a reboot)
- **Tier 7**: Workspace setup — folder tree, GitHub auth, interactive repo picker, clone into workspace

### Key guarantees

- **Fail-isolated**: each tool runs in its own stage; one tool's failure doesn't abort the entire run. A per-tool result table is printed at the end.
- **Idempotent**: safe to re-run; existing installations are skipped by default (override with `-Force` to reinstall).
- **Dry-run aware**: every stage honors `-DryRun`; prints what would be done without making changes.
- **No interactive prompts under `-AcceptAll`**: suitable for unattended automation.
- **Exit code reflects health**: exits 0 on complete success, 2 if any tool failed, so it can be chained in CI/CD pipelines.

## Platform-specific notes

### macOS (Intel and Apple Silicon)

The macOS script detects your architecture once at startup and uses the correct binary for each tool that publishes arch-specific releases (GitHub CLI, Supabase CLI, VS Code, Docker Desktop, Go, Rust).

- **Supported**: x86_64 (Intel) and arm64 (Apple Silicon)
- **Unsupported**: anything else (unusual emulation) → explicit error, not silent misbehavior

The script also detects your login shell and writes environment variables to the correct file:
- **zsh**: `~/.zshenv`
- **bash**: `~/.bash_profile`
- **fish**: `~/.config/fish/config.fish` (using fish's `set -gx` syntax)
- **other**: `~/.zshenv` with a warning message about the actual path

### Windows (including Windows Sandbox)

The Windows script uses direct MSI/EXE downloads with explicit exit-code handling (0, 1641, 3010 all treated as success).

**Note on Strix and Docker**: Strix scans run inside a Docker container. Windows Sandbox does **not** expose nested virtualization, so Docker's WSL2/Hyper-V backend cannot start there. The Strix CLI installs and `strix --help` works, but scans will fail inside Sandbox. The same constraint applies to `supabase start` (local stack). MCP servers (except Supabase's local stack) work fine in Sandbox because they're pure npm packages.

## Quick start

### Try it dry-run first

Before running for real, see what will be installed:

**Windows (PowerShell):**
```powershell
.\windows\Setup-ClaudeCodeSandbox.ps1 -DryRun
```

**macOS (Intel or Apple Silicon):**
```bash
./macos/Setup-ClaudeCodeSandbox.sh -DryRun
```

### Run unattended

Supply your Git identity and any optional secrets (Strix, Sentry, Perplexity). GitHub credentials are resolved from your existing `gh auth login` at Tier 7 (or skipped if not authenticated).

**Windows (PowerShell):**
```powershell
.\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll `
    -GitUserName 'Your Name' -GitUserEmail 'you@example.com' `
    -StrixLlm 'anthropic/claude-sonnet-4-6' -StrixApiKey $env:ANTHROPIC_API_KEY
```

**macOS (bash):**
```bash
./macos/Setup-ClaudeCodeSandbox.sh -AcceptAll \
    -GitUserName 'Your Name' -GitUserEmail 'you@example.com'
```

Both scripts exit with code 0 on success, 2 if any tool failed. Each tool's result is printed in a summary table at the end.

### Interactive mode

Omit `-AcceptAll` for prompts at each stage:

```powershell
# Windows
.\windows\Setup-ClaudeCodeSandbox.ps1
```

```bash
# macOS
./macos/Setup-ClaudeCodeSandbox.sh
```

## Parameters

### Behavior flags

| Flag | Effect |
|---|---|
| `-AcceptAll` | Disable all interactive prompts; use safe defaults (Git identity: `"Sandbox User" <sandbox@localhost.invalid>`). |
| `-DryRun` | Show what would be installed; make no changes. |
| `-Force` | Reinstall/overwrite even if a tool is already present. |
| `-InstallDocker` | Opt in to Docker Desktop (Tier 6, last — installer may request a reboot). |

### Identity and secrets

| Parameter | Purpose | Default |
|---|---|---|
| `-GitUserName` | Git commit name | `"Sandbox User"` (under `-AcceptAll`); otherwise prompts |
| `-GitUserEmail` | Git commit email | `"sandbox@localhost.invalid"` (under `-AcceptAll`); otherwise prompts |
| `-GithubUser` | GitHub account (Tier 7 repo picker) | Auto-resolved from `gh auth status` |
| `-StrixLlm` | Strix LLM model, e.g. `anthropic/claude-sonnet-4-6` | None |
| `-StrixApiKey` | Strix LLM API key | None |
| `-StrixApiBase` | Optional LLM_API_BASE (local models) | None |
| `-PerplexityApiKey` | Optional Perplexity API key (enables Strix search) | None |
| `-SentryAuthToken` | Sentry MCP server auth token | None |
| `-SentryOrg` | Sentry organization slug | None |

### Paths and versions

| Parameter | Purpose | Default |
|---|---|---|
| `-WorkspaceRoot` | Root of provisioned folder tree | `C:\Git\clrogon` (Windows); `~/Git/clrogon` (macOS) |
| `-PostgresVersion` | PostgreSQL version override | `18.4-1` |

### Skip flags

Use `-Skip<Tier>` or `-Skip<Tool>` to omit entire tiers or individual tools:

- **By tool**: `-SkipGit`, `-SkipPython`, `-SkipNode`, `-SkipUv`, `-SkipBun`, `-SkipDeno`, `-SkipGh`, `-SkipClaude`, `-SkipOpenCode`, `-SkipVite`, `-SkipGrok`, `-SkipSupabase`, `-SkipStrix`, `-SkipMcp`, `-SkipVSCode`, `-SkipPostgres`, `-SkipLsp`, `-SkipGitIdentity`, `-SkipWorkspace`, `-SkipRepoClone`
- **By Tier 2–4**: `-SkipUv`, `-SkipBun`, `-SkipDeno` (Tier 2), etc.

For a complete parameter list, run the script's help:

**Windows**: `Get-Help .\windows\Setup-ClaudeCodeSandbox.ps1 -Full`

**macOS**: `./macos/Setup-ClaudeCodeSandbox.sh -Help` (or read the header comment)

## MCP servers (Tier 3.5)

Both scripts install six MCP servers as npm packages and register them with opencode's global config (`~/.config/opencode/opencode.json`):

1. **GitHub** — interact with repos, issues, PRs via the MCP protocol
2. **Sequential Thinking** — reason step-by-step for complex tasks
3. **Memory** — persistent session memory across MCP tools
4. **Context7** — vector search and semantic context via Upstash
5. **Sentry** — browse and analyze Sentry issues
6. **Supabase** — query PostgreSQL, manage auth, run edge functions

opencode reads its config only at startup. After provisioning completes, restart opencode to use the new MCP tools.

### Updating the server list

Both scripts read [`config/mcp-packages.json`](config/mcp-packages.json) as the single source of truth. The PS1 script uses `ConvertFrom-Json`; the SH script uses grep/sed (no Node/Python dependency, since this runs before Tier 1).

**To add, remove, or rename a server:**
1. Edit [`config/mcp-packages.json`](config/mcp-packages.json)
2. Update both scripts' embedded fallback arrays to match (so standalone downloads still work)

All server installation and registration code reads from the same loaded list — nothing else needs changing.

## Known limitations

- **Claude Code MCP config**: only opencode receives MCP server registration (`~/.config/opencode/opencode.json`). Claude Code MCP registration is future work (likely via `claude mcp add-json`). You can manually register the MCP servers with Claude Code after provisioning if needed.

- **Docker in Windows Sandbox**: Strix scans and `supabase start` (local stack) both require Docker containers. Windows Sandbox doesn't expose nested virtualization, so these will fail in Sandbox environments (though the CLIs themselves install fine).

- **Fallback URLs**: pinned download URLs for Git, Python, Node, GitHub CLI, Supabase CLI, Notepad++, and 7-Zip are checked weekly by [`.github/workflows/link-check.yml`](.github/workflows/link-check.yml). However, the provisioners try dynamic resolvers first (GitHub Releases API, official download pages). Pinned URLs are only used if a dynamic resolver fails at runtime — **the dynamic resolvers are the source of truth, not the pins**.

## More documentation

- **[CHANGELOG.md](CHANGELOG.md)** — version history and migration notes
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — common issues and solutions
- **[MAINTENANCE.md](MAINTENANCE.md)** — for developers modifying the provisioners

## Version history

See [CHANGELOG.md](CHANGELOG.md) for detailed release notes and migration guides.
