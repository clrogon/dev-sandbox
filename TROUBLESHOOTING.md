# Troubleshooting

Common questions and solutions when running the provisioners.

## Before you start

**Run with `-DryRun` first** to see what will be installed and catch any issues early:

```powershell
# Windows
.\windows\Setup-ClaudeCodeSandbox.ps1 -DryRun
```

```bash
# macOS
./macos/Setup-ClaudeCodeSandbox.sh -DryRun
```

## General issues

### "Access denied" or "requires admin"

Both scripts require administrative privileges (to install system tools like Python, Node.js, PostgreSQL, Docker).

**Windows**: Run PowerShell as Administrator before executing the script.

**macOS**: The script caches `sudo` at startup with `sudo -v`. You'll be prompted for your password once; subsequent installs won't re-prompt.

### "Command not found" after the script completes

The script added new tools to your PATH (Python, Node.js, etc.), but your shell may have cached the old PATH.

**Solution**: Close and reopen your terminal, or source the profile file:

**macOS (zsh)**:
```bash
source ~/.zshenv
```

**macOS (bash)**:
```bash
source ~/.bash_profile
```

**macOS (fish)**:
```bash
source ~/.config/fish/config.fish
```

**Windows (PowerShell)**: Close and reopen PowerShell.

### The script installed some tools but not all

This is **expected and by design**. The provisioner is fail-isolated — if one tool fails, others still install. Check the result table printed at the end to see which succeeded and which failed.

To see full details:
- **Windows**: Check `./Setup-ClaudeCodeSandbox.log` or the transcript from `-TranscriptPath`
- **macOS**: Check the log at the path shown in the script output (default: `/tmp/clrogon-sandbox-setup/Setup-ClaudeCodeSandbox.sh.log`)

### "The specified script file is not signed"

**Windows PowerShell**, if your execution policy is `AllSigned`:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Or run the script with `-ExecutionPolicy Bypass`:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll
```

## Platform-specific issues

### macOS: "Architecture not supported"

The script only works on x86_64 (Intel) or arm64 (Apple Silicon). If you see this error, you're running on an unsupported architecture (e.g., unusual emulation or PPC — unlikely, but the check prevents silent failures).

Check your architecture:
```bash
uname -m    # Should print x86_64 or arm64
```

### macOS: Environment variables not persisting

The script writes to your login shell's config file:
- **zsh**: `~/.zshenv`
- **bash**: `~/.bash_profile`
- **fish**: `~/.config/fish/config.fish`
- **other**: `~/.zshenv` (with a warning)

**Solution**: Close and reopen your terminal. If that doesn't work:

1. Check which file was written (look for the warning in the script output)
2. Verify the file exists and has content: `cat ~/.zshenv` (or your shell's file)
3. If the file looks empty, re-run the script with `-Force -SkipNode -SkipPython -SkipGit ... -SkipDocker` to force Tier 5 (git identity/env config)

### Windows: Git/Python/Node not available in a new PowerShell window

Windows PATH updates don't take effect in currently-open processes. Close and reopen PowerShell after the script completes.

### Windows: "Error: Could not find a part of the path"

You may be running from a UNC path or a location with special characters. Try running the script from `C:\` instead:

```powershell
cd C:\
.\path\to\Setup-ClaudeCodeSandbox.ps1 -AcceptAll
```

## MCP servers

### MCP servers installed but not appearing in opencode

opencode reads its config **only at startup**. After provisioning:

1. Restart opencode completely (close all windows, wait a moment, reopen)
2. Run `opencode --version` to confirm it's running
3. Check the config file: `cat ~/.config/opencode/opencode.json` (should list the six servers)

### "Docker is required but not installed" (Strix / Supabase local stack)

Strix scans and Supabase's local `supabase start` command run inside Docker containers. The provisioner installs Docker Desktop only if you pass `-InstallDocker`:

```powershell
# Windows
.\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll -InstallDocker
```

```bash
# macOS
./macos/Setup-ClaudeCodeSandbox.sh -AcceptAll -InstallDocker
```

**Note**: Docker installation is always last because the installer can request a reboot.

### Docker works but Strix fails in Windows Sandbox

**Expected limitation**: Windows Sandbox doesn't expose nested virtualization, so Docker's WSL2/Hyper-V backend can't start there. The Strix CLI installs and `strix --help` works, but scans will fail in Sandbox.

**Workaround**: Run Strix scans on a regular Windows machine, not inside Sandbox.

## Tier 7 (workspace and repo picker)

### GitHub repo picker doesn't appear

Tier 7 (workspace setup) requires `gh auth login` to have succeeded earlier. If the repo picker is skipped:

1. Is GitHub CLI installed? Check: `gh --version`
2. Is your GitHub account authenticated? Run: `gh auth status`
3. If not authenticated, run: `gh auth login` manually, then re-run the provisioner with `-SkipGit -SkipPython -SkipNode ... -SkipWorkspace` to jump to Tier 7 only

### "gh repo list" is empty or shows someone else's repos

This means `gh auth login` authenticated under a different GitHub account than expected. Run `gh auth logout` and `gh auth login` again with the correct account, then re-run the provisioner.

## Strix configuration

### Strix tests fail with "API key not set"

You may need to provide Strix credentials:

```powershell
# Windows
.\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll `
    -StrixLlm 'anthropic/claude-sonnet-4-6' `
    -StrixApiKey $env:ANTHROPIC_API_KEY
```

```bash
# macOS
./macos/Setup-ClaudeCodeSandbox.sh -AcceptAll \
    -StrixLlm 'anthropic/claude-sonnet-4-6' \
    -StrixApiKey "$ANTHROPIC_API_KEY"
```

If you omit these, Tier 5 (Strix env setup) is skipped. You can add the env vars later manually:

```powershell
# Windows
[System.Environment]::SetEnvironmentVariable('STRIX_LLM', 'anthropic/claude-sonnet-4-6', [System.EnvironmentVariableTarget]::User)
[System.Environment]::SetEnvironmentVariable('LLM_API_KEY', 'your-api-key', [System.EnvironmentVariableTarget]::User)
```

```bash
# macOS
echo 'export STRIX_LLM=anthropic/claude-sonnet-4-6' >> ~/.zshenv
echo 'export LLM_API_KEY=your-api-key' >> ~/.zshenv
source ~/.zshenv
```

## Re-running the provisioner

It's safe to re-run the provisioner — all stages are idempotent. By default, existing tools are skipped:

```powershell
# Windows
.\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll -GitUserName 'Name' -GitUserEmail 'email'
```

```bash
# macOS
./macos/Setup-ClaudeCodeSandbox.sh -AcceptAll -GitUserName 'Name' -GitUserEmail 'email'
```

To **reinstall** a tool, use `-Force`:

```powershell
# Windows - reinstall everything
.\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll -Force
```

```bash
# macOS - reinstall everything
./macos/Setup-ClaudeCodeSandbox.sh -AcceptAll -Force
```

Or skip specific tools to only reinstall some:

```powershell
# Windows - reinstall only Node.js
.\windows\Setup-ClaudeCodeSandbox.ps1 -AcceptAll -Force -SkipGit -SkipPython -SkipUv -SkipBun -SkipDeno -SkipGh -SkipClaude -SkipOpenCode -SkipVite -SkipGrok -SkipSupabase -SkipStrix -SkipMcp -SkipVSCode -SkipPostgres -SkipLsp -SkipDocker -SkipWorkspace
```

## Still stuck?

1. Check the full log file (referenced in script output or in the `-LogPath` you specified)
2. Note which Tier and tool failed
3. Try re-running with `-DryRun` to see what was planned vs. what actually ran
4. Search GitHub Issues in this repository, or file a new issue with:
   - The output from the script
   - Your OS and architecture (`uname -a` on macOS, `systeminfo` on Windows)
   - The command you ran
