#!/usr/bin/env bash
# =============================================================================
# Setup-ClaudeCodeSandbox.sh  (macOS Intel / x86_64)
# v3.2 -- direct-download developer toolchain provisioner for macOS.
#
# Port of the Windows PowerShell provisioner (Setup-ClaudeCodeSandbox.ps1)
# with the same end goal: an unattended Claude Code / opencode / MCP /
# AI-toolchain workstation. Direct downloads and canonical curl installers
# only -- no Homebrew, no interactive vendor prompts (unless -AcceptAll is
# omitted), no aborting the whole run on a single tool failure.
#
# TIERS (identical dependency order to the Windows build):
#   Tier 0   Preflight   macOS + x86_64 check, admin/sudo check, log tee
#   Tier 1   Runtimes    Git (Xcode CLT) -> Python -> Node.js
#   Tier 2   Toolchains  uv -> Bun -> Deno
#   Tier 3   CLI layer   GitHub CLI -> Claude Code -> OpenCode -> Vite
#                        -> Grok Build -> Supabase CLI -> Strix
#   Tier 3.5 MCP layer   GitHub MCP -> Sequential Thinking -> Memory
#                        -> Context7 -> Sentry -> Supabase
#                        registered with opencode
#                          (~/.config/opencode/opencode.json)
#   Tier 4   Heavy/GUI   VS Code -> PostgreSQL (EDB DMG). Notepad++ and
#                        7-Zip are Windows-only and are not part of this
#                        build (see the Windows PowerShell script).
#   Tier 4.5 LSP layer   pyright -> ruff -> black -> isort -> mypy
#                        (Python, via `uv tool install`)
#                        -> typescript-language-server -> typescript
#                        -> eslint -> vscode-langservers-extracted
#                        (JS/TS, via `npm install -g`)
#                        -> Go runtime -> gopls
#                        -> Rust toolchain (rustup) -> rust-analyzer
#                        Skipped by -SkipLsp. Auto-skips a stack when its
#                        runtime (Node/uv/Go/Rust) is unavailable.
#   Tier 5   Config      Git identity ("Sandbox User" fallback if unset),
#                        Strix env vars, Sentry env vars
#   Tier 6   Docker      Docker Desktop (Intel Mac), opt-in, LAST
#   Tier 7   Workspace   ~/Git/clrogon tree (override -WorkspaceRoot),
#                        gh auth login, interactive repo picker, clone into
#                        $WORKSPACE/projects, open in VS Code, persist
#                        CLAUDIO_CURRENT_REPO
#
# KEY BEHAVIOUR (mirrors the Windows script):
#   * FAIL-ISOLATED: every tool runs inside its own stage; a failure is
#     recorded and the run continues.
#   * NO PROMPTS on -AcceptAll (git identity defaults supplied).
#   * SUMMARY + EXIT CODE: prints a per-tool result table; exits 2 if
#     anything failed so it can be chained in automation.
#   * sudo is cached once up front (-v). PKG installs (Python, Node,
#     PostgreSQL, VS Code, Docker) still need an admin password unless the
#     script runs as root.
#
# MCP NOTE: the six servers are pure npm packages and run on macOS with no
# Docker requirement. Supabase local stack needs Docker. opencode reads its
# config only at startup -- restart it after the run for the MCP tools to
# appear.
#
# STRIX NOTE: scans run inside a Docker container. On an Intel Mac, Docker
# Desktop works (HyperKit), so scans run once the engine is up. If the Rust
# build of litellm fails (no Xcode CLT), a pure-Python litellm<1.89.0
# fallback is used, same as the Windows build.
#
# USAGE:
#   ./Setup-ClaudeCodeSandbox-macOS.sh -AcceptAll
#   ./Setup-ClaudeCodeSandbox-macOS.sh -DryRun
#   ./Setup-ClaudeCodeSandbox-macOS.sh -AcceptAll -InstallDocker \
#        -GitUserName 'YOUR-NAME' -GitUserEmail 'you@example.com'
#   # -GithubUser is optional -- it defaults to whichever account
#   # `gh auth login` authenticated.
#
# OPTIONS (PowerShell-compatible spellings):
#   -AcceptAll -Force -DryRun -NoCleanup -InstallDocker
#   -GitUserName <n> -GitUserEmail <e>
#   -StrixLlm <model> -StrixApiKey <key> -StrixApiBase <url> -PerplexityApiKey <key>
#   -GithubUser <user> -SentryAuthToken <tok> -SentryOrg <slug>
#   -WorkspaceRoot <path> -PostgresVersion <ver> -LogPath <path>
#   -SkipNode -SkipUv -SkipBun -SkipDeno -SkipGh -SkipClaude -SkipOpenCode
#   -SkipVite -SkipGrok -SkipSupabase -SkipStrix -SkipMcp -SkipVSCode
#   -SkipPostgres -SkipLsp -SkipGitIdentity
#   -SkipWorkspace -SkipRepoClone
# =============================================================================
set -u

# ---------------------------------------------------------------------------
# Config + defaults
# ---------------------------------------------------------------------------
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/Git/clrogon}"
# Pinned fallbacks — used only when the dynamic resolver (API / scrape) fails.
# Last audited: 2026-08-03.  Dynamic resolvers are the source of truth.
POSTGRES_VERSION="${POSTGRES_VERSION:-18.4-1}"    # EDB has no latest-version API; override with -PostgresVersion
GITHUB_USER="${GITHUB_USER:-}"    # empty = auto-resolved from `gh auth status` at Tier 7
PYTHON_VERSION="${PYTHON_VERSION:-3.14.6}"    # fallback; get_latest_python_url() resolves dynamically
NODE_VERSION="${NODE_VERSION:-24.18.1}"       # fallback; get_latest_node_url() resolves dynamically

# Bash 3.2 (macOS default) has no mapfile / ${var,,}. Everything below is
# kept 3.2-compatible.
SETUP_TMP="${TMPDIR:-/tmp}/clrogon-sandbox-setup"
RESULTS=()
ACCEPT_ALL=0; FORCE=0; DRY_RUN=0; NO_CLEANUP=0; INSTALL_DOCKER=0
SKIP_NODE=0; SKIP_UV=0; SKIP_BUN=0; SKIP_DENO=0; SKIP_GH=0; SKIP_CLAUDE=0
SKIP_OPENCODE=0; SKIP_VITE=0; SKIP_GROK=0; SKIP_SUPABASE=0; SKIP_STRIX=0
SKIP_MCP=0; SKIP_VSCODE=0; SKIP_POSTGRES=0
SKIP_LSP=0
SKIP_GIT_IDENTITY=0; SKIP_WORKSPACE=0; SKIP_REPO_CLONE=0
SKIP_GIT=0; SKIP_PYTHON=0; SKIP_SENTRY=0
GIT_USER_NAME=""; GIT_USER_EMAIL=""; STRIX_LLM=""; STRIX_API_KEY=""
STRIX_API_BASE=""; PERPLEXITY_API_KEY=""; SENTRY_AUTH_TOKEN=""; SENTRY_ORG=""
LOG_PATH=""

# MCP servers: "<opencode-key> <npm-package>"
MCP_PACKAGES=(
  "github     @modelcontextprotocol/server-github"
  "sequential @modelcontextprotocol/server-sequential-thinking"
  "memory     @modelcontextprotocol/server-memory"
  "context7   @upstash/context7-mcp"
  "sentry     @sentry/mcp-server"
  "supabase   @supabase/mcp-server-supabase"
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -AcceptAll)     ACCEPT_ALL=1 ;;
        -Force)         FORCE=1 ;;
        -DryRun)        DRY_RUN=1 ;;
        -NoCleanup)     NO_CLEANUP=1 ;;
        -InstallDocker) INSTALL_DOCKER=1 ;;
        -SkipLsp)        SKIP_LSP=1 ;;
        -GitUserName)   GIT_USER_NAME="$2"; shift ;;
        -GitUserEmail)  GIT_USER_EMAIL="$2"; shift ;;
        -StrixLlm)      STRIX_LLM="$2"; shift ;;
        -StrixApiKey)   STRIX_API_KEY="$2"; shift ;;
        -StrixApiBase)  STRIX_API_BASE="$2"; shift ;;
        -PerplexityApiKey) PERPLEXITY_API_KEY="$2"; shift ;;
        -GithubUser)    GITHUB_USER="$2"; shift ;;
        -SentryAuthToken) SENTRY_AUTH_TOKEN="$2"; shift ;;
        -SentryOrg)     SENTRY_ORG="$2"; shift ;;
        -WorkspaceRoot) WORKSPACE_ROOT="$2"; shift ;;
        -PostgresVersion) POSTGRES_VERSION="$2"; shift ;;
        -LogPath)       LOG_PATH="$2"; shift ;;
        -SkipNode)      SKIP_NODE=1 ;;
        -SkipGit)       SKIP_GIT=1 ;;
        -SkipPython)    SKIP_PYTHON=1 ;;
        -SkipUv)        SKIP_UV=1 ;;
        -SkipBun)       SKIP_BUN=1 ;;
        -SkipDeno)      SKIP_DENO=1 ;;
        -SkipGh)        SKIP_GH=1 ;;
        -SkipClaude)    SKIP_CLAUDE=1 ;;
        -SkipOpenCode)  SKIP_OPENCODE=1 ;;
        -SkipVite)      SKIP_VITE=1 ;;
        -SkipGrok)      SKIP_GROK=1 ;;
        -SkipSupabase)  SKIP_SUPABASE=1 ;;
        -SkipStrix)     SKIP_STRIX=1 ;;
        -SkipMcp)       SKIP_MCP=1 ;;
        -SkipVSCode)    SKIP_VSCODE=1 ;;
        -SkipPostgres)  SKIP_POSTGRES=1 ;;
        -SkipGitIdentity) SKIP_GIT_IDENTITY=1 ;;
        -SkipSentry)    SKIP_SENTRY=1 ;;
        -SkipWorkspace) SKIP_WORKSPACE=1 ;;
        -SkipRepoClone) SKIP_REPO_CLONE=1 ;;
        -h|-Help|--help) head -80 "$0" | sed -n '1,80p'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Output + result tracking
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_FAIL=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_STEP=; C_OK=; C_WARN=; C_FAIL=; C_RESET=
fi

step() { echo -e "\n${C_STEP}==> $1${C_RESET}"; }
ok()   { echo -e " ${C_OK}[OK]${C_RESET} $1"; }
skip() { echo -e " ${C_WARN}[SKIP]${C_RESET} $1"; }
warn() { echo -e " ${C_WARN}[WARN]${C_RESET} $1"; }
fail() { echo -e " ${C_FAIL}[FAIL]${C_RESET} $1"; }
info() { echo " $1"; }

# Deliberately NOT echo-to-stderr-as-error: a single tool failure must not
# abort the run (the PowerShell v2 bug this whole script avoids).
record() { RESULTS+=("$1|$2|$3"); }

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

add_to_path() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) export PATH="$dir:$PATH" ;;
    esac
    # Persist for new zsh sessions (macOS default shell).
    if ! grep -qsF "export PATH=\"$dir" "$ZSHRC"; then
        printf 'export PATH="%s:$PATH"\n' "$dir" >> "$ZSHRC"
    fi
}

persist_env() {
    local name="$1" value="$2"
    [ -z "$value" ] && return 0
    export "$name=$value"
    if grep -qsF "export $name=" "$ZSHENV"; then
        sed -i '' "/^export $name=/d" "$ZSHENV"
    fi
    printf 'export %s=%q\n' "$name" "$value" >> "$ZSHENV"
}

# ---------------------------------------------------------------------------
# Download + install primitives
# ---------------------------------------------------------------------------
download() {
    local url="$1" dest="$2" name="$3"
    info "Downloading $name from $url ..."
    if curl -fsSL --retry 3 -o "$dest" "$url"; then
        return 0
    fi
    fail "Download failed for $name."
    return 1
}

pkg_install() {
    local pkg="$1" name="$2"
    info "Installing $name via pkg installer ..."
    if ! $SUDO installer -pkg "$pkg" -target / ; then
        fail "$name install failed."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Latest-version resolvers
# ---------------------------------------------------------------------------
get_github_asset_url() {
    local repo="$1" pattern="$2"
    local json url
    json=$(curl -fsSL --retry 2 "https://api.github.com/repos/$repo/releases/latest" \
        -H "User-Agent: clrogon-sandbox-setup" 2>/dev/null) || return 1
    url=$(printf '%s' "$json" | grep -oE '"browser_download_url":"[^"]*"' \
        | sed -E 's/.*"([^"]+)"$/\1/' | grep -E "$pattern" | head -1)
    [ -n "$url" ] || return 1
    printf '%s' "$url"
}

get_latest_python_url() {
    local html ver
    html=$(curl -fsSL --retry 2 https://www.python.org/ftp/python/ 2>/dev/null) || return 1
    ver=$(printf '%s' "$html" \
        | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
        | sed -E 's/href="([0-9.]+)\/"/\1/' \
        | grep -vE '(a|b|rc)[0-9]*$' \
        | sort -t. -k1,1n -k2,2n -k3,3n -u \
        | tail -1)
    [ -n "$ver" ] || return 1
    printf 'https://www.python.org/ftp/python/%s/python-%s-macos11.pkg' "$ver" "$ver"
}

get_latest_node_url() {
    # Returns the .pkg download URL for the latest Active LTS Node.js release.
    # Queries https://nodejs.org/dist/index.json (array, newest-first).
    # Active LTS releases have a codename string in the "lts" field;
    # Current/non-LTS releases have JSON false.
    local json ver
    json=$(curl -fsSL --retry 2 'https://nodejs.org/dist/index.json' 2>/dev/null) || return 1
    ver=$(printf '%s' "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
lts = [r for r in data if r.get('lts')]   # lts=false -> Python False (falsy), lts=codename -> truthy
print(lts[0]['version'].lstrip('v')) if lts else sys.exit(1)
" 2>/dev/null) || return 1
    [ -n "$ver" ] || return 1
    printf 'https://nodejs.org/dist/v%s/node-v%s.pkg' "$ver" "$ver"
}

# ---------------------------------------------------------------------------
# Generic curl-installer stage (uv, Bun, Deno, Claude Code, Grok)
# ---------------------------------------------------------------------------
run_curl_installer() {
    local name="$1" url="$2" check="$3" bin_dir="$4"
    step "Checking $name"
    if [ "$FORCE" -ne 1 ] && command_exists "$check"; then
        ok "$name already installed."
        record "$name" "Present" ""
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would download and run $url"
        record "$name" "DryRun" "$url"
        return 0
    fi
    local local_file="$SETUP_TMP/$(echo "$name" | tr ' ' '_').sh"
    info "Downloading $name installer script..."
    if ! curl -fsSL --retry 3 -o "$local_file" "$url"; then
        fail "$name installer download failed."
        record "$name" "Failed" "Download failed."
        return 1
    fi
    info "SHA256: $(shasum -a 256 "$local_file" | awk '{print $1}')"
    if [ "$ACCEPT_ALL" -ne 1 ]; then
        read -r -p "Execute downloaded $name installer? (y/N) " ans
        if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
            skip "$name skipped by operator after hash review."
            record "$name" "Skipped" "Declined at hash review."
            return 0
        fi
    fi
    bash "$local_file"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "$name installer exited with code $rc."
    fi
    add_to_path "$bin_dir"
    if command_exists "$check"; then
        ok "$name installed successfully."
        record "$name" "Installed" ""
    else
        warn "$name installed but '$check' is not visible in this session."
        record "$name" "Warning" "Installed; needs a new terminal for PATH."
    fi
}

# ---------------------------------------------------------------------------
# Tier 1 -- runtimes
# ---------------------------------------------------------------------------
install_git() {
    step "Checking Git"
    if [ "$FORCE" -ne 1 ] && command_exists git; then
        ok "Git already installed: $(git --version)"
        record "Git" "Present" "$(git --version)"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would ensure Xcode Command Line Tools (git included) are installed."
        record "Git" "DryRun" ""
        return 0
    fi
    if ! xcode-select -p >/dev/null 2>&1; then
        warn "Git/Xcode Command Line Tools not installed. Launching 'xcode-select --install' (GUI prompt). Complete the dialog, then re-run."
        xcode-select --install 2>/dev/null || true
    else
        warn "Xcode CLT present but git is missing from PATH."
    fi
    if command_exists git; then
        ok "Git available."
        record "Git" "Installed" ""
    else
        warn "git not visible yet (Xcode CLT install is asynchronous)."
        record "Git" "Warning" "Complete the Xcode CLT dialog, then re-run."
    fi
}

install_python() {
    step "Checking Python"
    if [ "$FORCE" -ne 1 ] && command_exists python3; then
        ok "Python already installed: $(python3 --version 2>&1 | head -1)"
        record "Python" "Present" "$(python3 --version 2>&1 | head -1)"
        return 0
    fi
    local url ver
    url=$(get_latest_python_url) || true
    if [ -n "$url" ]; then
        ver=$(basename "$(dirname "$url")")
    else
        ver="$PYTHON_VERSION"
        url="https://www.python.org/ftp/python/$ver/python-$ver-macos11.pkg"
        warn "Python latest-version lookup failed; using pinned $ver."
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would install Python $ver from $url"
        record "Python" "DryRun" "$url"
        return 0
    fi
    local pkg="$SETUP_TMP/python-$ver.pkg"
    if ! download "$url" "$pkg" "Python $ver"; then
        record "Python" "Failed" "Download failed."
        return 1
    fi
    if ! pkg_install "$pkg" "Python $ver"; then
        record "Python" "Failed" "Installer failed."
        return 1
    fi
    add_to_path "/usr/local/bin"
    if command_exists python3; then
        ok "Python $ver installed."
        record "Python" "Installed" ""
    else
        warn "python3 not visible in this session."
        record "Python" "Warning" "Needs a new terminal for PATH."
    fi
}

install_node() {
    step "Checking Node.js"
    if [ "$FORCE" -ne 1 ] && command_exists node; then
        ok "Node.js already installed: $(node --version 2>&1 | head -1)"
        record "Node.js" "Present" "$(node --version 2>&1 | head -1)"
        return 0
    fi
    local url ver
    url=$(get_latest_node_url) || true
    if [ -n "$url" ]; then
        # Extract version from URL path: .../v24.18.1/node-v24.18.1.pkg
        ver=$(basename "$(dirname "$url")" | sed 's/^v//')
    else
        ver="$NODE_VERSION"
        url="https://nodejs.org/dist/v${ver}/node-v${ver}.pkg"
        warn "Node.js latest-version lookup failed; using pinned ${ver}."
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would install Node.js ${ver} from $url"
        record "Node.js" "DryRun" "$url"
        return 0
    fi
    local pkg="$SETUP_TMP/node-v${ver}.pkg"
    if ! download "$url" "$pkg" "Node.js ${ver}"; then
        record "Node.js" "Failed" "Download failed."
        return 1
    fi
    if ! pkg_install "$pkg" "Node.js ${ver}"; then
        record "Node.js" "Failed" "Installer failed."
        return 1
    fi
    add_to_path "/usr/local/bin"
    if command_exists node; then
        ok "Node.js ${ver} installed."
        record "Node.js" "Installed" ""
    else
        warn "node not visible in this session."
        record "Node.js" "Warning" "Needs a new terminal for PATH."
    fi
}

# ---------------------------------------------------------------------------
# Tier 2 -- toolchains
# ---------------------------------------------------------------------------
install_uv()   { run_curl_installer "uv" "https://astral.sh/uv/install.sh" "uv" "$HOME/.local/bin"; }
install_bun()  { run_curl_installer "Bun" "https://bun.sh/install" "bun" "$HOME/.bun/bin"; }
install_deno() { run_curl_installer "Deno" "https://deno.land/install.sh" "deno" "$HOME/.deno/bin"; }

# ---------------------------------------------------------------------------
# Tier 3 -- CLI layer
# ---------------------------------------------------------------------------
install_claude_code() {
    run_curl_installer "Claude Code" "https://claude.ai/install.sh" "claude" "$HOME/.local/bin"
}

install_grok() {
    local grok_bin="${GROKBINDIR:-$HOME/.grok/bin}"
    if [ "$FORCE" -eq 1 ] || ! command_exists grok; then
        warn "Grok Build is gated to SuperGrok / X Premium+ accounts. Install will succeed; first-run OAuth will fail without an eligible subscription."
    fi
    run_curl_installer "Grok Build" "https://x.ai/cli/install.sh" "grok" "$grok_bin"
}

install_gh() {
    step "Checking GitHub CLI"
    if [ "$FORCE" -ne 1 ] && command_exists gh; then
        ok "GitHub CLI already installed."
        record "GitHub CLI" "Present" ""
        return 0
    fi
    local url
    url=$(get_github_asset_url "cli/cli" 'macOS_amd64\.tar\.gz$') || true
    if [ -z "$url" ]; then
        url="https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_macOS_amd64.tar.gz"
        warn "Using pinned fallback for GitHub CLI."
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would install GitHub CLI from $url"
        record "GitHub CLI" "DryRun" "$url"
        return 0
    fi
    local tgz="$SETUP_TMP/$(basename "$url")"
    if ! download "$url" "$tgz" "GitHub CLI"; then
        record "GitHub CLI" "Failed" "Download failed."
        return 1
    fi
    local extract="$SETUP_TMP/gh-extract"
    rm -rf "$extract"; mkdir -p "$extract"
    tar -xzf "$tgz" -C "$extract"
    local ghbin share
    ghbin=$(find "$extract" -name gh -type f 2>/dev/null | head -1)
    if [ -z "$ghbin" ]; then
        fail "gh binary not found in archive."
        record "GitHub CLI" "Failed" "Extraction produced no binary."
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    cp "$ghbin" "$HOME/.local/bin/gh"
    chmod +x "$HOME/.local/bin/gh"
    share=$(find "$extract" -type d -name share 2>/dev/null | head -1)
    [ -n "$share" ] && mkdir -p "$HOME/.local/share" && cp -R "$share/." "$HOME/.local/share/" 2>/dev/null
    add_to_path "$HOME/.local/bin"
    if command_exists gh; then
        ok "GitHub CLI installed."
        record "GitHub CLI" "Installed" ""
    else
        warn "gh not visible in this session."
        record "GitHub CLI" "Warning" "Needs a new terminal for PATH."
    fi
}

install_npm_global() {
    local name="$1" check="$2" pkg="$3"
    step "Checking $name"
    if [ "$FORCE" -ne 1 ] && command_exists "$check"; then
        ok "$name already installed."
        record "$name" "Present" ""
        return 0
    fi
    if ! command_exists npm; then
        warn "npm not found (Node.js skipped or failed). $name requires npm."
        record "$name" "Skipped" "npm unavailable."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would run: npm install -g $pkg"
        record "$name" "DryRun" ""
        return 0
    fi
    info "Installing $name via npm ..."
    npm install -g "$pkg" --no-fund --no-audit
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name install failed (npm exit $rc)."
        record "$name" "Failed" "npm exit $rc"
        return 1
    fi
    add_to_path "/usr/local/bin"
    if command_exists "$check"; then
        ok "$name installed successfully."
        record "$name" "Installed" ""
    else
        warn "$name installed but '$check' not visible in this session."
        record "$name" "Warning" "Needs a new terminal for PATH."
    fi
}

install_opencode() { install_npm_global "OpenCode" "opencode" "opencode-ai"; }
install_vite()     { install_npm_global "Vite" "vite" "vite"; }

install_supabase() {
    step "Checking Supabase CLI"
    if [ "$FORCE" -ne 1 ] && command_exists supabase; then
        ok "Supabase CLI already installed."
        record "Supabase CLI" "Present" ""
        return 0
    fi
    warn "'supabase start' needs the Docker engine (which needs virtualization). Remote commands (login, link, db push/pull, functions deploy, gen types) work normally."
    local url
    url=$(get_github_asset_url "supabase/cli" 'darwin_amd64\.tar\.gz$') || true
    if [ -z "$url" ]; then
        url="https://github.com/supabase/cli/releases/download/v2.111.0/supabase_2.111.0_darwin_amd64.tar.gz"
        warn "Using pinned fallback for Supabase CLI."
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would install Supabase CLI from $url"
        record "Supabase CLI" "DryRun" "$url"
        return 0
    fi
    local tgz="$SETUP_TMP/$(basename "$url")"
    if ! download "$url" "$tgz" "Supabase CLI"; then
        record "Supabase CLI" "Failed" "Download failed."
        return 1
    fi
    local extract="$SETUP_TMP/supabase-extract"
    rm -rf "$extract"; mkdir -p "$extract"
    tar -xzf "$tgz" -C "$extract"
    local bin
    bin=$(find "$extract" -name supabase -type f 2>/dev/null | head -1)
    if [ -z "$bin" ]; then
        fail "supabase binary not found in archive."
        record "Supabase CLI" "Failed" "Extraction produced no binary."
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    cp "$bin" "$HOME/.local/bin/supabase"
    chmod +x "$HOME/.local/bin/supabase"
    add_to_path "$HOME/.local/bin"
    if command_exists supabase; then
        ok "Supabase CLI installed successfully."
        record "Supabase CLI" "Installed" ""
    else
        warn "supabase not visible in this session."
        record "Supabase CLI" "Warning" "Needs a new terminal for PATH."
    fi
}

install_strix() {
    step "Checking Strix (AI pentesting agent)"
    if [ "$FORCE" -ne 1 ] && command_exists strix; then
        ok "Strix already installed."
        record "Strix" "Present" ""
    else
        if ! command_exists uv; then
            warn "uv not found. Strix installs through uv -- ensure Tier 2 runs first."
            record "Strix" "Skipped" "uv unavailable."
            return 0
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[DRYRUN] Would run: uv tool install strix-agent --python 3.12 (litellm<1.89.0 fallback if no Xcode CLT)"
            record "Strix" "DryRun" ""
            return 0
        fi
        local uvargs=(tool install strix-agent --python 3.12)
        [ "$FORCE" -eq 1 ] && uvargs+=(--force)
        local has_toolchain=0
        if xcode-select -p >/dev/null 2>&1 && command_exists clang; then
            has_toolchain=1
        fi
        if [ "$has_toolchain" -ne 1 ]; then
            warn "Xcode CLT/clang not found. litellm >= 1.89.0 ships a Rust extension needing a toolchain; will constrain to litellm<1.89.0 (pure Python, no build step)."
        fi
        local installed=0
        if [ "$has_toolchain" -eq 1 ]; then
            info "Attempt 1: unconstrained install (toolchain present)..."
            uv "${uvargs[@]}"
            local rc=$?
            if [ "$rc" -eq 0 ]; then
                installed=1
            else
                warn "Unconstrained install failed (exit $rc). Falling back to litellm<1.89.0 constraint."
            fi
        fi
        if [ "$installed" -ne 1 ]; then
            local constraint="$SETUP_TMP/strix-litellm-constraint.txt"
            printf 'litellm<1.89.0\n' > "$constraint"
            local uvc=("${uvargs[@]}" --constraint "$constraint")
            if [ "$FORCE" -eq 1 ] || [ "$has_toolchain" -ne 1 ]; then
                uvc+=(--reinstall)
            fi
            info "Attempt 2: install with litellm<1.89.0 (pure-Python, no Rust build)..."
            uv "${uvc[@]}"
            local rc2=$?
            if [ "$rc2" -eq 0 ]; then
                installed=1
                warn "Strix installed with litellm < 1.89.0 (no Rust extension). Install Xcode CLT and re-run with -Force to upgrade."
            fi
        fi
        if [ "$installed" -ne 1 ]; then
            fail "strix-agent installation failed on both attempts."
            fail "To fix: install Xcode Command Line Tools, then re-run with -Force."
            record "Strix" "Failed" "Both constrained and unconstrained uv install failed."
            return 1
        fi
        add_to_path "$HOME/.local/bin"
        if command_exists strix; then
            ok "Strix installed successfully."
            record "Strix" "Installed" ""
        else
            warn "strix-agent installed but 'strix' is not visible in this session."
            record "Strix" "Warning" "Needs a new terminal for PATH."
        fi
    fi
    if command_exists docker && docker info >/dev/null 2>&1; then
        ok "Docker daemon reachable -- Strix will pull its sandbox image on first scan."
    else
        warn "Docker daemon not reachable. Strix scans run inside a container; start Docker Desktop first."
    fi
}

# ---------------------------------------------------------------------------
# Tier 3.5 -- MCP servers (npm packages) + config
# ---------------------------------------------------------------------------
install_mcp_servers() {
    step "Installing MCP servers (npm global)"
    if ! command_exists npm; then
        warn "npm not found (Node.js skipped or failed). MCP servers require npm."
        record "MCP servers" "Skipped" "npm unavailable."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would install ${#MCP_PACKAGES[@]} MCP packages via npm -g:"
        local entry
        for entry in "${MCP_PACKAGES[@]}"; do
            info "  - ${entry##* }"
        done
        record "MCP servers" "DryRun" ""
        return 0
    fi
    local installed=0
    local failed=()
    local entry pkg rc
    for entry in "${MCP_PACKAGES[@]}"; do
        pkg="${entry##* }"
        info "Installing $pkg ..."
        npm install -g "$pkg" --no-fund --no-audit
        rc=$?
        if [ "$rc" -eq 0 ]; then
            installed=$((installed + 1))
        else
            warn "$pkg installation failed (npm exit $rc)."
            failed+=("$pkg")
        fi
    done
    add_to_path "/usr/local/bin"
    if [ ${#failed[@]} -eq 0 ]; then
        ok "All ${#MCP_PACKAGES[@]} MCP servers installed."
        record "MCP servers" "Installed" "$installed/${#MCP_PACKAGES[@]} packages"
    elif [ "$installed" -gt 0 ]; then
        warn "Partial MCP install: $installed succeeded, ${#failed[@]} failed."
        record "MCP servers" "Warning" "Failed: ${failed[*]}"
    else
        fail "All MCP server installs failed."
        record "MCP servers" "Failed" "Every npm install returned non-zero."
    fi
}

configure_opencode_mcp() {
    step "Registering MCP servers with opencode"
    local config_dir="$HOME/.config/opencode"
    local config_path="$config_dir/opencode.json"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would register ${#MCP_PACKAGES[@]} MCP servers in $config_path"
        record "Opencode MCP" "DryRun" "$config_path"
        return 0
    fi
    if ! command_exists node; then
        warn "node not found -- cannot merge the opencode config."
        record "Opencode MCP" "Skipped" "node unavailable."
        return 0
    fi
    mkdir -p "$config_dir"
    # Merge with node: robust JSON handling, no BOM, array-style commands.
    node -e '
const fs = require("fs");
const path = process.argv[1];
const servers = {
  "github":     "@modelcontextprotocol/server-github",
  "sequential": "@modelcontextprotocol/server-sequential-thinking",
  "memory":     "@modelcontextprotocol/server-memory",
  "context7":   "@upstash/context7-mcp",
  "sentry":     "@sentry/mcp-server",
  "supabase":   "@supabase/mcp-server-supabase"
};
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); } catch (e) { cfg = {}; }
cfg.mcp = cfg.mcp || {};
for (const key of Object.keys(servers)) {
  cfg.mcp[key] = { type: "local", command: ["npx", "-y", servers[key]], enabled: true };
}
cfg["$schema"] = cfg["$schema"] || "https://opencode.ai/config.json";
fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
' "$config_path"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "MCP servers registered in opencode global config: $config_path"
        warn "Restart opencode for the MCP servers to be picked up (config loads once at startup)."
        record "Opencode MCP" "Installed" "$config_path"
    else
        fail "Could not write opencode config (node exit $rc)."
        record "Opencode MCP" "Failed" "node merge failed."
    fi
}

configure_sentry_environment() {
    step "Configuring Sentry MCP environment"
    if [ -z "$SENTRY_AUTH_TOKEN" ] && [ -z "$SENTRY_ORG" ]; then
        skip "No -SentryAuthToken / -SentryOrg supplied. Sentry MCP will prompt at first use."
        record "Sentry config" "Skipped" "No credentials supplied."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would set SENTRY_AUTH_TOKEN / SENTRY_ORG in ~/.zshenv."
        record "Sentry config" "DryRun" ""
        return 0
    fi
    warn "Tokens are written to ~/.zshenv and exported for the session. Clear them when done."
    persist_env "SENTRY_AUTH_TOKEN" "$SENTRY_AUTH_TOKEN"
    persist_env "SENTRY_ORG" "$SENTRY_ORG"
    ok "Sentry MCP environment configured."
    record "Sentry config" "Installed" "Env vars set in ~/.zshenv."
}

# ---------------------------------------------------------------------------
# Tier 4 -- heavy / GUI
# ---------------------------------------------------------------------------
install_vscode() {
    step "Checking VS Code"
    if [ "$FORCE" -ne 1 ] && command_exists code; then
        ok "VS Code already installed."
        record "VS Code" "Present" ""
        return 0
    fi
    local url="https://update.code.visualstudio.com/latest/darwin/stable"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would install VS Code from $url"
        record "VS Code" "DryRun" "$url"
        return 0
    fi
    local zip="$SETUP_TMP/VSCode-darwin.zip"
    if ! download "$url" "$zip" "VS Code"; then
        record "VS Code" "Failed" "Download failed."
        return 1
    fi
    info "Extracting ..."
    local extract="$SETUP_TMP/vscode-extract"
    rm -rf "$extract"; mkdir -p "$extract"
    unzip -q "$zip" -d "$extract"
    if [ ! -d "$extract/Visual Studio Code.app" ]; then
        fail "Visual Studio Code.app not found in archive."
        record "VS Code" "Failed" "Unexpected archive layout."
        return 1
    fi
    rm -rf "/Applications/Visual Studio Code.app"
    if ! $SUDO cp -R "$extract/Visual Studio Code.app" /Applications/; then
        record "VS Code" "Failed" "Copy to /Applications failed."
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    ln -sf "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" "$HOME/.local/bin/code"
    add_to_path "$HOME/.local/bin"
    if command_exists code; then
        ok "VS Code installed."
        record "VS Code" "Installed" "/Applications/Visual Studio Code.app"
    else
        warn "code CLI not visible in this session."
        record "VS Code" "Warning" "Needs a new terminal for PATH."
    fi
}

install_postgresql() {
    step "Checking PostgreSQL"
    if [ "$FORCE" -ne 1 ] && command_exists psql; then
        ok "PostgreSQL already installed."
        record "PostgreSQL" "Present" ""
        return 0
    fi
    local url="https://get.enterprisedb.com/postgresql/postgresql-$POSTGRES_VERSION-osx-x64.dmg"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would install PostgreSQL $POSTGRES_VERSION from $url (superuser password: postgres)."
        record "PostgreSQL" "DryRun" "$url"
        return 0
    fi
    warn "Superuser 'postgres' password is set to 'postgres' (unattended default). Change it after install: ALTER USER postgres WITH PASSWORD 'newpassword';"
    local dmg="$SETUP_TMP/postgresql-$POSTGRES_VERSION.dmg"
    if ! download "$url" "$dmg" "PostgreSQL $POSTGRES_VERSION"; then
        warn "If this 404'd, the pinned build string is stale. Re-run with -PostgresVersion '<major>.<minor>-<build>'."
        record "PostgreSQL" "Failed" "Download failed (check -PostgresVersion)."
        return 1
    fi
    info "This install takes several minutes."
    local mount="/Volumes/pgsetup"
    if ! hdiutil attach -nobrowse -mountpoint "$mount" "$dmg" >/dev/null; then
        fail "hdiutil attach failed."
        record "PostgreSQL" "Failed" "DMG mount failed."
        return 1
    fi
    local pkg
    pkg=$(find "$mount" -maxdepth 3 -name '*.pkg' 2>/dev/null | head -1)
    if [ -z "$pkg" ]; then
        warn "No .pkg found inside the EDB DMG -- skipping."
        hdiutil detach "$mount" >/dev/null 2>&1
        record "PostgreSQL" "Skipped" "No pkg inside DMG."
        return 0
    fi
    pkg_install "$pkg" "PostgreSQL $POSTGRES_VERSION"
    local rc=$?
    hdiutil detach "$mount" >/dev/null 2>&1
    if [ "$rc" -ne 0 ]; then
        record "PostgreSQL" "Failed" "Installer failed."
        return 1
    fi
    local pg_bin=""
    local d
    for d in /Library/PostgreSQL/*/bin; do
        if [ -d "$d" ] && [ -x "$d/psql" ]; then pg_bin="$d"; fi
    done
    if [ -n "$pg_bin" ]; then
        add_to_path "$pg_bin"
        ok "PostgreSQL installed. Connect with: psql -U postgres (password: postgres)"
        record "PostgreSQL" "Installed" "$pg_bin"
    else
        warn "PostgreSQL installed but the bin directory was not located."
        record "PostgreSQL" "Warning" "Install dir not found."
    fi
}

# ---------------------------------------------------------------------------
# Tier 4.5 -- LSP / language tooling (Python + JS/TS + Go + Rust)
# ---------------------------------------------------------------------------
#   Python: pyright (LSP), ruff (lint/format), black, isort, mypy
#           -- installed via `uv tool install` (isolated venvs + PATH shims)
#   JS/TS:  typescript-language-server, typescript, eslint,
#           vscode-langservers-extracted (html/css/json/eslint/md LSPs)
#           -- installed via `npm install -g`
#   Go:     Go runtime from go.dev (.pkg) if absent, then
#           `go install golang.org/x/tools/gopls@latest`
#   Rust:   rustup from sh.rustup.rs (-y --profile minimal) if absent, then
#           `rustup component add rust-analyzer`
# ---------------------------------------------------------------------------

install_python_lsp() {
    step "Checking Python LSP / lint (pyright, ruff, black, isort, mypy)"
    if ! command_exists uv; then
        warn "uv not found (Tier 2 skipped). Python LSP installs via uv tool -- skipping."
        record "Python LSP" "Skipped" "uv unavailable."
        return 0
    fi
    local tools="pyright ruff black isort mypy"
    if [ "$DRY_RUN" -eq 1 ]; then
        for t in $tools; do info "[DRYRUN] Would run: uv tool install $t"; done
        record "Python LSP" "DryRun" "$tools"
        return 0
    fi

    local installed=0 failed=""
    for t in $tools; do
        if [ "$FORCE" -ne 1 ] && command_exists "$t"; then
            ok "$t already installed."
            installed=$((installed + 1)); continue
        fi
        info "uv tool install $t ..."
        if uv tool install "$t"; then
            installed=$((installed + 1))
        else
            warn "$t install failed (uv exit $?)."
            failed="$failed $t"
        fi
    done

    local count=5
    if [ -z "$failed" ]; then
        ok "Python LSP stack complete ($installed/$count)."
        record "Python LSP" "Installed" "$tools"
    elif [ "$installed" -gt 0 ]; then
        warn "Partial Python LSP: $installed ok, failed:$failed."
        record "Python LSP" "Warning" "Failed:$failed"
    else
        fail "All Python LSP installs failed."
        record "Python LSP" "Failed" "Every uv tool install returned non-zero."
    fi
}

install_node_lsp() {
    step "Checking JS/TS LSP / lint (ts-ls, tsc, eslint, vscode-langservers)"
    if ! command_exists npm; then
        warn "npm not found (Node.js skipped). JS/TS LSP requires npm -- skipping."
        record "JS/TS LSP" "Skipped" "npm unavailable."
        return 0
    fi
    local pkgs="typescript-language-server typescript eslint vscode-langservers-extracted"
    if [ "$DRY_RUN" -eq 1 ]; then
        for p in $pkgs; do info "[DRYRUN] Would run: npm install -g $p"; done
        record "JS/TS LSP" "DryRun" "$pkgs"
        return 0
    fi

    local installed=0 failed=""
    local probe_pkg probe_cmd
    for pkg in $pkgs; do
        case "$pkg" in
            typescript-language-server)   probe_cmd="typescript-language-server" ;;
            typescript)                   probe_cmd="tsc" ;;
            eslint)                       probe_cmd="eslint" ;;
            vscode-langservers-extracted) probe_cmd="vscode-html-language-server" ;;
        esac
        if [ "$FORCE" -ne 1 ] && command_exists "$probe_cmd"; then
            ok "$pkg already installed (probe: $probe_cmd)."
            installed=$((installed + 1)); continue
        fi
        info "npm install -g $pkg ..."
        if npm install -g "$pkg" --no-fund --no-audit; then
            installed=$((installed + 1))
        else
            warn "$pkg install failed (npm exit $?)."
            failed="$failed $pkg"
        fi
    done

    local count=4
    if [ -z "$failed" ]; then
        ok "JS/TS LSP stack complete ($installed/$count)."
        record "JS/TS LSP" "Installed" "$pkgs"
    elif [ "$installed" -gt 0 ]; then
        warn "Partial JS/TS LSP: $installed ok, failed:$failed."
        record "JS/TS LSP" "Warning" "Failed:$failed"
    else
        fail "All JS/TS LSP installs failed."
        record "JS/TS LSP" "Failed" "Every npm install returned non-zero."
    fi
}

install_go_lsp() {
    step "Checking Go + gopls (Go LSP)"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would: install Go runtime if absent, then go install golang.org/x/tools/gopls@latest"
        record "Go LSP" "DryRun" ""
        return 0
    fi

    if ! command_exists go; then
        # Download the official .pkg from go.dev. ~80 MB.
        local go_ver="${GO_VERSION:-1.23.4}"
        local arch_label
        if [ "$(uname -m)" = "arm64" ]; then arch_label="arm64"; else arch_label="amd64"; fi
        local url="https://go.dev/dl/go${go_ver}.darwin-${arch_label}.pkg"
        local dest="$SETUP_TMP/go-${go_ver}.pkg"
        info "Downloading Go $go_ver from $url ..."
        if ! curl -fsSL -o "$dest" "$url"; then
            fail "Go download failed."
            record "Go LSP" "Failed" "Go download failed."
            return 1
        fi
        info "Installing Go $go_ver .pkg ..."
        pkg_install "$dest" "Go $go_ver"
        local rc=$?
        if [ "$rc" -ne 0 ]; then
            record "Go LSP" "Failed" "Go pkg install failed (exit $rc)."
            return 1
        fi
        add_to_path "/usr/local/go/bin"
        export PATH="$PATH:/usr/local/go/bin"
        ok "Go runtime installed."
    else
        ok "Go runtime already present."
    fi

    if ! command_exists go; then
        warn "go still not on PATH -- gopls cannot be installed. Open a new shell and re-run."
        record "Go LSP" "Warning" "Go installed but not on PATH."
        return 0
    fi

    if [ "$FORCE" -ne 1 ] && command_exists gopls; then
        ok "gopls already installed."
        record "Go LSP" "Present" "go + gopls"
        return 0
    fi

    info "go install golang.org/x/tools/gopls@latest ..."
    if ! go install golang.org/x/tools/gopls@latest; then
        fail "gopls install failed (go exit $?)."
        record "Go LSP" "Failed" "go exit $?"
        return 1
    fi
    local gobin
    gobin="$(go env GOPATH)/bin"
    add_to_path "$gobin"

    if command_exists gopls; then
        ok "gopls installed."
        record "Go LSP" "Installed" "go + gopls"
    else
        warn "gopls installed but not visible in this session."
        record "Go LSP" "Warning" "Needs a new shell for PATH."
    fi
}

install_rust_lsp() {
    step "Checking Rust + rust-analyzer (Rust LSP)"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would: install rustup if absent, then rustup component add rust-analyzer"
        record "Rust LSP" "DryRun" ""
        return 0
    fi

    if ! command_exists rustup; then
        info "Downloading rustup from https://sh.rustup.rs ..."
        local dest="$SETUP_TMP/rustup-init.sh"
        if ! curl -fsSL -o "$dest" https://sh.rustup.rs; then
            fail "rustup download failed."
            record "Rust LSP" "Failed" "rustup download failed."
            return 1
        fi
        info "Running rustup-init -y --default-toolchain stable --profile minimal ..."
        if ! sh "$dest" -y --default-toolchain stable --profile minimal; then
            fail "rustup-init failed."
            record "Rust LSP" "Failed" "rustup-init returned non-zero."
            return 1
        fi
        local cargo_bin="$HOME/.cargo/bin"
        add_to_path "$cargo_bin"
        export PATH="$PATH:$cargo_bin"
        ok "Rust toolchain installed via rustup."
    else
        ok "rustup already present."
    fi

    if ! command_exists rustup; then
        warn "rustup still not on PATH -- rust-analyzer cannot be added. Open a new shell and re-run."
        record "Rust LSP" "Warning" "rustup installed but not on PATH."
        return 0
    fi

    if [ "$FORCE" -ne 1 ] && command_exists rust-analyzer; then
        ok "rust-analyzer already installed."
        record "Rust LSP" "Present" "rustup + rust-analyzer"
        return 0
    fi

    info "rustup component add rust-analyzer ..."
    if ! rustup component add rust-analyzer; then
        fail "rust-analyzer component add failed (rustup exit $?)."
        record "Rust LSP" "Failed" "rustup exit $?"
        return 1
    fi

    if command_exists rust-analyzer; then
        ok "rust-analyzer installed."
        record "Rust LSP" "Installed" "rustup + rust-analyzer"
    else
        warn "rust-analyzer installed but not visible in this session."
        record "Rust LSP" "Warning" "Needs a new shell for PATH."
    fi
}

install_lsp_servers() {
    step "Installing LSP / language tooling (Tier 4.5)"
    install_python_lsp
    install_node_lsp
    install_go_lsp
    install_rust_lsp
}

# ---------------------------------------------------------------------------
# Tier 5 -- configuration
# ---------------------------------------------------------------------------
set_git_identity() {
    step "Checking Git identity (user.name / user.email)"
    if ! command_exists git; then
        warn "git not on PATH -- skipping identity configuration."
        record "Git identity" "Skipped" "git unavailable."
        return 0
    fi
    local name email
    name=$(git config --global user.name 2>/dev/null)
    email=$(git config --global user.email 2>/dev/null)
    if [ "$FORCE" -ne 1 ] && [ -n "$name" ] && [ -n "$email" ]; then
        ok "Git identity already configured: $name <$email>"
        record "Git identity" "Present" "$name <$email>"
        return 0
    fi
    if [ -z "$GIT_USER_NAME" ] || [ -z "$GIT_USER_EMAIL" ]; then
        if [ "$ACCEPT_ALL" -eq 1 ]; then
            [ -z "$GIT_USER_NAME" ] && GIT_USER_NAME="Sandbox User"
            [ -z "$GIT_USER_EMAIL" ] && GIT_USER_EMAIL="sandbox@localhost.invalid"
            warn "No -GitUserName/-GitUserEmail supplied. Applying unattended defaults so commits work: $GIT_USER_NAME <$GIT_USER_EMAIL>. Override before pushing to a real remote."
        else
            [ -z "$GIT_USER_NAME" ] && read -r -p "Git commit author name (e.g. 'Jane Doe'): " GIT_USER_NAME
            [ -z "$GIT_USER_EMAIL" ] && read -r -p "Git commit author email (e.g. you@users.noreply.github.com): " GIT_USER_EMAIL
        fi
    fi
    if [ -z "$GIT_USER_NAME" ] || [ -z "$GIT_USER_EMAIL" ]; then
        warn "Name/email not provided -- commits will fail until set manually."
        record "Git identity" "Skipped" "No values provided."
        return 0
    fi
    # DryRun check placed BEFORE any interaction.
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would set git user.name '$GIT_USER_NAME' / user.email '$GIT_USER_EMAIL'"
        record "Git identity" "DryRun" ""
        return 0
    fi
    git config --global user.name "$GIT_USER_NAME"
    git config --global user.email "$GIT_USER_EMAIL"
    ok "Git identity set: $GIT_USER_NAME <$GIT_USER_EMAIL>"
    record "Git identity" "Installed" "$GIT_USER_NAME <$GIT_USER_EMAIL>"
}

configure_strix_environment() {
    step "Configuring Strix environment"
    if [ -z "$STRIX_LLM" ] && [ -z "$STRIX_API_KEY" ]; then
        skip "No -StrixLlm / -StrixApiKey supplied. Strix will prompt on first run; it caches answers to ~/.strix/cli-config.json."
        record "Strix config" "Skipped" "No credentials supplied."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would set STRIX_LLM / LLM_API_KEY (+ optional LLM_API_BASE, PERPLEXITY_API_KEY) in ~/.zshenv."
        record "Strix config" "DryRun" ""
        return 0
    fi
    warn "API keys are written to ~/.zshenv and exported. Clear them when done."
    persist_env "STRIX_LLM" "$STRIX_LLM"
    persist_env "LLM_API_KEY" "$STRIX_API_KEY"
    persist_env "LLM_API_BASE" "$STRIX_API_BASE"
    persist_env "PERPLEXITY_API_KEY" "$PERPLEXITY_API_KEY"
    [ -z "$STRIX_LLM" ] && warn "STRIX_LLM not set -- Strix will prompt for the model on first run."
    [ -z "$STRIX_API_KEY" ] && warn "LLM_API_KEY not set -- Strix will prompt for the key on first run."
    ok "Strix environment configured."
    record "Strix config" "Installed" "Env vars set in ~/.zshenv."
}

# ---------------------------------------------------------------------------
# Tier 6 -- Docker Desktop (opt-in, last)
# ---------------------------------------------------------------------------
install_docker() {
    step "Checking Docker Desktop"
    if [ "$FORCE" -ne 1 ] && command_exists docker; then
        ok "Docker CLI already present."
        record "Docker Desktop" "Present" ""
        return 0
    fi
    local url="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would install Docker Desktop from $url"
        record "Docker Desktop" "DryRun" "$url"
        return 0
    fi
    local dmg="$SETUP_TMP/Docker.dmg"
    if ! download "$url" "$dmg" "Docker Desktop"; then
        record "Docker Desktop" "Failed" "Download failed."
        return 1
    fi
    info "This is a large install and may take 10+ minutes."
    local mount="/Volumes/docker-desktop"
    if ! hdiutil attach -nobrowse -mountpoint "$mount" "$dmg" >/dev/null; then
        fail "hdiutil attach failed."
        record "Docker Desktop" "Failed" "DMG mount failed."
        return 1
    fi
    if [ -d "$mount/Docker.app" ]; then
        rm -rf "/Applications/Docker.app"
        $SUDO cp -R "$mount/Docker.app" /Applications/
        local rc=$?
        hdiutil detach "$mount" >/dev/null 2>&1
        if [ "$rc" -ne 0 ]; then
            record "Docker Desktop" "Failed" "Copy to /Applications failed."
            return 1
        fi
    elif [ -d "$mount/Installer.app" ]; then
        info "Docker Desktop installer app detected; launching the GUI installer."
        open "$mount/Installer.app"
        hdiutil detach "$mount" >/dev/null 2>&1
        record "Docker Desktop" "Warning" "GUI installer launched -- finish it manually."
        return 0
    else
        hdiutil detach "$mount" >/dev/null 2>&1
        fail "Docker.app not found in DMG."
        record "Docker Desktop" "Failed" "Unexpected DMG layout."
        return 1
    fi
    add_to_path "/Applications/Docker.app/Contents/Resources/bin"
    if command_exists docker; then
        ok "Docker Desktop installed. Start the app once, then verify with 'docker info'."
        record "Docker Desktop" "Installed" ""
    else
        warn "Docker Desktop installed but 'docker' is not visible in this session."
        record "Docker Desktop" "Warning" "Start the app, then open a new terminal."
    fi
}

# ---------------------------------------------------------------------------
# Tier 7 -- workspace + GitHub auth + repo picker
# ---------------------------------------------------------------------------
initialize_workspace() {
    step "Creating clrogon workspace tree"
    local folders=(projects archive mcp logs scripts templates powershell architecture security downloads)
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would create $WORKSPACE_ROOT and ${#folders[@]} subfolders."
        record "Workspace" "DryRun" "$WORKSPACE_ROOT"
        return 0
    fi
    mkdir -p "$WORKSPACE_ROOT"
    local f
    for f in "${folders[@]}"; do
        mkdir -p "$WORKSPACE_ROOT/$f"
    done
    ok "Workspace ready at $WORKSPACE_ROOT"
    record "Workspace" "Installed" "$WORKSPACE_ROOT"
}

connect_github() {
    step "GitHub authentication"
    if ! command_exists gh; then
        warn "GitHub CLI not installed (Tier 3 skipped or failed). Skipping auth."
        record "GitHub auth" "Skipped" "gh unavailable."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would run: gh auth login --hostname github.com --git-protocol https --web"
        record "GitHub auth" "DryRun" ""
        return 0
    fi
    if gh auth status >/dev/null 2>&1; then
        ok "Already authenticated to GitHub."
        record "GitHub auth" "Present" "gh auth status OK"
        return 0
    fi
    info "Browser authentication will open. Complete the device flow in your default browser."
    if gh auth login --hostname github.com --git-protocol https --web; then
        gh auth status
        ok "Authenticated to GitHub."
        record "GitHub auth" "Installed" ""
    else
        warn "gh auth login returned exit code $? -- authentication may be incomplete."
        record "GitHub auth" "Warning" "gh auth login failed."
    fi
}

select_github_repository() {
    step "Selecting GitHub repository to clone"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRYRUN] Would: gh repo list ${GITHUB_USER:-<gh-authenticated-user>} --limit 200, present menu, clone into $WORKSPACE_ROOT/projects"
        record "Repository clone" "DryRun" ""
        return 0
    fi
    if ! command_exists gh; then
        warn "GitHub CLI not found -- repo picker skipped."
        record "Repository clone" "Skipped" "gh unavailable."
        return 0
    fi
    if ! command_exists git; then
        warn "git not found -- repo picker skipped."
        record "Repository clone" "Skipped" "git unavailable."
        return 0
    fi
    if ! gh auth status >/dev/null 2>&1; then
        warn "Not authenticated to GitHub. Run the auth stage first (or re-run without -SkipWorkspace)."
        record "Repository clone" "Skipped" "gh not authenticated."
        return 0
    fi
    if [ -z "$GITHUB_USER" ]; then
        GITHUB_USER=$(gh api user --jq '.login' 2>/dev/null)
        if [ -z "$GITHUB_USER" ]; then
            warn "Could not resolve the authenticated GitHub user -- pass -GithubUser explicitly."
            record "Repository clone" "Skipped" "GITHUB_USER not resolved."
            return 0
        fi
    fi
    info "Loading repositories for '$GITHUB_USER' (limit 200) ..."
    local names=()
    local line n
    while IFS= read -r line; do
        n=$(printf '%s' "$line" | awk -F'\t' '{print $1}')
        [ -n "$n" ] && names+=("$n")
    done < <(gh repo list "$GITHUB_USER" --limit 200 2>/dev/null)
    if [ ${#names[@]} -eq 0 ]; then
        warn "No repositories listed for '$GITHUB_USER'."
        record "Repository clone" "Skipped" "No repositories listed."
        return 0
    fi
    echo ""
    echo "Repositories for $GITHUB_USER"
    echo "------------------------------------------------------------"
    local i
    for ((i=0; i<${#names[@]}; i++)); do
        printf '[%3d] %s\n' "$((i+1))" "${names[$i]}"
    done
    echo "------------------------------------------------------------"
    echo "  0  Cancel"
    read -r -p "Select repository number (1-${#names[@]}, 0 to cancel): " sel
    [ -z "$sel" ] && sel=0
    if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
        warn "Invalid selection '$sel' -- must be a number."
        record "Repository clone" "Skipped" "Non-numeric selection."
        return 0
    fi
    if [ "$sel" -eq 0 ]; then
        skip "Repository clone cancelled by user."
        record "Repository clone" "Skipped" "User cancelled."
        return 0
    fi
    if [ "$sel" -lt 1 ] || [ "$sel" -gt ${#names[@]} ]; then
        warn "Selection out of range: $sel (must be 1-${#names[@]})."
        record "Repository clone" "Skipped" "Out of range."
        return 0
    fi
    local repo="${names[$((sel-1))]}"
    local dest="$WORKSPACE_ROOT/projects/$repo"
    if [ -d "$dest" ]; then
        ok "Repository already present at $dest -- skipping clone."
    else
        info "Cloning $GITHUB_USER/$repo into $dest ..."
        if ! gh repo clone "$GITHUB_USER/$repo" "$dest"; then
            fail "gh repo clone failed."
            record "Repository clone" "Failed" "gh repo clone failed."
            return 1
        fi
        ok "Repository cloned to $dest"
    fi
    persist_env "CLAUDIO_CURRENT_REPO" "$dest"
    ok "CLAUDIO_CURRENT_REPO = $dest (~/.zshenv)"
    if command_exists code; then
        info "Opening repository in VS Code ..."
        code "$dest"
    else
        warn "VS Code 'code' CLI not found. Open $dest manually once PATH refreshes."
    fi
    record "Repository clone" "Installed" "$dest"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
run_stage() {
    local name="$1"; shift
    local before=${#RESULTS[@]}
    "$@"
    local rc=$?
    if [ "${#RESULTS[@]}" -eq "$before" ] && [ "$rc" -eq 0 ]; then
        record "$name" "Warning" "Stage returned without reporting a result."
    fi
}

main() {
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "This script targets macOS only (Darwin)." >&2
        return 1
    fi
    if [ "$(uname -m)" != "x86_64" ]; then
        echo "This is the Intel (x86_64) build; detected $(uname -m). Use the Apple Silicon build instead." >&2
        return 1
    fi

    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
        if ! sudo -n true 2>/dev/null; then
            warn "Admin rights are needed for Python/Node/VS Code/PostgreSQL/Docker installs. Caching sudo password now..."
            sudo -v || { fail "sudo is required to continue."; return 1; }
        fi
    fi

    mkdir -p "$SETUP_TMP"

    echo -e "${C_STEP}Claude Code Sandbox Setup v3.2 (macOS) -- direct download, unattended${C_RESET}"
    echo "============================================================="
    echo " Architecture   : $(uname -m)"
    echo " macOS          : $(sw_vers -productVersion 2>/dev/null)"
    echo " Administrator  : $([ "$(id -u)" -eq 0 ] && echo root || echo no)"
    echo " Unattended     : $([ "$ACCEPT_ALL" -eq 1 ] && echo yes || echo no)"
    echo " Log            : $LOG_PATH"
    [ "$DRY_RUN" -eq 1 ] && echo -e "${C_WARN} DRY RUN        : no changes will be made${C_RESET}"

    if [ "$ACCEPT_ALL" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        warn "Running without -AcceptAll: vendor installer scripts will prompt for confirmation. Pass -AcceptAll for a fully unattended run."
    fi

    # Skip-aware stage runner: records a Skipped result instead of running.
    stage_or_skip() {
        local name="$1" skip="$2" reason="$3"; shift 3
        if [ "$skip" -eq 1 ]; then
            step "Checking $name"
            skip "$reason"
            record "$name" "Skipped" "$reason"
            return 0
        fi
        run_stage "$name" "$@"
    }

    # ---- Tier 1: runtimes --------------------------------------------------
    stage_or_skip "Git"      "$SKIP_GIT"          "Skipped by -SkipGit"        install_git
    stage_or_skip "Python"   "$SKIP_PYTHON"       "Skipped by -SkipPython"     install_python
    stage_or_skip "Node.js"  "$SKIP_NODE"         "Skipped by -SkipNode"       install_node

    # ---- Tier 2: toolchains ------------------------------------------------
    stage_or_skip "uv"   "$SKIP_UV"   "Skipped by -SkipUv"   install_uv
    stage_or_skip "Bun"  "$SKIP_BUN"  "Skipped by -SkipBun"  install_bun
    stage_or_skip "Deno" "$SKIP_DENO" "Skipped by -SkipDeno" install_deno

    # ---- Tier 3: CLI layer -------------------------------------------------
    stage_or_skip "GitHub CLI"   "$SKIP_GH"       "Skipped by -SkipGh"       install_gh
    stage_or_skip "Claude Code"  "$SKIP_CLAUDE"   "Skipped by -SkipClaude"   install_claude_code
    stage_or_skip "OpenCode"     "$SKIP_OPENCODE" "Skipped by -SkipOpenCode" install_opencode
    stage_or_skip "Vite"         "$SKIP_VITE"     "Skipped by -SkipVite"     install_vite
    stage_or_skip "Grok Build"   "$SKIP_GROK"     "Skipped by -SkipGrok"     install_grok
    stage_or_skip "Supabase CLI" "$SKIP_SUPABASE" "Skipped by -SkipSupabase" install_supabase
    stage_or_skip "Strix"        "$SKIP_STRIX"    "Skipped by -SkipStrix"    install_strix

    # ---- Tier 3.5: MCP layer (npm packages + config) ----------------------
    stage_or_skip "MCP servers"  "$SKIP_MCP" "Skipped by -SkipMcp" install_mcp_servers
    stage_or_skip "Opencode MCP" "$SKIP_MCP" "Skipped by -SkipMcp" configure_opencode_mcp

    # ---- Tier 4: heavy / GUI ----------------------------------------------
    stage_or_skip "VS Code"     "$SKIP_VSCODE"    "Skipped by -SkipVSCode"    install_vscode
    stage_or_skip "PostgreSQL"  "$SKIP_POSTGRES"  "Skipped by -SkipPostgres"  install_postgresql

    # ---- Tier 4.5: LSP / language tooling ---------------------------------
    stage_or_skip "LSP servers" "$SKIP_LSP"       "Skipped by -SkipLsp"       install_lsp_servers

    # ---- Tier 5: configuration --------------------------------------------
    stage_or_skip "Git identity"  "$SKIP_GIT_IDENTITY" "Skipped by -SkipGitIdentity" set_git_identity
    stage_or_skip "Strix config"  "$SKIP_STRIX"        "Skipped by -SkipStrix"        configure_strix_environment
    stage_or_skip "Sentry config" "$SKIP_SENTRY"       "Skipped by -SkipSentry"       configure_sentry_environment

    # ---- Tier 6: Docker Desktop (opt-in, last) -----------------------------
    if [ "$INSTALL_DOCKER" -eq 1 ]; then
        run_stage "Docker Desktop" install_docker
    else
        step "Checking Docker Desktop"
        skip "Not requested (-InstallDocker)."
        record "Docker Desktop" "Skipped" "Not requested (-InstallDocker)."
    fi

    # ---- Tier 7: workspace + GitHub + repo select --------------------------
    stage_or_skip "Workspace"       "$SKIP_WORKSPACE"  "Skipped by -SkipWorkspace"  initialize_workspace
    stage_or_skip "GitHub auth"     "$SKIP_WORKSPACE"  "Skipped by -SkipWorkspace"  connect_github
    stage_or_skip "Repository clone" "$SKIP_REPO_CLONE" "Skipped by -SkipRepoClone" select_github_repository

    # ---- Cleanup + summary -------------------------------------------------
    local failed=()
    local tool status detail r
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r tool status detail <<< "$r"
        [ "$status" = "Failed" ] && failed+=("$tool")
    done

    if [ "$NO_CLEANUP" -ne 1 ] && [ "$DRY_RUN" -ne 1 ] && [ ${#failed[@]} -eq 0 ]; then
        rm -rf "$SETUP_TMP"
        ok "Temporary download files cleaned."
    elif [ ${#failed[@]} -gt 0 ]; then
        warn "Temp files kept at $SETUP_TMP for diagnosis."
    fi

    echo ""
    echo "============================================================="
    echo "SUMMARY"
    printf '  %-16s %-10s %s\n' "TOOL" "STATUS" "DETAIL"
    local col
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r tool status detail <<< "$r"
        case "$status" in
            Installed|Present) col="$C_OK" ;;
            DryRun)            col="$C_STEP" ;;
            Skipped|Warning)   col="$C_WARN" ;;
            Failed)            col="$C_FAIL" ;;
            *)                 col="" ;;
        esac
        printf '  %s%-16s %-10s %s%s\n' "$col" "$tool" "$status" "$detail" "$C_RESET"
    done

    local warns=0
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r tool status detail <<< "$r"
        [ "$status" = "Warning" ] && warns=$((warns + 1))
    done
    if [ "$warns" -gt 0 ]; then
        echo "Open a NEW terminal for PATH / env changes to take effect, then re-run to confirm." 
    fi

    if [ ${#failed[@]} -gt 0 ]; then
        echo "${#failed[@]} tool(s) failed: ${failed[*]}. Log: $LOG_PATH"
        return 2
    fi
    echo "All requested tools completed. Log: $LOG_PATH"
    return 0
}

if [ -z "$LOG_PATH" ]; then
    LOG_PATH="$HOME/Setup-ClaudeCodeSandbox_$(date +%Y%m%d-%H%M%S).log"
fi

main 2>&1 | tee -a "$LOG_PATH"
exit "${PIPESTATUS[0]}"