# Maintenance guide

This document describes how to modify and test the provisioner scripts.

## File structure

```
dev-sandbox/
  README.md                    # User-facing documentation
  CHANGELOG.md                 # Version history and migration notes
  MAINTENANCE.md              # This file
  config/
    mcp-packages.json         # Single source of truth for MCP servers
  windows/
    Setup-ClaudeCodeSandbox.ps1
  macos/
    Setup-ClaudeCodeSandbox.sh
  .github/workflows/
    link-check.yml            # Weekly check of pinned fallback URLs
```

## How the scripts work

### Single source of truth: MCP servers

Both scripts read `config/mcp-packages.json` at runtime:
- Windows script parses it via `ConvertFrom-Json`
- macOS script parses it via grep/sed (no Node/Python dependency)

If the file is missing or unparseable, each script falls back to an embedded array (`$MCP_PACKAGES` in the SH script, hardcoded in the PS1 script). This keeps the scripts usable standalone.

**To add, remove, or rename an MCP server:**
1. Edit `config/mcp-packages.json`
2. Find the embedded MCP list in the script's comment block (early in the file)
3. Update both scripts' embedded lists to match
4. The installation code reads from the loaded list — nothing else needs changing

### Tier structure

Both scripts install in the same order:

| Tier | What | Notes |
|---|---|---|
| 0 | Preflight | Admin check, OS/arch detection, logging setup |
| 1 | Runtimes | Git, Python, Node.js — others depend on these |
| 2 | Toolchains | uv, Bun, Deno |
| 3 | CLI tools | GitHub CLI, Claude Code, opencode, Vite, Grok, Supabase CLI, Strix |
| 3.5 | MCP servers | Six npm packages, registered with opencode |
| 4 | Heavy/GUI | VS Code, PostgreSQL, platform-native tools |
| 4.5 | Language servers | Auto-skip if their runtimes aren't available |
| 5 | Configuration | Git identity, Strix/Sentry env vars |
| 6 | Docker | Optional, always last (can request reboot) |
| 7 | Workspace | Folder tree, GitHub auth, interactive repo picker |

### URL resolution

Most tools use **dynamic resolvers** (GitHub Releases API, official download pages):
- Python, Node.js: LTS/latest from official APIs
- GitHub CLI, Supabase CLI: GitHub Releases API

**Pinned fallback URLs** (e.g., `GITHUB_CLI_URL_WINDOWS`) are defined early in each script as comments. These are checked weekly by [`.github/workflows/link-check.yml`](.github/workflows/link-check.yml), but are only used if a dynamic resolver fails at runtime.

### Fail-isolated execution

Every tool/stage runs independently:
- If `install_git()` fails, `install_python()` still runs
- Each failure is recorded in the `$RESULTS` array (Windows) or `RESULTS` array (macOS)
- At the end, a summary table is printed
- Exit code is 0 if all succeeded, 2 if any failed

### Idempotency

By default:
- Skip installs if a tool already exists (e.g., `if (Test-Path $PythonPath)`)
- Override with `-Force` to reinstall

### Dry-run mode

Every actual install/write is wrapped in a check:

**PowerShell:**
```powershell
if ($DryRun) {
    Write-Host "Would install Python..."
} else {
    # actual install
}
```

**Bash:**
```bash
if [ $DRY_RUN -eq 1 ]; then
    echo "Would install Python..."
else
    # actual install
fi
```

## Making changes

### Add a new tool

1. Create an `install_<tool>()` function (or `Install-<Tool>` in PS1)
2. Add it to the appropriate tier in `main()` / `main_script()`
3. Wrap calls in `-Skip<Tool>` logic
4. Add a function to record results

### Update a tool's version

1. If it's dynamic resolution (GitHub Releases API), no change needed — the resolver handles it
2. If it's a pinned fallback URL:
   - Update the comment near the top of the script
   - Test the URL manually before committing
   - Create a GitHub issue on this repo if you can't reach the official source
   - The weekly link-check workflow will catch stale URLs

### Update MCP servers

1. Edit `config/mcp-packages.json` with the new list
2. Update both scripts' embedded `MCP_PACKAGES` lists
3. Test with `-DryRun` first: `./script.ps1 -DryRun -SkipDocker`
4. Note the change in `CHANGELOG.md` (Unreleased section)

## Testing

### Local testing (no installs)

```powershell
# Windows
.\windows\Setup-ClaudeCodeSandbox.ps1 -DryRun
```

```bash
# macOS
./macos/Setup-ClaudeCodeSandbox.sh -DryRun
```

### In Windows Sandbox

1. Download `Setup-ClaudeCodeSandbox.ps1` alone (no repo clone)
2. Run it inside Sandbox with `-AcceptAll`
3. Test that embedded MCP list works (in case `config/mcp-packages.json` is unreachable)

### Integration testing

Use the full run with `-AcceptAll` and `-Force` to test all tiers:

```powershell
# Windows
.\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll -Force -GitUserName 'Test' -GitUserEmail 'test@example.com'
```

```bash
# macOS
./macos/Setup-ClaudeCodeSandbox.sh -AcceptAll -Force -GitUserName 'Test' -GitUserEmail 'test@example.com'
```

## Performance notes

- The macOS script parses `config/mcp-packages.json` using grep/sed (no Node/Python dependency) so it works even if Tier 1 hasn't completed yet
- The Windows script can use PowerShell 5.1's `ConvertFrom-Json` natively
- Both scripts cache `sudo` (macOS) or check admin (Windows) once at startup rather than repeatedly

## Logging

**Windows**: Output is tee'd to `./Setup-ClaudeCodeSandbox.log` by default

**macOS**: Output is tee'd to `${TMPDIR:-/tmp}/clrogon-sandbox-setup/Setup-ClaudeCodeSandbox.sh.log` or a custom path if `-LogPath` is supplied

Set `-NoCleanup` (macOS) or leave the default (Windows always keeps logs) to preserve temp files for inspection.

## Troubleshooting common issues

**Q: A tool install fails but others complete?**  
A: This is expected — that's the fail-isolated design. Check the result table at the end.

**Q: On macOS, env vars aren't persisting after the script completes?**  
A: The script detected your login shell and wrote to the right file (zsh/bash/fish), but shell caching/sourcing might not have picked it up. Close and reopen your terminal.

**Q: The script says "Would install X" but X was never installed?**  
A: You ran with `-DryRun`, which prints plans but doesn't execute. Run without `-DryRun` to actually install.

**Q: How do I run just Tier 5 (git config) without running all tiers?**  
A: Pass `-SkipGit -SkipPython -SkipNode -SkipUv -SkipBun -SkipDeno -SkipGh -SkipClaude -SkipOpenCode -SkipVite -SkipGrok -SkipSupabase -SkipStrix -SkipMcp -SkipVSCode -SkipPostgres -SkipDocker -SkipWorkspace`, then only Tier 5 (git identity) will run. Or just use `git config --global` manually.
