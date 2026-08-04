#Requires -Version 5.1
<#
.SYNOPSIS
    Unattended developer-toolchain provisioner for Windows and Windows Sandbox.
    Direct downloads only -- no winget, no interactive prompts, no aborts on
    a single tool failure.

.DESCRIPTION
    v3.2. Installs, in dependency order:

      Tier 0   Preflight     admin check, arch detect, Sandbox detect, transcript
      Tier 1   Runtimes      Git -> Python -> Node.js
      Tier 2   Toolchains    uv -> Bun -> Deno
      Tier 3   CLI layer     GitHub CLI -> Claude Code -> OpenCode -> Vite -> Grok Build
                             -> Supabase CLI -> Strix
      Tier 3.5 MCP layer     GitHub MCP -> Sequential Thinking MCP -> Memory MCP
                             -> Context7 MCP -> Sentry MCP -> Supabase MCP
                             registered with opencode
                             (global ~/.config/opencode/opencode.json)
      Tier 4   Heavy/GUI     VS Code -> Notepad++ -> 7-Zip -> PostgreSQL
      Tier 4.5 LSP layer     pyright -> ruff -> black -> isort -> mypy
                             (Python, via `uv tool install`)
                             -> typescript-language-server -> typescript
                             -> eslint -> vscode-langservers-extracted
                             (JS/TS, via `npm install -g`)
                             -> Go runtime -> gopls
                             -> Rust toolchain (rustup) -> rust-analyzer
                             Skipped by -SkipLsp. Auto-skips a stack when its
                             runtime (Node/uv/Go/Rust) is unavailable.
      Tier 5   Config        Git identity ("Sandbox User" fallback if unset),
                             Strix environment, Sentry environment vars
      Tier 6   Docker        Docker Desktop, opt-in only, LAST because its
                             installer can request a reboot that would abort
                             anything queued behind it
      Tier 7   Workspace     C:\Git\clrogon folder tree, gh auth login,
                             interactive GitHub repo picker, clone into
                             C:\Git\clrogon\projects, open in VS Code,
                             persist selected repo to CLAUDIO_CURRENT_REPO

    Key behavioural differences from v2.x:

    * FAIL-ISOLATED. Every tool runs inside its own stage. A failure is
      recorded and the run continues. v2 promoted every Write-Error to a
      terminating error via $ErrorActionPreference='Stop', so one bad
      download killed the whole run.
    * HARD SILENT. MSI packages are dispatched explicitly through
      msiexec.exe rather than relying on the shell file association.
      Exit codes 0 / 1641 / 3010 are all treated as success.
    * NO PROMPTS on -AcceptAll. Includes a working default Git identity so
      the first commit in a fresh sandbox does not fail.
    * SUMMARY + EXIT CODE. Prints a per-tool result table and exits 2 if
      anything failed, so this can be chained in automation.

    STRIX NOTE: Strix executes its scans inside a Docker container. Windows
    Sandbox does not expose nested virtualization, so Docker's WSL2/Hyper-V
    backend cannot start there. The CLI installs and 'strix --help' works,
    but scans will fail inside Sandbox. Same constraint as 'supabase start'.

    MCP NOTE: GitHub MCP, Sequential Thinking MCP, Memory MCP, Context7 MCP
    and Sentry MCP are pure npm packages and run on Node.js -- they do NOT
    require Docker, so they work inside Windows Sandbox. Supabase MCP
    connects to a local or cloud Supabase project; the cloud/console commands
    work, the local 'supabase start' stack still needs Docker. All MCP
    servers are merged into the global opencode config
    (~/.config/opencode/opencode.json) so opencode exposes them in every
    project. opencode reads its config only at startup -- restart it after
    the run for the MCP tools to appear.

    TIER 7 NOTE: The interactive repo picker and 'gh auth login --web' open
    a browser session. They are skipped under -AcceptAll -SkipWorkspace or
    when GitHub CLI is unavailable. The picker clones into
    C:\Git\clrogon\projects and writes the selected path to the User-scope
    CLAUDIO_CURRENT_REPO environment variable so downstream MCPs / VS Code
    tasks can auto-discover the active project without re-prompting.

.PARAMETER GitUserName
    Global git user.name. Defaults under -AcceptAll to 'Sandbox User'.
.PARAMETER GitUserEmail
    Global git user.email. Defaults under -AcceptAll to
    'sandbox@localhost.invalid' (RFC 2606 reserved TLD, never routable).
.PARAMETER StrixLlm
    Value for the STRIX_LLM environment variable, e.g.
    'anthropic/claude-sonnet-4-6'.
.PARAMETER StrixApiKey
    Value for the LLM_API_KEY environment variable.
.PARAMETER StrixApiBase
    Optional LLM_API_BASE, for local models (Ollama, LM Studio).
.PARAMETER PerplexityApiKey
    Optional PERPLEXITY_API_KEY, enables Strix search capability.
.PARAMETER GithubUser
    GitHub username used by Tier 7 (repo listing / clone). Optional --
    if omitted, it's resolved from whichever account `gh auth status` is
    logged in as (via `gh api user`). If that resolution fails, Tier 7
    skips the repo picker with a warning rather than guessing a username.
.PARAMETER SentryAuthToken
    Optional SENTRY_AUTH_TOKEN for the Sentry MCP server.
.PARAMETER SentryOrg
    Optional SENTRY_ORG slug for the Sentry MCP server.
.PARAMETER WorkspaceRoot
    Root directory for the clrogon workspace tree. Defaults to
    'C:\Git\clrogon'. Under -DryRun no directories are created.
.PARAMETER PostgresVersion
    EnterpriseDB build string, e.g. '18.4-1'. EDB publishes no latest-version
    API, so this is pinned and overridable rather than guessed.
.PARAMETER InstallDocker
    Install Docker Desktop. OFF by default: it is a ~700 MB download that
    cannot function inside Windows Sandbox. Auto-skipped in Sandbox unless
    -ForceDockerInSandbox is also passed.
.PARAMETER ForceDockerInSandbox
    Attempt the Docker Desktop install even when Windows Sandbox is detected.
    Expected to fail at engine start. Diagnostic use only.
.PARAMETER DryRun
    Resolve versions and URLs only. No downloads, no installs, no env writes.
.PARAMETER Force
    Reinstall even if already detected.
.PARAMETER VerifyChecksums
    Verify SHA256 where a trusted digest is published.
.PARAMETER AcceptAll
    Fully unattended: auto-accept vendor installer scripts, suppress all
    confirmation, apply default Git identity if none supplied.
.PARAMETER NoCleanup
    Keep the temporary download directory.
.PARAMETER LogPath
    Transcript path. Defaults to %USERPROFILE%\Setup-ClaudeCodeSandbox_<ts>.log
.PARAMETER Architecture
    Force x64 or arm64 instead of auto-detecting.

.EXAMPLE
    .\Setup-ClaudeCodeSandbox.ps1 -AcceptAll

.EXAMPLE
    .\Setup-ClaudeCodeSandbox.ps1 -AcceptAll -Force `
        -GitUserName 'Claudio' -GitUserEmail 'claudio@users.noreply.github.com' `
        -StrixLlm 'anthropic/claude-sonnet-4-6' -StrixApiKey $env:ANTHROPIC_API_KEY

.EXAMPLE
    .\Setup-ClaudeCodeSandbox.ps1 -DryRun -VerifyChecksums

.EXAMPLE
    Fully automated run with the workspace, MCP layer, and the
    interactive GitHub repo picker (GithubUser is optional -- it defaults
    to whichever account `gh auth login` authenticated):

    .\Setup-ClaudeCodeSandbox.ps1 -AcceptAll `
        -GitUserName 'YOUR-NAME' -GitUserEmail 'you@example.com' `
        -StrixLlm 'anthropic/claude-sonnet-4-6' -StrixApiKey $env:ANTHROPIC_API_KEY
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipNode,
    [switch]$SkipUv,
    [switch]$SkipBun,
    [switch]$SkipDeno,
    [switch]$SkipGh,
    [switch]$SkipClaude,
    [switch]$SkipOpenCode,
    [switch]$SkipVite,
    [switch]$SkipGrok,
    [switch]$SkipSupabase,
    [switch]$SkipStrix,
    [switch]$SkipMcp,
    [switch]$SkipVSCode,
    [switch]$SkipNotepad,
    [switch]$SkipSevenZip,
    [switch]$SkipPostgres,
    [switch]$SkipLsp,
    [switch]$SkipGitIdentity,
    [switch]$SkipWorkspace,
    [switch]$SkipRepoClone,

    [string]$GitUserName,
    [string]$GitUserEmail,

    [string]$StrixLlm,
    [string]$StrixApiKey,
    [string]$StrixApiBase,
    [string]$PerplexityApiKey,

    [string]$GithubUser,
    [string]$SentryAuthToken,
    [string]$SentryOrg,

    [string]$WorkspaceRoot = 'C:\Git\clrogon',

    [string]$PostgresVersion = '18.4-1',

    [switch]$InstallDocker,
    [switch]$ForceDockerInSandbox,

    [switch]$DryRun,
    [switch]$Force,
    [switch]$VerifyChecksums,
    [switch]$AcceptAll,
    [switch]$NoCleanup,
    [string]$LogPath,
    [ValidateSet('x64', 'arm64')][string]$Architecture
)

Set-StrictMode -Version Latest

# Stage bodies handle their own errors; the outer catch only sees genuinely
# unrecoverable faults. Individual tool failures never unwind past Invoke-Stage.
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
if ($AcceptAll) {
    $ConfirmPreference = 'None'
    $PSDefaultParameterValues['*:Confirm'] = $false
}
[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

# ---------------------------------------------------------------------------
# Tier 0 -- state
# ---------------------------------------------------------------------------

$script:TempDir          = Join-Path $env:TEMP 'ccode-sandbox-setup'
$script:Results          = New-Object System.Collections.Generic.List[object]
$script:RebootPending    = $false
$script:SuccessExitCodes = @(0, 1641, 3010)
$script:UserBinDir       = Join-Path $env:USERPROFILE '.local\bin'

# Tier 7 workspace state. -WorkspaceRoot is overridable; subfolders are the
# recommended layout from the v3.2 spec (projects, archive, mcp, logs,
# scripts, templates, powershell, architecture, security, downloads).
$script:WorkspaceRoot    = $WorkspaceRoot
$script:WorkspaceFolders = @(
    'projects', 'archive', 'mcp', 'logs',
    'scripts', 'templates', 'powershell',
    'architecture', 'security', 'downloads'
)
# Single source of truth for the MCP server list is ../config/mcp-packages.json
# (shared with the macOS script). Falls back to this embedded copy so the
# script still works standalone -- e.g. downloaded as a lone file, outside a
# clone of the dev-sandbox repo. Keep this fallback in sync with the JSON.
$script:McpServerMap = [ordered]@{
    github     = '@modelcontextprotocol/server-github'
    sequential = '@modelcontextprotocol/server-sequential-thinking'
    memory     = '@modelcontextprotocol/server-memory'
    context7   = '@upstash/context7-mcp'
    sentry     = '@sentry/mcp-server'
    supabase   = '@supabase/mcp-server-supabase'
}
if ($PSScriptRoot) {
    $mcpConfigPath = Join-Path $PSScriptRoot '..\config\mcp-packages.json'
    if (Test-Path -LiteralPath $mcpConfigPath) {
        try {
            $mcpJson = Get-Content -Raw -LiteralPath $mcpConfigPath | ConvertFrom-Json
            $loaded  = [ordered]@{}
            foreach ($entry in $mcpJson.servers) {
                if ($entry.key -and $entry.package) { $loaded[$entry.key] = $entry.package }
            }
            if ($loaded.Count -gt 0) {
                $script:McpServerMap = $loaded
            } else {
                Write-Warning "$mcpConfigPath has no valid entries -- using the embedded MCP server list."
            }
        } catch {
            Write-Warning "Could not parse $mcpConfigPath ($($_.Exception.Message)) -- using the embedded MCP server list."
        }
    }
}

New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

if ($Architecture) {
    $script:Architecture = $Architecture
} else {
    $rawArch = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    $script:Architecture = if ($rawArch -eq 'ARM64') { 'arm64' } else { 'x64' }
}

# ---------------------------------------------------------------------------
# Pinned fallback URLs — used ONLY when the dynamic resolver (GitHub API /
# nodejs.org / python.org) fails at runtime. Update these whenever a major
# version ships, but the resolvers are the source of truth.
#
# Last audited: 2026-08-03
#   Git     v2.55.0.windows.3   (dynamic: git-for-windows/git   latest)
#   Python  3.14.6              (dynamic: python.org/ftp/python/ latest)
#   Node    v24.18.1 LTS Krypton (dynamic: nodejs.org/dist/index.json LTS)
#   Npp     v8.9.7              (dynamic: notepad-plus-plus/notepad-plus-plus latest)
#   GH CLI  v2.96.0             (dynamic: cli/cli latest)
#   Supabase v2.111.0           (dynamic: supabase/cli latest)
#   7-Zip   26.02               (dynamic: ip7z/7zip latest)
# ---------------------------------------------------------------------------
$script:PinnedFallback = @{
    Git_x64        = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe'
    Git_arm64      = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-arm64.exe'
    Python_x64     = 'https://www.python.org/ftp/python/3.14.6/python-3.14.6-amd64.exe'
    Python_arm64   = 'https://www.python.org/ftp/python/3.14.6/python-3.14.6-arm64.exe'
    Node_x64       = 'https://nodejs.org/dist/v24.18.1/node-v24.18.1-x64.msi'
    Node_arm64     = 'https://nodejs.org/dist/v24.18.1/node-v24.18.1-arm64.msi'
    Notepad_x64    = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.7/npp.8.9.7.Installer.x64.exe'
    Notepad_arm64  = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.7/npp.8.9.7.Installer.arm64.exe'
    Gh_x64         = 'https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_windows_amd64.msi'
    Gh_arm64       = 'https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_windows_arm64.msi'
    Supabase_x64   = 'https://github.com/supabase/cli/releases/download/v2.111.0/supabase_2.111.0_windows_amd64.tar.gz'
    Supabase_arm64 = 'https://github.com/supabase/cli/releases/download/v2.111.0/supabase_2.111.0_windows_arm64.tar.gz'
    SevenZip_x64   = 'https://github.com/ip7z/7zip/releases/download/26.02/7z2602-x64.exe'
    SevenZip_arm64 = 'https://github.com/ip7z/7zip/releases/download/26.02/7z2602-arm64.exe'
}

# ---------------------------------------------------------------------------
# Output + result tracking
# ---------------------------------------------------------------------------

function Write-Step  { param([string]$m) Write-Host "`n==> $m"    -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host " [OK] $m"    -ForegroundColor Green }
function Write-Skip  { param([string]$m) Write-Host " [SKIP] $m"  -ForegroundColor Yellow }
function Write-Warn2 { param([string]$m) Write-Host " [WARN] $m"  -ForegroundColor Yellow }
function Write-Info  { param([string]$m) Write-Host " $m" }

# Deliberately NOT Write-Error. Under $ErrorActionPreference='Stop' a
# Write-Error becomes terminating and unwinds the entire script -- the v2 bug.
function Write-Fail  { param([string]$m) Write-Host " [FAIL] $m" -ForegroundColor Red }

function Set-Result {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][ValidateSet('Installed', 'Present', 'Skipped', 'Warning', 'Failed', 'DryRun')]
        [string]$Status,
        [string]$Detail = ''
    )
    $existing = $script:Results | Where-Object { $_.Tool -eq $Tool } | Select-Object -First 1
    if ($existing) {
        $existing.Status = $Status
        $existing.Detail = $Detail
        return
    }
    $script:Results.Add([pscustomobject]@{
        Tool   = $Tool
        Status = $Status
        Detail = $Detail
    })
}

function Invoke-Stage {
    <#
        Fail-isolation boundary. Anything thrown inside $Action is captured,
        recorded and swallowed so the remaining tiers still run.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Skip,
        [string]$SkipReason = 'Skipped by switch'
    )
    if ($Skip) {
        Write-Step "Checking $Name"
        Write-Skip $SkipReason
        Set-Result -Tool $Name -Status 'Skipped' -Detail $SkipReason
        return
    }
    try {
        & $Action
    } catch {
        Write-Fail "$Name : $($_.Exception.Message)"
        Set-Result -Tool $Name -Status 'Failed' -Detail $_.Exception.Message
    }
    if (-not ($script:Results | Where-Object { $_.Tool -eq $Name })) {
        Set-Result -Tool $Name -Status 'Warning' -Detail 'Stage returned without reporting a result.'
    }
}

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InWindowsSandbox {
    # WDAGUtilityAccount is the fixed guest account inside Windows Sandbox.
    if ($env:USERNAME -eq 'WDAGUtilityAccount') { return $true }
    try {
        $model = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model
        return ($model -like '*Virtual*' -and $env:COMPUTERNAME -eq 'WDAGUTILITYACCOUNT')
    } catch {
        return $false
    }
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    # Merges Machine + User + anything already added at process scope.
    # v2 overwrote $env:Path outright, discarding in-session additions.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $current = $env:Path

    $seen  = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($chunk in @($machine, $user, $current)) {
        if (-not $chunk) { continue }
        foreach ($entry in ($chunk -split ';')) {
            $trimmed = $entry.Trim()
            if (-not $trimmed) { continue }
            if ($seen.Add($trimmed)) { $merged.Add($trimmed) }
        }
    }
    $env:Path = ($merged -join ';')
}

function Add-ToUserPath {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { return $false }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries  = @()
    if ($userPath) { $entries = $userPath -split ';' | Where-Object { $_.Trim() -ne '' } }
    if ($entries -notcontains $Directory) {
        $new = if ($userPath) { "$userPath;$Directory" } else { $Directory }
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        Write-Ok "Added $Directory to User PATH."
    }
    return $true
}

function Set-PersistentEnvVar {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "Env:$Name" -Value $Value
}

# ---------------------------------------------------------------------------
# Download + install primitives
# ---------------------------------------------------------------------------

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$FriendlyName
    )
    Write-Info "Downloading $FriendlyName from $Url ..."
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        return $true
    } catch {
        Write-Fail "Download failed for $FriendlyName : $($_.Exception.Message)"
        return $false
    }
}

function Get-Latest7ZipRelease {
    # 7-Zip moved its releases to GitHub (ip7z/7zip) from 23.01 onward.
    # Use the existing GitHub resolver -- no scraping required.
    $pattern = if ($script:Architecture -eq 'arm64') { 'arm64\.exe$' } else { 'x64\.exe$' }
    return Get-GitHubLatestAsset -Repo 'ip7z/7zip' -Pattern $pattern -FriendlyName '7-Zip'
}

function Test-DownloadedFileHash {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$FriendlyName,
        [string]$ExpectedDigest
    )
    if (-not $VerifyChecksums) { return $true }
    if (-not $ExpectedDigest) {
        Write-Warn2 "No trusted checksum published for this $FriendlyName download -- verification skipped."
        return $true
    }
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
    if ($actual -eq $ExpectedDigest) {
        Write-Ok "$FriendlyName checksum verified."
        return $true
    }
    Write-Fail "$FriendlyName checksum MISMATCH. Expected $ExpectedDigest, got $actual."
    return $false
}

function Invoke-SilentInstaller {
    <#
        Explicit dispatch. .msi goes through msiexec.exe with the package
        passed via /i -- never via the shell 'Open' verb, which is what v2
        relied on implicitly. Reboot exit codes count as success.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FriendlyName,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.msi') {
        $exe     = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $argList = @('/i', ('"{0}"' -f $Path)) + $Arguments
    } else {
        $exe     = $Path
        $argList = $Arguments
    }

    Write-Info "Running silent install for $FriendlyName ..."
    $startParams = @{
        FilePath    = $exe
        Wait        = $true
        PassThru    = $true
        WindowStyle = 'Hidden'
    }
    if ($argList.Count -gt 0) { $startParams['ArgumentList'] = $argList }

    try {
        $proc = Start-Process @startParams
    } catch {
        Write-Fail "$FriendlyName installer could not be launched: $($_.Exception.Message)"
        return $false
    }

    $code = $proc.ExitCode
    if ($script:SuccessExitCodes -contains $code) {
        if ($code -eq 3010 -or $code -eq 1641) {
            $script:RebootPending = $true
            Write-Warn2 "$FriendlyName installed but requested a reboot (exit $code). Continuing."
        }
        return $true
    }
    Write-Fail "$FriendlyName installer returned exit code $code."
    return $false
}

# ---------------------------------------------------------------------------
# Latest-version resolvers
# ---------------------------------------------------------------------------

function Get-GitHubLatestAsset {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$FriendlyName
    )
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
            -Headers @{ 'User-Agent' = 'ClaudeCodeSandboxSetup' } -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
        if ($asset) {
            $digest = $null
            if ($asset.PSObject.Properties['digest'] -and
                $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
                $digest = $Matches[1].ToLower()
            }
            return @{ Url = $asset.browser_download_url; Digest = $digest }
        }
        Write-Warn2 "$FriendlyName : no release asset matched /$Pattern/."
    } catch {
        Write-Warn2 "$FriendlyName latest-version lookup failed: $($_.Exception.Message)"
    }
    return $null
}

function Get-LatestGitRelease {
    $pattern = if ($script:Architecture -eq 'arm64') { 'arm64\.exe$' } else { '64-bit\.exe$' }
    return Get-GitHubLatestAsset -Repo 'git-for-windows/git' -Pattern $pattern -FriendlyName 'Git'
}

function Get-LatestNotepadRelease {
    $pattern = if ($script:Architecture -eq 'arm64') { 'Installer\.arm64\.exe$' } else { 'Installer\.x64\.exe$' }
    return Get-GitHubLatestAsset -Repo 'notepad-plus-plus/notepad-plus-plus' -Pattern $pattern -FriendlyName 'Notepad++'
}

function Get-LatestGhRelease {
    $pattern = if ($script:Architecture -eq 'arm64') { 'windows_arm64\.msi$' } else { 'windows_amd64\.msi$' }
    return Get-GitHubLatestAsset -Repo 'cli/cli' -Pattern $pattern -FriendlyName 'GitHub CLI'
}

function Get-LatestSupabaseCliRelease {
    $pattern = if ($script:Architecture -eq 'arm64') { 'windows_arm64\.tar\.gz$' } else { 'windows_amd64\.tar\.gz$' }
    return Get-GitHubLatestAsset -Repo 'supabase/cli' -Pattern $pattern -FriendlyName 'Supabase CLI'
}

function Get-LatestNodeRelease {
    try {
        $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing
        $lts = $index | Where-Object { $_.lts -ne $false } | Select-Object -First 1
        if (-not $lts) { return $null }

        $suffix = if ($script:Architecture -eq 'arm64') { 'arm64' } else { 'x64' }
        $url    = "https://nodejs.org/dist/$($lts.version)/node-$($lts.version)-$suffix.msi"
        $digest = $null

        if ($VerifyChecksums) {
            try {
                # Digest keyed off the RESOLVED version, not a local temp path.
                $sums     = Invoke-WebRequest -Uri "https://nodejs.org/dist/$($lts.version)/SHASUMS256.txt" -UseBasicParsing
                $fileName = Split-Path $url -Leaf
                $line     = $sums.Content -split "`n" |
                            Where-Object { $_ -match [regex]::Escape($fileName) } |
                            Select-Object -First 1
                if ($line) { $digest = ($line -split '\s+')[0].ToLower() }
            } catch {
                Write-Warn2 "Could not fetch Node SHASUMS256.txt for $($lts.version); verification skipped."
            }
        }
        return @{ Url = $url; Digest = $digest }
    } catch {
        Write-Warn2 "Node.js latest-version lookup failed: $($_.Exception.Message)"
    }
    return $null
}

function Get-LatestPythonRelease {
    try {
        $html = Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/' -UseBasicParsing
        $versions = [regex]::Matches($html.Content, 'href="(\d+\.\d+\.\d+)/"') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notmatch '(a|b|rc)\d*$' } |
            Sort-Object { [Version]$_ } -Descending |
            Select-Object -First 8

        $suffix = if ($script:Architecture -eq 'arm64') { 'arm64' } else { 'amd64' }
        foreach ($ver in $versions) {
            $candidate = "https://www.python.org/ftp/python/$ver/python-$ver-$suffix.exe"
            try {
                $head = Invoke-WebRequest -Uri $candidate -Method Head -UseBasicParsing
                if ($head.StatusCode -eq 200) { return @{ Url = $candidate; Digest = $null } }
            } catch {
                continue
            }
        }
    } catch {
        Write-Warn2 "Python latest-version lookup failed: $($_.Exception.Message)"
    }
    return $null
}

# ---------------------------------------------------------------------------
# Generic installers
# ---------------------------------------------------------------------------

function Install-Tool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CommandCheck,
        [Parameter(Mandatory)][scriptblock]$LatestReleaseResolver,
        [Parameter(Mandatory)][string]$FallbackKey,
        [Parameter(Mandatory)][string[]]$SilentArgs
    )
    Write-Step "Checking $Name"

    if (-not $Force -and (Test-CommandExists -Name $CommandCheck)) {
        $version = (& $CommandCheck --version 2>$null | Select-Object -First 1)
        Write-Ok "$Name already installed: $version"
        Set-Result -Tool $Name -Status 'Present' -Detail "$version"
        return
    }

    $resolved = & $LatestReleaseResolver
    if (-not $resolved) {
        $archKey = "${FallbackKey}_$($script:Architecture)"
        if ($script:PinnedFallback.ContainsKey($archKey)) {
            Write-Warn2 "Using pinned fallback for $Name."
            $resolved = @{ Url = $script:PinnedFallback[$archKey]; Digest = $null }
        } else {
            Write-Fail "No download URL for $Name (dynamic lookup failed, no pinned fallback for $archKey)."
            Set-Result -Tool $Name -Status 'Failed' -Detail 'No URL resolvable.'
            return
        }
    }

    if ($DryRun) {
        Write-Info "[DRYRUN] Would install $Name from: $($resolved.Url)"
        if ($resolved.Digest) { Write-Info "[DRYRUN] Expected SHA256: $($resolved.Digest)" }
        Set-Result -Tool $Name -Status 'DryRun' -Detail $resolved.Url
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Download + silent install')) {
        Set-Result -Tool $Name -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $dest = Join-Path $script:TempDir (Split-Path $resolved.Url -Leaf)
    if (-not (Get-RemoteFile -Url $resolved.Url -Destination $dest -FriendlyName $Name)) {
        Set-Result -Tool $Name -Status 'Failed' -Detail 'Download failed.'
        return
    }
    if (-not (Test-DownloadedFileHash -FilePath $dest -FriendlyName $Name -ExpectedDigest $resolved.Digest)) {
        Set-Result -Tool $Name -Status 'Failed' -Detail 'Checksum mismatch.'
        return
    }

    $installed = Invoke-SilentInstaller -Path $dest -FriendlyName $Name -Arguments $SilentArgs
    Update-SessionPath

    if (Test-CommandExists -Name $CommandCheck) {
        Write-Ok "$Name installed successfully."
        Set-Result -Tool $Name -Status 'Installed'
    } elseif ($installed) {
        Write-Warn2 "$Name installed but '$CommandCheck' is not visible in this session. It will resolve in a new PowerShell window."
        Set-Result -Tool $Name -Status 'Warning' -Detail 'Installed; needs a new session for PATH.'
    } else {
        Write-Fail "$Name installation failed."
        Set-Result -Tool $Name -Status 'Failed' -Detail 'Installer reported failure.'
    }
}

function Install-RemoteScriptSafely {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$CommandCheck,
        [Parameter(Mandatory)][string]$ExpectedBinDir
    )
    Write-Step "Checking $Name"

    if (-not $Force -and (Test-CommandExists -Name $CommandCheck)) {
        Write-Ok "$Name already installed."
        Set-Result -Tool $Name -Status 'Present'
        return
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would install $Name via $Url"
        Set-Result -Tool $Name -Status 'DryRun' -Detail $Url
        return
    }

    $local = Join-Path $script:TempDir "$($Name -replace '\s', '').ps1"
    Write-Info "Downloading $Name installer script..."
    if (-not (Get-RemoteFile -Url $Url -Destination $local -FriendlyName "$Name installer")) {
        Set-Result -Tool $Name -Status 'Failed' -Detail 'Installer script download failed.'
        return
    }

    $hash = (Get-FileHash $local -Algorithm SHA256).Hash
    Write-Warn2 "SECURITY: $Name installer saved to $local"
    Write-Info "SHA256: $hash"

    if (-not $AcceptAll) {
        $ans = Read-Host "Execute downloaded $Name installer? (y/N)"
        if ($ans -ne 'y') {
            Write-Skip "$Name skipped by operator after hash review."
            Set-Result -Tool $Name -Status 'Skipped' -Detail 'Declined at hash review.'
            return
        }
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Execute downloaded installer')) {
        Set-Result -Tool $Name -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    # Isolated child process: vendor scripts must NOT inherit our
    # Set-StrictMode / $ErrorActionPreference. Running Grok's installer in
    # our scope is what produced the '$PSVersionTable.Platform' failure.
    try {
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $local) `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Warn2 "$Name installer exited with code $($proc.ExitCode)."
        }
    } catch {
        Write-Fail "$Name installer failed to launch: $($_.Exception.Message)"
        Set-Result -Tool $Name -Status 'Failed' -Detail 'Installer launch failed.'
        return
    }

    if (-not (Add-ToUserPath -Directory $ExpectedBinDir)) {
        $found = Get-ChildItem -Path $env:USERPROFILE -Filter "$CommandCheck.exe" `
            -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            Add-ToUserPath -Directory $found.DirectoryName | Out-Null
        } else {
            Write-Warn2 "Could not locate $CommandCheck.exe. Check the installer output for its path and add it to PATH manually."
        }
    }
    Update-SessionPath

    if (Test-CommandExists -Name $CommandCheck) {
        Write-Ok "$Name installed successfully."
        Set-Result -Tool $Name -Status 'Installed'
    } else {
        Write-Warn2 "$Name installed and PATH updated, but '$CommandCheck' is not visible in this session."
        Set-Result -Tool $Name -Status 'Warning' -Detail 'Installed; needs a new session for PATH.'
    }
}

# ---------------------------------------------------------------------------
# Tier 2 -- toolchains
# ---------------------------------------------------------------------------

function Install-Uv {
    # uv is a hard prerequisite for Strix: it provisions an isolated CPython
    # 3.12+ regardless of which Python landed in Tier 1.
    Install-RemoteScriptSafely -Name 'uv' -CommandCheck 'uv' `
        -Url 'https://astral.sh/uv/install.ps1' `
        -ExpectedBinDir $script:UserBinDir
}

function Install-Bun {
    Install-RemoteScriptSafely -Name 'Bun' -CommandCheck 'bun' `
        -Url 'https://bun.sh/install.ps1' `
        -ExpectedBinDir (Join-Path $env:USERPROFILE '.bun\bin')
}

function Install-Deno {
    Install-RemoteScriptSafely -Name 'Deno' -CommandCheck 'deno' `
        -Url 'https://deno.land/install.ps1' `
        -ExpectedBinDir (Join-Path $env:USERPROFILE '.deno\bin')
}

# ---------------------------------------------------------------------------
# Tier 3 -- CLI layer
# ---------------------------------------------------------------------------

function Install-ClaudeCode {
    Install-RemoteScriptSafely -Name 'Claude Code' -CommandCheck 'claude' `
        -Url 'https://claude.ai/install.ps1' `
        -ExpectedBinDir $script:UserBinDir
}

function Install-GrokBuild {
    $grokBinDir = if ($env:GROKBINDIR) { $env:GROKBINDIR } else { Join-Path $env:USERPROFILE '.grok\bin' }
    if ($Force -or -not (Test-CommandExists -Name 'grok')) {
        Write-Warn2 "Grok Build is gated to SuperGrok / X Premium+ accounts. Install will succeed; first-run OAuth will fail without an eligible subscription."
    }
    Install-RemoteScriptSafely -Name 'Grok Build' -CommandCheck 'grok' `
        -Url 'https://x.ai/cli/install.ps1' `
        -ExpectedBinDir $grokBinDir
}

function Install-OpenCode {
    Write-Step "Checking OpenCode"

    if (-not $Force -and (Test-CommandExists -Name 'opencode')) {
        Write-Ok "OpenCode already installed."
        Set-Result -Tool 'OpenCode' -Status 'Present'
        return
    }
    if (-not (Test-CommandExists -Name 'npm')) {
        Write-Warn2 "npm not found (Node.js skipped or failed). OpenCode requires npm on Windows."
        Set-Result -Tool 'OpenCode' -Status 'Skipped' -Detail 'npm unavailable.'
        return
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would run: npm install -g opencode-ai"
        Set-Result -Tool 'OpenCode' -Status 'DryRun'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('OpenCode', 'npm install -g opencode-ai')) {
        Set-Result -Tool 'OpenCode' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    Write-Info "Installing OpenCode via npm..."
    # Call operator, not Start-Process: npm is a .cmd shim, and
    # Start-Process on it fails with 'not a valid Win32 application'.
    $env:npm_config_yes = 'true'
    & npm install -g opencode-ai --no-fund --no-audit
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "OpenCode install failed (npm exit code $LASTEXITCODE)."
        Set-Result -Tool 'OpenCode' -Status 'Failed' -Detail "npm exit $LASTEXITCODE"
        return
    }

    Update-SessionPath
    if (Test-CommandExists -Name 'opencode') {
        Write-Ok "OpenCode installed successfully."
        Set-Result -Tool 'OpenCode' -Status 'Installed'
    } else {
        Write-Warn2 "OpenCode installed but not visible in this session."
        Set-Result -Tool 'OpenCode' -Status 'Warning' -Detail 'Needs a new session for PATH.'
    }
}

function Install-Vite {
    # Vite is installed as a global npm package providing a 'vite' CLI.
    # It acts as both a development server (vite) and a build tool (vite build / vite preview).
    # Node.js must be present (Tier 1) before this Tier 3 stage runs.
    Write-Step "Checking Vite (dev server / build tool)"

    if (-not $Force -and (Test-CommandExists -Name 'vite')) {
        $ver = (& vite --version 2>$null | Select-Object -First 1)
        Write-Ok "Vite already installed: $ver"
        Set-Result -Tool 'Vite' -Status 'Present' -Detail "$ver"
        return
    }
    if (-not (Test-CommandExists -Name 'npm')) {
        Write-Warn2 "npm not found (Node.js skipped or failed). Vite requires npm."
        Set-Result -Tool 'Vite' -Status 'Skipped' -Detail 'npm unavailable.'
        return
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would run: npm install -g vite"
        Set-Result -Tool 'Vite' -Status 'DryRun'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Vite', 'npm install -g vite')) {
        Set-Result -Tool 'Vite' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    Write-Info "Installing Vite via npm (global) ..."
    # npm is a .cmd shim -- use the call operator, not Start-Process.
    $env:npm_config_yes = 'true'
    & npm install -g vite --no-fund --no-audit
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Vite install failed (npm exit code $LASTEXITCODE)."
        Set-Result -Tool 'Vite' -Status 'Failed' -Detail "npm exit $LASTEXITCODE"
        return
    }

    Update-SessionPath
    if (Test-CommandExists -Name 'vite') {
        $ver = (& vite --version 2>$null | Select-Object -First 1)
        Write-Ok "Vite installed: $ver"
        Write-Info "  Dev server  : vite                 (watches src/, serves on http://localhost:5173)"
        Write-Info "  Build       : vite build            (outputs dist/)"
        Write-Info "  Preview     : vite preview          (serves the built dist/ on http://localhost:4173)"
        Set-Result -Tool 'Vite' -Status 'Installed' -Detail "$ver"
    } else {
        Write-Warn2 "Vite installed but not visible in this session. Open a new PowerShell window."
        Set-Result -Tool 'Vite' -Status 'Warning' -Detail 'Needs a new session for PATH.'
    }
}

function Install-SupabaseCli {
    Write-Step "Checking Supabase CLI"

    if (-not $Force -and (Test-CommandExists -Name 'supabase')) {
        Write-Ok "Supabase CLI already installed."
        Set-Result -Tool 'Supabase CLI' -Status 'Present'
        return
    }
    Write-Warn2 "'supabase start' needs the Docker stack, which needs virtualization Windows Sandbox does not expose. Remote-project commands (login, link, db push/pull, functions deploy, gen types) work normally."

    $resolved = Get-LatestSupabaseCliRelease
    if (-not $resolved) {
        $archKey = "Supabase_$($script:Architecture)"
        if ($script:PinnedFallback.ContainsKey($archKey)) {
            $resolved = @{ Url = $script:PinnedFallback[$archKey]; Digest = $null }
        } else {
            Write-Fail "No pinned fallback for $archKey."
            Set-Result -Tool 'Supabase CLI' -Status 'Failed' -Detail 'No URL resolvable.'
            return
        }
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would install Supabase CLI from: $($resolved.Url)"
        Set-Result -Tool 'Supabase CLI' -Status 'DryRun' -Detail $resolved.Url
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Supabase CLI', 'Download + extract')) {
        Set-Result -Tool 'Supabase CLI' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $archivePath = Join-Path $script:TempDir (Split-Path $resolved.Url -Leaf)
    if (-not (Get-RemoteFile -Url $resolved.Url -Destination $archivePath -FriendlyName 'Supabase CLI')) {
        Set-Result -Tool 'Supabase CLI' -Status 'Failed' -Detail 'Download failed.'
        return
    }
    if (-not (Test-DownloadedFileHash -FilePath $archivePath -FriendlyName 'Supabase CLI' -ExpectedDigest $resolved.Digest)) {
        Set-Result -Tool 'Supabase CLI' -Status 'Failed' -Detail 'Checksum mismatch.'
        return
    }

    $extractDir = Join-Path $env:LOCALAPPDATA 'SupabaseCLI'
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Write-Info "Extracting with tar.exe (built into Windows 10 1803+/11) ..."
    & tar.exe -xzf $archivePath -C $extractDir
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Supabase CLI extraction failed (tar exit $LASTEXITCODE)."
        Set-Result -Tool 'Supabase CLI' -Status 'Failed' -Detail "tar exit $LASTEXITCODE"
        return
    }

    Add-ToUserPath -Directory $extractDir | Out-Null
    Update-SessionPath

    if (Test-CommandExists -Name 'supabase') {
        Write-Ok "Supabase CLI installed successfully."
        Set-Result -Tool 'Supabase CLI' -Status 'Installed'
    } else {
        Write-Warn2 "Supabase CLI extracted to $extractDir but not visible in this session."
        Set-Result -Tool 'Supabase CLI' -Status 'Warning' -Detail 'Needs a new session for PATH.'
    }
}

function Test-DockerDaemon {
    if (-not (Test-CommandExists -Name 'docker')) { return $false }
    $null = & docker info 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Test-MsvcLinker {
    # link.exe lives in VS / Build Tools installs. uv can build from source
    # only when it is present; absent, any package with a Rust/C extension
    # that has no pre-built Windows wheel will fail.
    $hints = @(
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\BuildTools'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools')
    )
    foreach ($base in $hints) {
        if (-not (Test-Path -LiteralPath $base -ErrorAction SilentlyContinue)) { continue }
        $found = Get-ChildItem -Path $base -Filter 'link.exe' -Recurse -Depth 8 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $true }
    }
    # Also accept a toolchain already on PATH (e.g. LLVM clang-link).
    return (Test-CommandExists -Name 'link')
}

function Install-Strix {
    <#
        Strix requirements, per usestrix/strix pyproject.toml:
          * Python >= 3.12  (requires-python = ">=3.12")
          * PyPI package strix-agent (console script: strix)
          * A RUNNING Docker engine (runtime dep: docker>=7.1.0 SDK)
          * STRIX_LLM + LLM_API_KEY env vars

        The documented bash installer is unusable natively on Windows.
        'uv tool install' is the correct equivalent: isolated venv, PATH
        shim, uv provisions CPython 3.12 itself if system Python is older.

        LITELLM RUST NOTE
        strix-agent >= 1.4.0 pulls openai-agents[litellm]==0.14.6, which
        resolves litellm >= 1.89.0. From 1.89.x onward litellm ships a Rust
        extension (litellm-rust / pyo3 / maturin). There is no pre-built
        win_amd64 wheel for this extension, so uv must compile it from
        source -- which requires the MSVC linker (link.exe). Windows Sandbox
        has no MSVC Build Tools, so the build fails with "linker not found".

        FIX: two-attempt strategy.
          Attempt 1 -- unconstrained: works on any host with MSVC installed.
          Attempt 2 -- constrained to litellm<1.89.0: this is the last
            release with a pure-Python sdist; uv resolves it from the cache
            or downloads the ~30 MB tarball and installs in seconds, no
            Rust/MSVC dependency. Compatible with openai-agents[litellm]==
            0.14.6 because that package only requires litellm>=X for some X
            below 1.89.0.
    #>
    Write-Step "Checking Strix (AI pentesting agent)"

    if (-not $Force -and (Test-CommandExists -Name 'strix')) {
        Write-Ok "Strix already installed."
        Set-Result -Tool 'Strix' -Status 'Present'
    }
    else {
        if (-not (Test-CommandExists -Name 'uv')) {
            Write-Warn2 "uv not found. Strix installs through uv -- ensure Tier 2 runs first, or drop -SkipUv."
            Set-Result -Tool 'Strix' -Status 'Skipped' -Detail 'uv unavailable.'
            return
        }
        if ($DryRun) {
            Write-Info "[DRYRUN] Would run: uv tool install strix-agent --python 3.12 (with litellm fallback if MSVC absent)"
            Set-Result -Tool 'Strix' -Status 'DryRun'
            return
        }
        if (-not $PSCmdlet.ShouldProcess('Strix', 'uv tool install strix-agent')) {
            Set-Result -Tool 'Strix' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
            return
        }

        # NOTE: never assign to $args -- it is a PowerShell automatic variable.
        $uvArgs = @('tool', 'install', 'strix-agent', '--python', '3.12')
        if ($Force) { $uvArgs += '--force' }

        $hasMsvc = Test-MsvcLinker
        if (-not $hasMsvc) {
            Write-Warn2 "MSVC linker (link.exe) not found. litellm >= 1.89.0 ships a Rust extension that requires it. Will attempt install with litellm<1.89.0 constraint (pre-Rust release, pure-Python wheel, no build step)."
        }

        $installed = $false

        if ($hasMsvc) {
            # Attempt 1: unconstrained -- lets uv pick the latest litellm.
            Write-Info "Attempt 1: unconstrained install (MSVC present)..."
            & uv @uvArgs
            if ($LASTEXITCODE -eq 0) { $installed = $true }
            else { Write-Warn2 "Unconstrained install failed (exit $LASTEXITCODE). Falling back to litellm<1.89.0 constraint." }
        }

        if (-not $installed) {
            # Attempt 2: constrain litellm to the last pure-Python release.
            # litellm 1.88.0 (Jun 6 2026) is the last stable without the
            # maturin/Rust build requirement. 1.89.0+ added the Rust core.
            $constraintPath = Join-Path $script:TempDir 'strix-litellm-constraint.txt'
            Set-Content -Path $constraintPath -Value 'litellm<1.89.0' -Encoding UTF8
            $uvArgsC = $uvArgs + @('--constraint', $constraintPath)
            # --reinstall ensures a partial Attempt 1 artefact doesn't block.
            if ($Force -or -not $hasMsvc) { $uvArgsC += '--reinstall' }
            Write-Info "Attempt 2: install with litellm<1.89.0 (pure-Python, no Rust build)..."
            & uv @uvArgsC
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
                Write-Warn2 "Strix installed with litellm < 1.89.0 (no Rust extension). Functionality is identical for scanning; the embedded Rust performance layer is absent. Install MSVC Build Tools and re-run with -Force to upgrade."
            }
        }

        if (-not $installed) {
            Write-Fail "strix-agent installation failed on both attempts."
            Write-Fail "To fix: install Visual Studio 2022 Build Tools with the 'Desktop development with C++' workload, then re-run with -Force -SkipNode -SkipBun -SkipDeno (skip already-present tools)."
            Set-Result -Tool 'Strix' -Status 'Failed' -Detail 'Both constrained and unconstrained uv install failed.'
            return
        }

        Add-ToUserPath -Directory $script:UserBinDir | Out-Null
        Update-SessionPath

        if (Test-CommandExists -Name 'strix') {
            Write-Ok "Strix installed successfully."
            Set-Result -Tool 'Strix' -Status 'Installed'
        } else {
            Write-Warn2 "strix-agent installed but 'strix' is not visible in this session."
            Set-Result -Tool 'Strix' -Status 'Warning' -Detail 'Needs a new session for PATH.'
        }
    }

    # Runtime capability check -- report honestly, not aspirationally.
    if (Test-InWindowsSandbox) {
        Write-Warn2 "Windows Sandbox detected. Strix scans run inside a Docker container; Sandbox does not expose nested virtualization, so the Docker engine cannot start here. 'strix --help' works, scans will not. Run Strix on a physical host or VM with nested virtualization enabled."
    } elseif (-not (Test-DockerDaemon)) {
        Write-Warn2 "Docker daemon not reachable. Strix needs a running engine and pulls its sandbox image (~2 GB) on first scan."
    } else {
        Write-Ok "Docker daemon reachable -- Strix will pull its sandbox image on first scan."
    }
}

function Set-StrixEnvironment {
    Write-Step "Configuring Strix environment"

    if (-not $StrixLlm -and -not $StrixApiKey) {
        Write-Skip "No -StrixLlm / -StrixApiKey supplied. Strix will prompt on first run; it caches answers to ~/.strix/cli-config.json."
        Set-Result -Tool 'Strix config' -Status 'Skipped' -Detail 'No credentials supplied.'
        return
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would set STRIX_LLM / LLM_API_KEY (+ optional LLM_API_BASE, PERPLEXITY_API_KEY) at User scope."
        Set-Result -Tool 'Strix config' -Status 'DryRun'
        return
    }

    Write-Warn2 "API keys are written to the User environment (registry). On a persistent host this survives reboots -- clear them when done. Inside Windows Sandbox everything is discarded on close."

    Set-PersistentEnvVar -Name 'STRIX_LLM'          -Value $StrixLlm
    Set-PersistentEnvVar -Name 'LLM_API_KEY'        -Value $StrixApiKey
    Set-PersistentEnvVar -Name 'LLM_API_BASE'       -Value $StrixApiBase
    Set-PersistentEnvVar -Name 'PERPLEXITY_API_KEY' -Value $PerplexityApiKey

    if (-not $StrixLlm)    { Write-Warn2 "STRIX_LLM not set -- Strix will prompt for the model on first run." }
    if (-not $StrixApiKey) { Write-Warn2 "LLM_API_KEY not set -- Strix will prompt for the key on first run." }

    Write-Ok "Strix environment configured."
    Set-Result -Tool 'Strix config' -Status 'Installed' -Detail 'Environment variables set at User scope.'
}

# ---------------------------------------------------------------------------
# Tier 3.5 -- MCP servers (npm packages)
# ---------------------------------------------------------------------------

function Install-McpServers {
    <#
        All five installable MCP servers from the v3.2 spec are pure Node.js
        packages and run via `npx -y <pkg>` or as global bins. None require
        Docker, so they behave correctly inside Windows Sandbox. Supabase MCP
        talks to a cloud project by default; the local 'supabase start' stack
        still needs Docker (documented in Install-SupabaseCli).
    #>
    Write-Step "Installing MCP servers (npm global)"

    if (-not (Test-CommandExists -Name 'npm')) {
        Write-Warn2 "Node.js/npm not found (Tier 1 skipped). MCP servers require npm."
        Set-Result -Tool 'MCP servers' -Status 'Skipped' -Detail 'npm unavailable.'
        return
    }
    $packages = @($script:McpServerMap.Values)

    if ($DryRun) {
        Write-Info "[DRYRUN] Would install $($packages.Count) MCP packages via npm -g:"
        foreach ($pkg in $packages) { Write-Info "  - $pkg" }
        Set-Result -Tool 'MCP servers' -Status 'DryRun' -Detail ($packages -join ', ')
        return
    }
    if (-not $PSCmdlet.ShouldProcess('MCP servers', 'npm install -g (multiple packages)')) {
        Set-Result -Tool 'MCP servers' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $env:npm_config_yes = 'true'
    $installed = 0
    $failed    = @()

    foreach ($pkg in $packages) {
        Write-Info "Installing $pkg ..."
        # npm is a .cmd shim -- use the call operator, not Start-Process.
        & npm install -g $pkg --no-fund --no-audit
        if ($LASTEXITCODE -eq 0) {
            $installed++
        } else {
            Write-Warn2 "$pkg installation failed (npm exit $LASTEXITCODE)."
            $failed += $pkg
        }
    }

    Update-SessionPath

    if ($failed.Count -eq 0) {
        Write-Ok "All $($packages.Count) MCP servers installed."
        Set-Result -Tool 'MCP servers' -Status 'Installed' -Detail "$installed/$($packages.Count) packages"
    } elseif ($installed -gt 0) {
        Write-Warn2 "Partial MCP install: $installed succeeded, $($failed.Count) failed ($($failed -join ', '))."
        Set-Result -Tool 'MCP servers' -Status 'Warning' -Detail "Failed: $($failed -join ', ')"
    } else {
        Write-Fail "All MCP server installs failed."
        Set-Result -Tool 'MCP servers' -Status 'Failed' -Detail 'Every npm install returned non-zero.'
    }
}

function Configure-OpencodeMcp {
    <#
        Registers the same six MCP servers with opencode by writing them into
        the GLOBAL opencode config (~/.config/opencode/opencode.json), so they
        are available in every project, not just C:\Git\clrogon.

        Uses opencode's own schema (mcp key, type: local, command as an array).
        Existing config is preserved: only the named servers are merged in,
        and $schema is added if absent.

        opencode loads config once at startup and never hot-reloads it, so the
        servers appear only after opencode is restarted.
    #>
    Write-Step "Registering MCP servers with opencode"

    $configDir  = Join-Path $env:USERPROFILE '.config\opencode'
    $configPath = Join-Path $configDir 'opencode.json'
    $serverMap  = $script:McpServerMap

    if ($DryRun) {
        Write-Info "[DRYRUN] Would register $($serverMap.Count) MCP servers in $configPath"
        Set-Result -Tool 'Opencode MCP' -Status 'DryRun' -Detail $configPath
        return
    }
    if (-not $PSCmdlet.ShouldProcess('opencode', 'Write MCP servers into global opencode.json')) {
        Set-Result -Tool 'Opencode MCP' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $config = @{}
    if (Test-Path -LiteralPath $configPath) {
        try {
            $existing = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
            if ($existing -and $existing -isnot [System.Array]) {
                foreach ($prop in $existing.PSObject.Properties) {
                    $config[$prop.Name] = $prop.Value
                }
            } else {
                Write-Warn2 "$configPath is not a JSON object -- rebuilding from scratch."
            }
        } catch {
            Write-Warn2 "Could not parse existing $configPath : $($_.Exception.Message) -- rebuilding from scratch."
        }
    }

    $mcp = @{}
    if ($config.ContainsKey('mcp') -and $config['mcp']) {
        foreach ($prop in $config['mcp'].PSObject.Properties) {
            $mcp[$prop.Name] = $prop.Value
        }
    }

    foreach ($key in $serverMap.Keys) {
        $mcp[$key] = [ordered]@{
            type    = 'local'
            command = @('npx', '-y', $serverMap[$key])
            enabled = $true
        }
    }
    $config['mcp'] = $mcp
    if (-not $config.ContainsKey('$schema')) {
        $config['$schema'] = 'https://opencode.ai/config.json'
    }

    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    try {
        # Write without a BOM: PowerShell 5.1's Set-Content -Encoding UTF8
        # prepends one, and opencode's strict JSON parser rejects it.
        $json = $config | ConvertTo-Json -Depth 20
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($configPath, $json, $utf8NoBom)
        Write-Ok "MCP servers registered in opencode global config: $configPath"
        Write-Warn2 "Restart opencode for the MCP servers to be picked up (config loads once at startup)."
        Set-Result -Tool 'Opencode MCP' -Status 'Installed' -Detail $configPath
    } catch {
        Write-Fail "Could not write opencode config: $($_.Exception.Message)"
        Set-Result -Tool 'Opencode MCP' -Status 'Failed' -Detail $_.Exception.Message
    }
}

function Configure-SentryEnvironment {
    <#
        Sentry MCP reads SENTRY_AUTH_TOKEN and SENTRY_ORG from the
        environment. Set both at User scope so they survive new shells.
        Inside Windows Sandbox everything is discarded on close, same
        caveat as Strix config.
    #>
    Write-Step "Configuring Sentry MCP environment"

    if (-not $SentryAuthToken -and -not $SentryOrg) {
        Write-Skip "No -SentryAuthToken / -SentryOrg supplied. Sentry MCP will prompt at first use."
        Set-Result -Tool 'Sentry config' -Status 'Skipped' -Detail 'No credentials supplied.'
        return
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would set SENTRY_AUTH_TOKEN / SENTRY_ORG at User scope."
        Set-Result -Tool 'Sentry config' -Status 'DryRun'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Sentry config', 'Write SENTRY_AUTH_TOKEN / SENTRY_ORG to User environment')) {
        Set-Result -Tool 'Sentry config' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    Set-PersistentEnvVar -Name 'SENTRY_AUTH_TOKEN' -Value $SentryAuthToken
    Set-PersistentEnvVar -Name 'SENTRY_ORG'        -Value $SentryOrg

    if (-not $SentryAuthToken) { Write-Warn2 "SENTRY_AUTH_TOKEN not set -- Sentry MCP will fail authenticated calls." }
    if (-not $SentryOrg)       { Write-Warn2 "SENTRY_ORG not set -- Sentry MCP will require it at runtime."            }

    Write-Ok "Sentry MCP environment configured."
    Set-Result -Tool 'Sentry config' -Status 'Installed' -Detail 'User-scope env vars set.'
}

# ---------------------------------------------------------------------------
# Tier 7 -- workspace + GitHub auth + repo picker
# ---------------------------------------------------------------------------

function Initialize-Workspace {
    <#
        Creates C:\Git\clrogon and the recommended subfolder tree. Idempotent:
        re-running on an existing tree is a no-op. This runs BEFORE the GitHub
        stages so Connect-GitHub / Select-GitHubRepository have a destination.
    #>
    Write-Step "Creating clrogon workspace tree"

    if ($DryRun) {
        Write-Info "[DRYRUN] Would create $script:WorkspaceRoot and $($script:WorkspaceFolders.Count) subfolders."
        Set-Result -Tool 'Workspace' -Status 'DryRun' -Detail $script:WorkspaceRoot
        return
    }
    if (-not $PSCmdlet.ShouldProcess('clrogon workspace', 'Create directories')) {
        Set-Result -Tool 'Workspace' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    if (-not (Test-Path -LiteralPath $script:WorkspaceRoot)) {
        New-Item -ItemType Directory -Path $script:WorkspaceRoot -Force | Out-Null
    }
    foreach ($folder in $script:WorkspaceFolders) {
        $path = Join-Path $script:WorkspaceRoot $folder
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    Write-Ok "Workspace ready at $script:WorkspaceRoot"
    Set-Result -Tool 'Workspace' -Status 'Installed' -Detail $script:WorkspaceRoot
}

function Connect-GitHub {
    <#
        Runs `gh auth login --web` when not already authenticated. The web
        flow opens the default browser, so this is intentionally skipped
        under -DryRun and when -AcceptAll is paired with -SkipWorkspace.
    #>
    Write-Step "GitHub authentication"

    if (-not (Test-CommandExists -Name 'gh')) {
        Write-Warn2 "GitHub CLI not installed (Tier 3 skipped or failed). Skipping auth."
        Set-Result -Tool 'GitHub auth' -Status 'Skipped' -Detail 'gh unavailable.'
        return
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would run: gh auth login --hostname github.com --git-protocol https --web"
        Set-Result -Tool 'GitHub auth' -Status 'DryRun'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('GitHub', 'gh auth login')) {
        Set-Result -Tool 'GitHub auth' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    # gh auth status exits 0 when authenticated, non-zero otherwise. Redirect
    # both streams so an unauthenticated state never surfaces as a red error.
    $already = $false
    try {
        & gh auth status *> $null
        if ($LASTEXITCODE -eq 0) { $already = $true }
    } catch { }

    if ($already) {
        Write-Ok "Already authenticated to GitHub."
        Set-Result -Tool 'GitHub auth' -Status 'Present' -Detail 'gh auth status OK'
        return
    }

    Write-Info "Browser authentication will open. Complete the device flow in your default browser."
    Write-Info "If the browser does not appear, copy the displayed code to https://github.com/login/device"
    & gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "gh auth login returned exit code $LASTEXITCODE -- authentication may be incomplete."
        Set-Result -Tool 'GitHub auth' -Status 'Warning' -Detail "gh auth login exit $LASTEXITCODE"
        return
    }

    & gh auth status
    Write-Ok "Authenticated to GitHub."
    Set-Result -Tool 'GitHub auth' -Status 'Installed'
}

function Select-GitHubRepository {
    <#
        Lists the authenticated user's repos (defaults to whichever account
        `gh auth status` is logged in as; override with -GithubUser to browse
        someone else's public repos), presents a numbered menu, clones the
        selection into C:\Git\clrogon\projects\<name>, opens it in VS Code, and persists
        the path to CLAUDIO_CURRENT_REPO (User scope) so downstream MCPs,
        Claude Code, OpenCode, Strix, and VS Code tasks can discover the
        active project without re-prompting.

        Skipped under -DryRun. Under -AcceptAll without -SkipWorkspace it
        still runs because cloning requires a human pick -- there is no
        safe default repo to auto-clone.
    #>
    Write-Step "Selecting GitHub repository to clone"

    if ($DryRun) {
        $dryRunUser = if ($GithubUser) { $GithubUser } else { '<gh-authenticated-user>' }
        Write-Info "[DRYRUN] Would: gh repo list $dryRunUser --limit 200, present menu, clone selection into $script:WorkspaceRoot\projects"
        Set-Result -Tool 'Repository clone' -Status 'DryRun'
        return
    }
    if (-not (Test-CommandExists -Name 'gh')) {
        Write-Warn2 "GitHub CLI not found -- repo picker skipped."
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'gh unavailable.'
        return
    }
    if (-not (Test-CommandExists -Name 'git')) {
        Write-Warn2 "git not found -- repo picker skipped."
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'git unavailable.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('GitHub repository', 'List, prompt, clone, open in VS Code')) {
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    # Verify auth before listing -- otherwise gh repo list returns empty
    # with a non-obvious stderr message.
    $authed = $false
    try {
        & gh auth status *> $null
        if ($LASTEXITCODE -eq 0) { $authed = $true }
    } catch { }
    if (-not $authed) {
        Write-Warn2 "Not authenticated to GitHub. Run Connect-GitHub first (or re-run without -SkipWorkspace)."
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'gh not authenticated.'
        return
    }

    if (-not $GithubUser) {
        $GithubUser = (& gh api user --jq '.login' 2>$null)
        if (-not $GithubUser) {
            Write-Warn2 "Could not resolve the authenticated GitHub user -- pass -GithubUser explicitly."
            Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'GithubUser not resolved.'
            return
        }
    }

    Write-Info "Loading repositories for '$GithubUser' (limit 200) ..."
    $raw = & gh repo list $GithubUser --limit 200 --json name,url,updatedAt,isPrivate 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        Write-Warn2 "gh repo list returned no repositories (exit $LASTEXITCODE)."
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'No repositories listed.'
        return
    }

    $repos = $raw | ConvertFrom-Json
    if (-not $repos -or $repos.Count -eq 0) {
        Write-Warn2 "No repositories visible for '$GithubUser'."
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'Empty repo list.'
        return
    }

    # Sort: most recently updated first, so the active projects float to top.
    $repos = @($repos | Sort-Object updatedAt -Descending)

    Write-Host ""
    Write-Host "Repositories for $GithubUser" -ForegroundColor White
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    for ($i = 0; $i -lt $repos.Count; $i++) {
        $priv = if ($repos[$i].isPrivate) { '(private)' } else { '' }
        Write-Host ("[{0,3}] {1,-32} {2} {3}" -f ($i + 1), $repos[$i].name, $repos[$i].updatedAt, $priv)
    }
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "  0  Cancel" -ForegroundColor Gray
    Write-Host ""

    $selection = Read-Host "Select repository number (1-$($repos.Count), 0 to cancel)"
    if (-not $selection) { $selection = '0' }
    $idx = 0
    if (-not ([int]::TryParse($selection, [ref]$idx))) {
        Write-Warn2 "Invalid selection '$selection' -- must be a number."
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'Non-numeric selection.'
        return
    }
    if ($idx -eq 0) {
        Write-Skip "Repository clone cancelled by user."
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'User cancelled.'
        return
    }
    if ($idx -lt 1 -or $idx -gt $repos.Count) {
        Write-Warn2 "Selection out of range: $idx (must be 1-$($repos.Count))."
        Set-Result -Tool 'Repository clone' -Status 'Skipped' -Detail 'Out of range.'
        return
    }

    $repo = $repos[$idx - 1]
    $destination = Join-Path $script:WorkspaceRoot "projects\$($repo.name)"
    $destination = [System.IO.Path]::GetFullPath($destination)

    if (Test-Path -LiteralPath $destination) {
        Write-Ok "Repository already present at $destination -- skipping clone."
    } else {
        Write-Info "Cloning $($repo.url) into $destination ..."
        & gh repo clone "$GithubUser/$($repo.name)" $destination
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "gh repo clone failed (exit $LASTEXITCODE)."
            Set-Result -Tool 'Repository clone' -Status 'Failed' -Detail "gh repo clone exit $LASTEXITCODE"
            return
        }
        Write-Ok "Repository cloned to $destination"
    }

    # Persist the active project so MCPs / Claude Code / OpenCode / Strix /
    # VS Code tasks can auto-discover the workspace without re-prompting.
    [Environment]::SetEnvironmentVariable('CLAUDIO_CURRENT_REPO', $destination, 'User')
    Set-Item -Path 'Env:CLAUDIO_CURRENT_REPO' -Value $destination
    Write-Ok "CLAUDIO_CURRENT_REPO = $destination (User scope)"

    if (Test-CommandExists -Name 'code') {
        Write-Info "Opening repository in VS Code (headless launch) ..."
        & code $destination
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 "'code $destination' returned exit $LASTEXITCODE -- VS Code may not be on PATH yet."
        }
    } else {
        Write-Warn2 "VS Code 'code' CLI not found in this session. Open $destination manually once PATH refreshes."
    }

    Set-Result -Tool 'Repository clone' -Status 'Installed' -Detail $destination
}

# ---------------------------------------------------------------------------
# Tier 4 -- heavy / GUI
# ---------------------------------------------------------------------------

function Install-VSCode {
    # The "always latest" endpoint has no filename in its path, so
    # Split-Path -Leaf yields 'stable' with no extension. Named explicitly.
    Write-Step "Checking VS Code"

    if (-not $Force -and (Test-CommandExists -Name 'code')) {
        Write-Ok "VS Code already installed."
        Set-Result -Tool 'VS Code' -Status 'Present'
        return
    }
    $suffix = if ($script:Architecture -eq 'arm64') { 'win32-arm64' } else { 'win32-x64' }
    $url    = "https://update.code.visualstudio.com/latest/$suffix/stable"

    if ($DryRun) {
        Write-Info "[DRYRUN] Would install VS Code from: $url"
        Set-Result -Tool 'VS Code' -Status 'DryRun' -Detail $url
        return
    }
    if (-not $PSCmdlet.ShouldProcess('VS Code', 'Download + silent install')) {
        Set-Result -Tool 'VS Code' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $dest = Join-Path $script:TempDir "VSCodeSetup-$suffix.exe"
    if (-not (Get-RemoteFile -Url $url -Destination $dest -FriendlyName 'VS Code')) {
        Set-Result -Tool 'VS Code' -Status 'Failed' -Detail 'Download failed.'
        return
    }

    $installed = Invoke-SilentInstaller -Path $dest -FriendlyName 'VS Code' `
        -Arguments @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/MERGETASKS=!runcode,addtopath')
    Update-SessionPath

    if (Test-CommandExists -Name 'code') {
        Write-Ok "VS Code installed successfully."
        Set-Result -Tool 'VS Code' -Status 'Installed'
    } elseif ($installed) {
        Write-Warn2 "VS Code installed but 'code' is not visible in this session."
        Set-Result -Tool 'VS Code' -Status 'Warning' -Detail 'Needs a new session for PATH.'
    } else {
        Set-Result -Tool 'VS Code' -Status 'Failed' -Detail 'Installer reported failure.'
    }
}

function Test-NotepadInstalled {
    # Not via Get-Command: the NSIS installer never adds itself to PATH.
    return (Test-Path (Join-Path $env:ProgramFiles 'Notepad++\notepad++.exe'))
}

function Install-Notepad {
    Write-Step "Checking Notepad++"

    if (-not $Force -and (Test-NotepadInstalled)) {
        Write-Ok "Notepad++ already installed."
        Set-Result -Tool 'Notepad++' -Status 'Present'
        return
    }
    $resolved = Get-LatestNotepadRelease
    if (-not $resolved) {
        $archKey = "Notepad_$($script:Architecture)"
        if ($script:PinnedFallback.ContainsKey($archKey)) {
            $resolved = @{ Url = $script:PinnedFallback[$archKey]; Digest = $null }
        } else {
            Write-Fail "No pinned fallback for $archKey."
            Set-Result -Tool 'Notepad++' -Status 'Failed' -Detail 'No URL resolvable.'
            return
        }
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would install Notepad++ from: $($resolved.Url)"
        Set-Result -Tool 'Notepad++' -Status 'DryRun' -Detail $resolved.Url
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Notepad++', 'Download + silent install')) {
        Set-Result -Tool 'Notepad++' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $dest = Join-Path $script:TempDir (Split-Path $resolved.Url -Leaf)
    if (-not (Get-RemoteFile -Url $resolved.Url -Destination $dest -FriendlyName 'Notepad++')) {
        Set-Result -Tool 'Notepad++' -Status 'Failed' -Detail 'Download failed.'
        return
    }
    if (-not (Test-DownloadedFileHash -FilePath $dest -FriendlyName 'Notepad++' -ExpectedDigest $resolved.Digest)) {
        Set-Result -Tool 'Notepad++' -Status 'Failed' -Detail 'Checksum mismatch.'
        return
    }

    $installed = Invoke-SilentInstaller -Path $dest -FriendlyName 'Notepad++' -Arguments @('/S')

    if (Test-NotepadInstalled) {
        Add-ToUserPath -Directory (Join-Path $env:ProgramFiles 'Notepad++') | Out-Null
        Update-SessionPath
        Write-Ok "Notepad++ installed successfully."
        Set-Result -Tool 'Notepad++' -Status 'Installed'
    } elseif ($installed) {
        Write-Warn2 "Notepad++ installer reported success but the binary was not found under Program Files."
        Set-Result -Tool 'Notepad++' -Status 'Warning' -Detail 'Binary not found at expected path.'
    } else {
        Set-Result -Tool 'Notepad++' -Status 'Failed' -Detail 'Installer reported failure.'
    }
}

function Test-7ZipInstalled {
    # The 7-Zip NSIS installer does not add itself to PATH by default.
    # Probe the fixed install directory, consistent with Test-NotepadInstalled.
    return (Test-Path (Join-Path $env:ProgramFiles '7-Zip\7z.exe'))
}

function Install-7Zip {
    Write-Step "Checking 7-Zip"

    if (-not $Force -and (Test-7ZipInstalled)) {
        Write-Ok "7-Zip already installed."
        Set-Result -Tool '7-Zip' -Status 'Present'
        return
    }
    $resolved = Get-Latest7ZipRelease
    if (-not $resolved) {
        $archKey = "SevenZip_$($script:Architecture)"
        if ($script:PinnedFallback.ContainsKey($archKey)) {
            Write-Warn2 "Using pinned fallback for 7-Zip."
            $resolved = @{ Url = $script:PinnedFallback[$archKey]; Digest = $null }
        } else {
            Write-Fail "No download URL for 7-Zip (dynamic lookup failed, no pinned fallback for $archKey)."
            Set-Result -Tool '7-Zip' -Status 'Failed' -Detail 'No URL resolvable.'
            return
        }
    }
    if ($DryRun) {
        Write-Info "[DRYRUN] Would install 7-Zip from: $($resolved.Url)"
        Set-Result -Tool '7-Zip' -Status 'DryRun' -Detail $resolved.Url
        return
    }
    if (-not $PSCmdlet.ShouldProcess('7-Zip', 'Download + silent install')) {
        Set-Result -Tool '7-Zip' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $dest = Join-Path $script:TempDir (Split-Path $resolved.Url -Leaf)
    if (-not (Get-RemoteFile -Url $resolved.Url -Destination $dest -FriendlyName '7-Zip')) {
        Set-Result -Tool '7-Zip' -Status 'Failed' -Detail 'Download failed.'
        return
    }
    if (-not (Test-DownloadedFileHash -FilePath $dest -FriendlyName '7-Zip' -ExpectedDigest $resolved.Digest)) {
        Set-Result -Tool '7-Zip' -Status 'Failed' -Detail 'Checksum mismatch.'
        return
    }

    # NSIS installer: /S is the silent flag. /D= would override install dir --
    # leave it at default (C:\Program Files-Zip\) to keep PATH addition simple.
    $installed = Invoke-SilentInstaller -Path $dest -FriendlyName '7-Zip' -Arguments @('/S')

    $sevenZipDir = Join-Path $env:ProgramFiles '7-Zip'
    if (Test-7ZipInstalled) {
        Add-ToUserPath -Directory $sevenZipDir | Out-Null
        Update-SessionPath
        Write-Ok "7-Zip installed. CLI: 7z i  |  GUI: 7zFM.exe"
        Set-Result -Tool '7-Zip' -Status 'Installed' -Detail $sevenZipDir
    } elseif ($installed) {
        Write-Warn2 "7-Zip installer reported success but 7z.exe was not found under $sevenZipDir."
        Set-Result -Tool '7-Zip' -Status 'Warning' -Detail 'Binary not found at expected path.'
    } else {
        Set-Result -Tool '7-Zip' -Status 'Failed' -Detail 'Installer reported failure.'
    }
}

function Get-PostgresInstallDir {
    $base = Join-Path $env:ProgramFiles 'PostgreSQL'
    if (-not (Test-Path $base)) { return $null }
    $versionDir = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [int]$_.Name } catch { 0 } } -Descending | Select-Object -First 1
    if (-not $versionDir) { return $null }
    if (Test-Path (Join-Path $versionDir.FullName 'bin\psql.exe')) { return $versionDir.FullName }
    return $null
}

function Install-PostgreSQL {
    Write-Step "Checking PostgreSQL"

    if (-not $Force -and (Get-PostgresInstallDir)) {
        Write-Ok "PostgreSQL already installed."
        Set-Result -Tool 'PostgreSQL' -Status 'Present'
        return
    }
    if ($script:Architecture -eq 'arm64') {
        Write-Warn2 "No confirmed native Windows ARM64 PostgreSQL installer -- skipping rather than guessing a URL."
        Set-Result -Tool 'PostgreSQL' -Status 'Skipped' -Detail 'No ARM64 build.'
        return
    }

    # EnterpriseDB publishes no latest-version API. Pinned, overridable via
    # -PostgresVersion rather than requiring a script edit.
    $url = "https://get.enterprisedb.com/postgresql/postgresql-$PostgresVersion-windows-x64.exe"

    if ($DryRun) {
        Write-Info "[DRYRUN] Would install PostgreSQL $PostgresVersion from: $url"
        Write-Info "[DRYRUN] Superuser 'postgres' password would be set to 'postgres'."
        Set-Result -Tool 'PostgreSQL' -Status 'DryRun' -Detail $url
        return
    }
    if (-not $PSCmdlet.ShouldProcess('PostgreSQL', 'Download + unattended install')) {
        Set-Result -Tool 'PostgreSQL' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    Write-Warn2 "Superuser 'postgres' password is set to 'postgres' (unattended default). Change it: ALTER USER postgres WITH PASSWORD 'newpassword';"

    $dest = Join-Path $script:TempDir (Split-Path $url -Leaf)
    if (-not (Get-RemoteFile -Url $url -Destination $dest -FriendlyName "PostgreSQL $PostgresVersion")) {
        Write-Warn2 "If this 404'd, the pinned build string is stale. Re-run with -PostgresVersion '<major>.<minor>-<build>'."
        Set-Result -Tool 'PostgreSQL' -Status 'Failed' -Detail 'Download failed (check -PostgresVersion).'
        return
    }

    Write-Info "This install takes several minutes."
    $installed = Invoke-SilentInstaller -Path $dest -FriendlyName 'PostgreSQL' `
        -Arguments @('--mode', 'unattended', '--unattendedmodeui', 'none', '--superpassword', 'postgres')

    $pgDir = Get-PostgresInstallDir
    if ($pgDir) {
        Add-ToUserPath -Directory (Join-Path $pgDir 'bin') | Out-Null
        Update-SessionPath
        Write-Ok "PostgreSQL installed. Connect with: psql -U postgres (password: postgres)"
        Set-Result -Tool 'PostgreSQL' -Status 'Installed' -Detail $pgDir
    } elseif ($installed) {
        Write-Warn2 "PostgreSQL installer reported success but the install directory was not found."
        Set-Result -Tool 'PostgreSQL' -Status 'Warning' -Detail 'Install dir not found.'
    } else {
        Set-Result -Tool 'PostgreSQL' -Status 'Failed' -Detail 'Installer reported failure.'
    }
}

# ---------------------------------------------------------------------------
# Tier 4.5 -- LSP / language tooling (Python + JS/TS + Go + Rust)
# ---------------------------------------------------------------------------
#
# The v3.2 base provisioner intentionally omitted LSPs/linters. This tier
# rounds out the sandbox for real development work:
#
#   Python  pyright (LSP) + ruff (lint/format) + black (format)
#           + isort (import sort) + mypy (type-check)  -> installed via
#           `uv tool install`, which provisions isolated venvs + PATH shims.
#           uv (Tier 2) is a hard prerequisite.
#   JS/TS   typescript-language-server (LSP) + typescript (tsc) + eslint
#           + vscode-langservers-extracted (html/css/json/eslint/md LSPs)
#           -> installed via `npm install -g`. Node (Tier 1) is required.
#   Go      Go runtime (if absent) from go.dev (.zip), then `go install
#           golang.org/x/tools/gopls@latest` for the LSP. If Go is already
#           on PATH, only gopls is installed.
#   Rust    rustup (if absent) from win.rustup.rs (-y --profile minimal),
#           then `rustup component add rust-analyzer` for the LSP. If
#           rustup is already present, only the component is added.
#
# Every tool is its own Invoke-Stage, so a single failure does not block
# the rest. Each sub-stage is idempotent (Test-CommandExists) and respects
# -Force, -DryRun, -AcceptAll, and -WhatIf via ShouldProcess.
# ---------------------------------------------------------------------------

function Install-PythonLsp {
    Write-Step "Checking Python LSP / lint (pyright, ruff, black, isort, mypy)"

    if (-not (Test-CommandExists -Name 'uv')) {
        Write-Warn2 "uv not found (Tier 2 skipped). Python LSP installs via uv tool -- skipping."
        Set-Result -Tool 'Python LSP' -Status 'Skipped' -Detail 'uv unavailable.'
        return
    }
    $tools = @('pyright','ruff','black','isort','mypy')
    if ($DryRun) {
        foreach ($t in $tools) { Write-Info "[DRYRUN] Would run: uv tool install $t" }
        Set-Result -Tool 'Python LSP' -Status 'DryRun' -Detail ($tools -join ', ')
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Python LSP', 'uv tool install (5 packages)')) {
        Set-Result -Tool 'Python LSP' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $installed = 0; $failed = @()
    foreach ($t in $tools) {
        if (-not $Force -and (Test-CommandExists -Name $t)) {
            Write-Ok "$t already installed."
            $installed++; continue
        }
        Write-Info "uv tool install $t ..."
        & uv tool install $t
        if ($LASTEXITCODE -eq 0) { $installed++ } else {
            Write-Warn2 "$t install failed (uv exit $LASTEXITCODE)."
            $failed += $t
        }
    }
    Update-SessionPath
    Add-ToUserPath -Directory $script:UserBinDir | Out-Null

    if ($failed.Count -eq 0) {
        Write-Ok "Python LSP stack complete ($installed/$($tools.Count))."
        Set-Result -Tool 'Python LSP' -Status 'Installed' -Detail ($tools -join ', ')
    } elseif ($installed -gt 0) {
        Write-Warn2 "Partial Python LSP: $installed ok, $($failed.Count) failed ($($failed -join ', '))."
        Set-Result -Tool 'Python LSP' -Status 'Warning' -Detail "Failed: $($failed -join ', ')"
    } else {
        Write-Fail "All Python LSP installs failed."
        Set-Result -Tool 'Python LSP' -Status 'Failed' -Detail 'Every uv tool install returned non-zero.'
    }
}

function Install-NodeLsp {
    Write-Step "Checking JS/TS LSP / lint (ts-ls, tsc, eslint, vscode-langservers)"

    if (-not (Test-CommandExists -Name 'npm')) {
        Write-Warn2 "npm not found (Node.js skipped). JS/TS LSP requires npm -- skipping."
        Set-Result -Tool 'JS/TS LSP' -Status 'Skipped' -Detail 'npm unavailable.'
        return
    }
    $pkgs = @('typescript-language-server','typescript','eslint','vscode-langservers-extracted')
    $probes = @{
        'typescript-language-server'  = 'typescript-language-server'
        'typescript'                  = 'tsc'
        'eslint'                      = 'eslint'
        'vscode-langservers-extracted' = 'vscode-html-language-server'
    }
    if ($DryRun) {
        foreach ($p in $pkgs) { Write-Info "[DRYRUN] Would run: npm install -g $p" }
        Set-Result -Tool 'JS/TS LSP' -Status 'DryRun' -Detail ($pkgs -join ', ')
        return
    }
    if (-not $PSCmdlet.ShouldProcess('JS/TS LSP', 'npm install -g (4 packages)')) {
        Set-Result -Tool 'JS/TS LSP' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $env:npm_config_yes = 'true'
    $installed = 0; $failed = @()
    foreach ($p in $pkgs) {
        $probe = $probes[$p]
        if (-not $Force -and (Test-CommandExists -Name $probe)) {
            Write-Ok "$p already installed (probe: $probe)."
            $installed++; continue
        }
        Write-Info "npm install -g $p ..."
        & npm install -g $p --no-fund --no-audit
        if ($LASTEXITCODE -eq 0) { $installed++ } else {
            Write-Warn2 "$p install failed (npm exit $LASTEXITCODE)."
            $failed += $p
        }
    }
    Update-SessionPath

    if ($failed.Count -eq 0) {
        Write-Ok "JS/TS LSP stack complete ($installed/$($pkgs.Count))."
        Set-Result -Tool 'JS/TS LSP' -Status 'Installed' -Detail ($pkgs -join ', ')
    } elseif ($installed -gt 0) {
        Write-Warn2 "Partial JS/TS LSP: $installed ok, $($failed.Count) failed ($($failed -join ', '))."
        Set-Result -Tool 'JS/TS LSP' -Status 'Warning' -Detail "Failed: $($failed -join ', ')"
    } else {
        Write-Fail "All JS/TS LSP installs failed."
        Set-Result -Tool 'JS/TS LSP' -Status 'Failed' -Detail 'Every npm install returned non-zero.'
    }
}

function Install-GoLsp {
    Write-Step "Checking Go + gopls (Go LSP)"

    if ($DryRun) {
        Write-Info "[DRYRUN] Would: install Go runtime if absent, then go install golang.org/x/tools/gopls@latest"
        Set-Result -Tool 'Go LSP' -Status 'DryRun'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Go LSP', 'Install Go + gopls')) {
        Set-Result -Tool 'Go LSP' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $goPresent = (Test-CommandExists -Name 'go')
    if (-not $goPresent) {
        # Pinned: 1.23.4 windows/amd64 zip. ~80 MB. Override via $env:GO_VERSION.
        $goVer = if ($env:GO_VERSION) { $env:GO_VERSION } else { '1.23.4' }
        $url   = "https://go.dev/dl/go$goVer.windows-amd64.zip"
        if ($script:Architecture -eq 'arm64') {
            $url = "https://go.dev/dl/go$goVer.windows-arm64.zip"
        }
        $dest = Join-Path $script:TempDir "go-$goVer.zip"
        Write-Info "Downloading Go $goVer from $url ..."
        if (-not (Get-RemoteFile -Url $url -Destination $dest -FriendlyName "Go $goVer")) {
            Set-Result -Tool 'Go LSP' -Status 'Failed' -Detail 'Go download failed.'
            return
        }
        $extractBase = Join-Path $env:ProgramFiles 'Go'
        if (Test-Path $extractBase) { Remove-Item $extractBase -Recurse -Force -ErrorAction SilentlyContinue }
        try {
            Expand-Archive -Path $dest -DestinationPath $env:ProgramFiles -Force -ErrorAction Stop
        } catch {
            Write-Fail "Go zip extraction failed: $($_.Exception.Message)"
            Set-Result -Tool 'Go LSP' -Status 'Failed' -Detail $_.Exception.Message
            return
        }
        $goBin = Join-Path $extractBase 'bin'
        if (-not (Test-Path (Join-Path $goBin 'go.exe'))) {
            Write-Fail "Go extraction done but go.exe not found at $goBin."
            Set-Result -Tool 'Go LSP' -Status 'Failed' -Detail 'go.exe missing after extract.'
            return
        }
        Add-ToUserPath -Directory $goBin | Out-Null
        Update-SessionPath
        Write-Ok "Go runtime installed at $extractBase."
    } else {
        Write-Ok "Go runtime already present."
    }

    if (-not (Test-CommandExists -Name 'go')) {
        Write-Warn2 "go still not on PATH -- gopls cannot be installed. Open a new session and re-run."
        Set-Result -Tool 'Go LSP' -Status 'Warning' -Detail 'Go installed but not on PATH.'
        return
    }

    if (-not $Force -and (Test-CommandExists -Name 'gopls')) {
        Write-Ok "gopls already installed."
        Set-Result -Tool 'Go LSP' -Status 'Present' -Detail 'go + gopls'
        return
    }

    Write-Info "go install golang.org/x/tools/gopls@latest ..."
    & go install golang.org/x/tools/gopls@latest
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "gopls install failed (go exit $LASTEXITCODE)."
        Set-Result -Tool 'Go LSP' -Status 'Failed' -Detail "go exit $LASTEXITCODE"
        return
    }
    $gobin = Join-Path $env:USERPROFILE 'go\bin'
    Add-ToUserPath -Directory $gobin | Out-Null
    Update-SessionPath

    if (Test-CommandExists -Name 'gopls') {
        Write-Ok "gopls installed."
        Set-Result -Tool 'Go LSP' -Status 'Installed' -Detail 'go + gopls'
    } else {
        Write-Warn2 "gopls installed but not visible in this session."
        Set-Result -Tool 'Go LSP' -Status 'Warning' -Detail 'Needs a new session for PATH.'
    }
}

function Install-RustLsp {
    Write-Step "Checking Rust + rust-analyzer (Rust LSP)"

    if ($DryRun) {
        Write-Info "[DRYRUN] Would: install rustup if absent, then rustup component add rust-analyzer"
        Set-Result -Tool 'Rust LSP' -Status 'DryRun'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Rust LSP', 'Install rustup + rust-analyzer')) {
        Set-Result -Tool 'Rust LSP' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    $rustupPresent = (Test-CommandExists -Name 'rustup')
    if (-not $rustupPresent) {
        $url = if ($script:Architecture -eq 'arm64') {
            'https://win.rustup.rs/aarch64'
        } else {
            'https://win.rustup.rs/x86_64'
        }
        $dest = Join-Path $script:TempDir 'rustup-init.exe'
        Write-Info "Downloading rustup from $url ..."
        if (-not (Get-RemoteFile -Url $url -Destination $dest -FriendlyName 'rustup-init')) {
            Set-Result -Tool 'Rust LSP' -Status 'Failed' -Detail 'rustup download failed.'
            return
        }
        Write-Info "Running rustup-init -y --default-toolchain stable --profile minimal ..."
        $proc = Start-Process -FilePath $dest `
            -ArgumentList @('-y','--default-toolchain','stable','--profile','minimal') `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Fail "rustup-init exited with code $($proc.ExitCode)."
            Set-Result -Tool 'Rust LSP' -Status 'Failed' -Detail "rustup-init exit $($proc.ExitCode)"
            return
        }
        $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
        Add-ToUserPath -Directory $cargoBin | Out-Null
        Update-SessionPath
        Write-Ok "Rust toolchain installed via rustup."
    } else {
        Write-Ok "rustup already present."
    }

    if (-not (Test-CommandExists -Name 'rustup')) {
        Write-Warn2 "rustup still not on PATH -- rust-analyzer cannot be added. Open a new session and re-run."
        Set-Result -Tool 'Rust LSP' -Status 'Warning' -Detail 'rustup installed but not on PATH.'
        return
    }

    if (-not $Force -and (Test-CommandExists -Name 'rust-analyzer')) {
        Write-Ok "rust-analyzer already installed."
        Set-Result -Tool 'Rust LSP' -Status 'Present' -Detail 'rustup + rust-analyzer'
        return
    }

    Write-Info "rustup component add rust-analyzer ..."
    & rustup component add rust-analyzer
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "rust-analyzer component add failed (rustup exit $LASTEXITCODE)."
        Set-Result -Tool 'Rust LSP' -Status 'Failed' -Detail "rustup exit $LASTEXITCODE"
        return
    }

    if (Test-CommandExists -Name 'rust-analyzer') {
        Write-Ok "rust-analyzer installed."
        Set-Result -Tool 'Rust LSP' -Status 'Installed' -Detail 'rustup + rust-analyzer'
    } else {
        Write-Warn2 "rust-analyzer installed but not visible in this session."
        Set-Result -Tool 'Rust LSP' -Status 'Warning' -Detail 'Needs a new session for PATH.'
    }
}

function Install-LspServers {
    Write-Step "Installing LSP / language tooling (Tier 4.5)"
    Install-PythonLsp
    Install-NodeLsp
    Install-GoLsp
    Install-RustLsp
}

# ---------------------------------------------------------------------------
# Tier 5 -- configuration
# ---------------------------------------------------------------------------

function Set-GitIdentity {
    param(
        [string]$UserName,
        [string]$UserEmail
    )
    Write-Step "Checking Git identity (user.name / user.email)"

    if (-not (Test-CommandExists -Name 'git')) {
        Write-Warn2 "git not on PATH -- skipping identity configuration."
        Set-Result -Tool 'Git identity' -Status 'Skipped' -Detail 'git unavailable.'
        return
    }

    $existingName  = git config --global user.name  2>$null
    $existingEmail = git config --global user.email 2>$null
    if (-not $Force -and $existingName -and $existingEmail) {
        Write-Ok "Git identity already configured: $existingName <$existingEmail>"
        Set-Result -Tool 'Git identity' -Status 'Present' -Detail "$existingName <$existingEmail>"
        return
    }

    # -AcceptAll must never prompt AND must never leave git unusable.
    # v2 skipped configuration entirely, so the first commit failed with
    # "Author identity unknown".
    if ((-not $UserName -or -not $UserEmail) -and $AcceptAll) {
        if (-not $UserName)  { $UserName  = 'Sandbox User' }
        if (-not $UserEmail) { $UserEmail = 'sandbox@localhost.invalid' }
        Write-Warn2 "No -GitUserName/-GitUserEmail supplied. Applying unattended defaults so commits work: $UserName <$UserEmail>. Override before pushing to a real remote."
    }

    if (-not $UserName -or -not $UserEmail) {
        if (-not $UserName)  { $UserName  = Read-Host "Git commit author name (e.g. 'Jane Doe')" }
        if (-not $UserEmail) { $UserEmail = Read-Host "Git commit author email (e.g. you@users.noreply.github.com)" }
    }
    if (-not $UserName -or -not $UserEmail) {
        Write-Warn2 "Name/email not provided -- commits will fail until set manually."
        Set-Result -Tool 'Git identity' -Status 'Skipped' -Detail 'No values provided.'
        return
    }

    # DryRun check placed BEFORE any interaction (regression point in v2).
    if ($DryRun) {
        Write-Info "[DRYRUN] Would set git user.name '$UserName' / user.email '$UserEmail'"
        Set-Result -Tool 'Git identity' -Status 'DryRun'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Git', 'Set global user.name / user.email')) {
        Set-Result -Tool 'Git identity' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }

    git config --global user.name  $UserName
    git config --global user.email $UserEmail
    Write-Ok "Git identity set: $UserName <$UserEmail>"
    Set-Result -Tool 'Git identity' -Status 'Installed' -Detail "$UserName <$UserEmail>"
}

# ---------------------------------------------------------------------------
# Tier 6 -- Docker Desktop (last: its installer can request a reboot)
# ---------------------------------------------------------------------------

function Install-DockerDesktop {
    Write-Step "Checking Docker Desktop"

    if (-not $Force -and (Test-CommandExists -Name 'docker')) {
        Write-Ok "Docker CLI already present."
        Set-Result -Tool 'Docker Desktop' -Status 'Present'
        return
    }
    if ((Test-InWindowsSandbox) -and -not $ForceDockerInSandbox) {
        Write-Warn2 "Windows Sandbox detected. Docker Desktop needs a WSL2 or Hyper-V backend, which requires nested virtualization Sandbox does not expose. Skipping a ~700 MB download that cannot start. Override with -ForceDockerInSandbox."
        Set-Result -Tool 'Docker Desktop' -Status 'Skipped' -Detail 'Unsupported inside Windows Sandbox.'
        return
    }
    if ($script:Architecture -eq 'arm64') {
        $url = 'https://desktop.docker.com/win/main/arm64/Docker%20Desktop%20Installer.exe'
    } else {
        $url = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'
    }

    if ($DryRun) {
        Write-Info "[DRYRUN] Would install Docker Desktop from: $url"
        Set-Result -Tool 'Docker Desktop' -Status 'DryRun' -Detail $url
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Docker Desktop', 'Download + silent install')) {
        Set-Result -Tool 'Docker Desktop' -Status 'Skipped' -Detail 'Declined by ShouldProcess/-WhatIf.'
        return
    }
    if (-not (Test-IsAdministrator)) {
        Write-Warn2 "Docker Desktop system-wide install needs elevation. Continuing, but expect failure."
    }

    $dest = Join-Path $script:TempDir 'DockerDesktopInstaller.exe'
    if (-not (Get-RemoteFile -Url $url -Destination $dest -FriendlyName 'Docker Desktop')) {
        Set-Result -Tool 'Docker Desktop' -Status 'Failed' -Detail 'Download failed.'
        return
    }

    Write-Info "This is a large install and may take 10+ minutes."
    $installed = Invoke-SilentInstaller -Path $dest -FriendlyName 'Docker Desktop' `
        -Arguments @('install', '--quiet', '--accept-license', '--backend=wsl-2')
    Update-SessionPath

    if (Test-CommandExists -Name 'docker') {
        Write-Ok "Docker Desktop installed. Start the app once, then verify with 'docker info'."
        Set-Result -Tool 'Docker Desktop' -Status 'Installed'
    } elseif ($installed) {
        Write-Warn2 "Docker Desktop installed but 'docker' is not visible in this session."
        Set-Result -Tool 'Docker Desktop' -Status 'Warning' -Detail 'Needs a new session / app first-run.'
    } else {
        Set-Result -Tool 'Docker Desktop' -Status 'Failed' -Detail 'Installer reported failure.'
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$transcriptStarted = $false
if (-not $LogPath) {
    $LogPath = Join-Path $env:USERPROFILE ("Setup-ClaudeCodeSandbox_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
try {
    Start-Transcript -Path $LogPath -Force | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Warn2 "Transcript unavailable ($($_.Exception.Message)). Continuing without a log file."
}

try {
    $inSandbox = Test-InWindowsSandbox
    $isAdmin   = Test-IsAdministrator

    Write-Host "Claude Code Sandbox Setup v3.2 -- direct download, unattended" -ForegroundColor White
    Write-Host "=============================================================" -ForegroundColor White
    Write-Host " Architecture   : $($script:Architecture)"
    Write-Host " Windows Sandbox: $inSandbox"
    Write-Host " Administrator  : $isAdmin"
    Write-Host " Unattended     : $([bool]$AcceptAll)"
    Write-Host " Log            : $LogPath"
    if ($VerifyChecksums) { Write-Host " Checksums      : ENABLED" -ForegroundColor Green }
    if ($DryRun)          { Write-Host " DRY RUN        : no changes will be made" -ForegroundColor Yellow }

    if (-not $isAdmin) {
        Write-Warn2 "Not elevated. Python (InstallAllUsers=1), PostgreSQL, MSI packages and Docker Desktop need administrator rights and will fail. Re-run from an elevated PowerShell."
    }
    if (-not $AcceptAll -and -not $DryRun) {
        Write-Warn2 "Running without -AcceptAll: vendor installer scripts will prompt for confirmation. Pass -AcceptAll for a fully unattended run."
    }

    # ---- Tier 1: runtimes --------------------------------------------------
    Invoke-Stage -Name 'Git' -Action {
        Install-Tool -Name 'Git' -CommandCheck 'git' `
            -LatestReleaseResolver ${function:Get-LatestGitRelease} -FallbackKey 'Git' `
            -SilentArgs @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL', '/SP-')
    }
    Invoke-Stage -Name 'Python' -Action {
        Install-Tool -Name 'Python' -CommandCheck 'python' `
            -LatestReleaseResolver ${function:Get-LatestPythonRelease} -FallbackKey 'Python' `
            -SilentArgs @('/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0')
    }
    Invoke-Stage -Name 'Node.js' -Skip:$SkipNode -SkipReason 'Skipped by -SkipNode' -Action {
        Install-Tool -Name 'Node.js' -CommandCheck 'node' `
            -LatestReleaseResolver ${function:Get-LatestNodeRelease} -FallbackKey 'Node' `
            -SilentArgs @('/qn', '/norestart')
    }

    # ---- Tier 2: toolchains ------------------------------------------------
    Invoke-Stage -Name 'uv'   -Skip:$SkipUv   -SkipReason 'Skipped by -SkipUv (Strix will be skipped too)' -Action { Install-Uv }
    Invoke-Stage -Name 'Bun'  -Skip:$SkipBun  -SkipReason 'Skipped by -SkipBun'  -Action { Install-Bun }
    Invoke-Stage -Name 'Deno' -Skip:$SkipDeno -SkipReason 'Skipped by -SkipDeno' -Action { Install-Deno }

    # ---- Tier 3: CLI layer -------------------------------------------------
    Invoke-Stage -Name 'GitHub CLI' -Skip:$SkipGh -SkipReason 'Skipped by -SkipGh' -Action {
        Install-Tool -Name 'GitHub CLI' -CommandCheck 'gh' `
            -LatestReleaseResolver ${function:Get-LatestGhRelease} -FallbackKey 'Gh' `
            -SilentArgs @('/qn', '/norestart')
    }
    Invoke-Stage -Name 'Claude Code'  -Skip:$SkipClaude   -SkipReason 'Skipped by -SkipClaude'   -Action { Install-ClaudeCode }
    Invoke-Stage -Name 'OpenCode'     -Skip:$SkipOpenCode -SkipReason 'Skipped by -SkipOpenCode' -Action { Install-OpenCode }
    Invoke-Stage -Name 'Vite'         -Skip:$SkipVite     -SkipReason 'Skipped by -SkipVite'     -Action { Install-Vite }
    Invoke-Stage -Name 'Grok Build'   -Skip:$SkipGrok     -SkipReason 'Skipped by -SkipGrok'     -Action { Install-GrokBuild }
    Invoke-Stage -Name 'Supabase CLI' -Skip:$SkipSupabase -SkipReason 'Skipped by -SkipSupabase' -Action { Install-SupabaseCli }
    Invoke-Stage -Name 'Strix'        -Skip:$SkipStrix    -SkipReason 'Skipped by -SkipStrix'    -Action { Install-Strix }

    # ---- Tier 3.5: MCP layer (npm packages) --------------------------------
    Invoke-Stage -Name 'MCP servers' -Skip:$SkipMcp -SkipReason 'Skipped by -SkipMcp' -Action { Install-McpServers }
    Invoke-Stage -Name 'Opencode MCP' -Skip:$SkipMcp -SkipReason 'Skipped by -SkipMcp' -Action { Configure-OpencodeMcp }

    # ---- Tier 4: heavy / GUI ----------------------------------------------
    Invoke-Stage -Name 'VS Code'    -Skip:$SkipVSCode   -SkipReason 'Skipped by -SkipVSCode'   -Action { Install-VSCode }
    Invoke-Stage -Name 'Notepad++'  -Skip:$SkipNotepad  -SkipReason 'Skipped by -SkipNotepad'  -Action { Install-Notepad }
    Invoke-Stage -Name '7-Zip'      -Skip:$SkipSevenZip -SkipReason 'Skipped by -SkipSevenZip' -Action { Install-7Zip }
    Invoke-Stage -Name 'PostgreSQL' -Skip:$SkipPostgres -SkipReason 'Skipped by -SkipPostgres' -Action { Install-PostgreSQL }

    # ---- Tier 4.5: LSP / language tooling ----------------------------------
    Invoke-Stage -Name 'LSP servers' -Skip:$SkipLsp -SkipReason 'Skipped by -SkipLsp' -Action { Install-LspServers }

    # ---- Tier 5: configuration --------------------------------------------
    Invoke-Stage -Name 'Git identity' -Skip:$SkipGitIdentity -SkipReason 'Skipped by -SkipGitIdentity' -Action {
        Set-GitIdentity -UserName $GitUserName -UserEmail $GitUserEmail
    }
    Invoke-Stage -Name 'Strix config' -Skip:$SkipStrix -SkipReason 'Skipped by -SkipStrix' -Action {
        Set-StrixEnvironment
    }
    Invoke-Stage -Name 'Sentry config' -Skip:(-not $SentryAuthToken -and -not $SentryOrg) -SkipReason 'No -SentryAuthToken / -SentryOrg supplied.' -Action {
        Configure-SentryEnvironment
    }

    # ---- Tier 6: Docker Desktop (opt-in, last) -----------------------------
    Invoke-Stage -Name 'Docker Desktop' -Skip:(-not $InstallDocker) `
        -SkipReason 'Not requested (-InstallDocker). Cannot function inside Windows Sandbox.' -Action {
        Install-DockerDesktop
    }

    # ---- Tier 7: workspace + GitHub + repo select --------------------------------
    Invoke-Stage -Name 'Workspace'    -Skip:$SkipWorkspace -SkipReason 'Skipped by -SkipWorkspace.' -Action { Initialize-Workspace }
    Invoke-Stage -Name 'GitHub auth'  -Skip:$SkipWorkspace -SkipReason 'Skipped by -SkipWorkspace.' -Action { Connect-GitHub }
    Invoke-Stage -Name 'Repository clone' -Skip:$SkipRepoClone -SkipReason 'Skipped by -SkipRepoClone.' -Action { Select-GitHubRepository }

    # ---- Cleanup + summary -------------------------------------------------
    $failed = @($script:Results | Where-Object { $_.Status -eq 'Failed' })

    if (-not $NoCleanup -and -not $DryRun -and $failed.Count -eq 0) {
        Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Temporary download files cleaned."
    } elseif ($failed.Count -gt 0) {
        Write-Warn2 "Temp files kept at $script:TempDir for diagnosis."
    }

    Write-Host "`n=============================================================" -ForegroundColor White
    Write-Host "SUMMARY" -ForegroundColor White
    # Manual rendering, not Format-Table: -AutoSize emits nothing when the
    # host width is unavailable (redirected output, scheduled task, transcript).
    Write-Host ("  {0,-16} {1,-10} {2}" -f 'TOOL', 'STATUS', 'DETAIL') -ForegroundColor Gray
    foreach ($entry in $script:Results) {
        $colour = switch ($entry.Status) {
            'Installed' { 'Green'  }
            'Present'   { 'Green'  }
            'DryRun'    { 'Cyan'   }
            'Skipped'   { 'Yellow' }
            'Warning'   { 'Yellow' }
            'Failed'    { 'Red'    }
            default     { 'White'  }
        }
        Write-Host ("  {0,-16} {1,-10} {2}" -f $entry.Tool, $entry.Status, $entry.Detail) -ForegroundColor $colour
    }

    if ($script:RebootPending) {
        Write-Warn2 "One or more installers requested a reboot. On a persistent host, reboot before using those tools."
    }
    $needsNewSession = @($script:Results | Where-Object { $_.Status -eq 'Warning' })
    if ($needsNewSession.Count -gt 0) {
        Write-Host "Open a NEW PowerShell window for PATH changes to take effect, then re-run to confirm." -ForegroundColor White
    }

    if ($failed.Count -gt 0) {
        Write-Host "$($failed.Count) tool(s) failed. Log: $LogPath" -ForegroundColor Red
        if ($transcriptStarted) { Stop-Transcript | Out-Null }
        exit 2
    }

    Write-Host "All requested tools completed. Log: $LogPath" -ForegroundColor Green
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    exit 0
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    exit 1
}
