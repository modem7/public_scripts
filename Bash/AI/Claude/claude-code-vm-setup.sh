#!/usr/bin/env bash
# ============================================================================
#  Claude Code VM Provisioner (Ubuntu 24.04)
#  Installs and configures a full Claude Code dev environment on an existing
#  Ubuntu 24.04 VM, using a regular sudo-capable user (no root login required).
#
#  Adapted from https://github.com/serversathome/ServersatHome/blob/main/agentic.sh
#  - Removed: Proxmox host checks, LXC container creation/start, root-only SSH
#    login setup, timezone override, and the Watchtower / Code-Server compose
#    stacks (Docker itself is still installed).
#  - Adapted: everything that ran as root inside a fresh LXC now runs as your
#    normal user, escalating with `sudo` only where actually required.
#  - Added: GitHub CLI (gh) + SSH key generation so this VM can push/pull from
#    GitHub, and notes for driving Claude Code on this VM from the Claude
#    Desktop app on Windows via Remote Control (outbound-HTTPS only, no
#    inbound ports needed).
#  - Locale set to en_GB.UTF-8. Ctrl+C during the run is trapped for a clean
#    exit instead of leaving background processes or a half-configured apt.
#  - Only languages, build tools, and Claude Code itself are unconditional.
#    Docker, GitHub CLI + SSH/auth, the recommended plugin bundle, and the
#    webapp-testing skill + Playwright are each asked about up front (Y/n,
#    default yes) as opinionated good-practice extras — decline any of them
#    and the generated settings.json / CLAUDE.md reflect that (no dangling
#    references to tools that were never installed).
#  - Plugin bundle (if accepted): frontend-design, code-review,
#    commit-commands, security-guidance, context7, superpowers,
#    deployment-engineer (community, from ccplugins/awesome-claude-code-plugins),
#    plus docker/github plugins if those extras were also accepted.
#  - Idempotent: safe to re-run. apt installs, GitHub CLI auth, SSH key
#    generation, shell rc blocks, and the webapp-testing skill copy all check
#    existing state before acting instead of blindly re-doing/duplicating it.
#  - Claude Code itself installs from Anthropic's signed apt repo (gpg
#    fingerprint verified against the published key), not the curl|bash
#    native installer — same binary, but plain `apt upgrade claude-code`
#    updates instead of a self-updating background process.
#  - Shell env (PATH, aliases, cargo env, project auto-cd) is written to both
#    ~/.bashrc and ~/.zshrc (if zsh is installed), each idempotently.
#
#  Run on the target VM (as the sudo user, NOT as root):
#    curl -fsSL <raw-url-to-this-file> -o /tmp/claude-code-vm-setup.sh && bash /tmp/claude-code-vm-setup.sh
#
# ============================================================================

set -euo pipefail

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        Claude Code VM Provisioner (Ubuntu)      ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Signal handling / cleanup ───────────────────────────────────────────────
# CURRENT_STEP is updated right before each major stage so Ctrl+C tells you
# where things stopped instead of just dying silently mid-apt-install.
CURRENT_STEP="startup"
SUDO_KEEPALIVE_PID=""

cleanup() {
  local exit_code=$?
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  exit "$exit_code"
}

on_interrupt() {
  echo ""
  warn "Interrupted during: ${CURRENT_STEP}"
  warn "Cleaning up and exiting. Re-run the script to pick up where package installs left off"
  warn "(apt/dpkg is idempotent); if apt looks locked afterwards, run: sudo dpkg --configure -a"
  exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -ne 0 ]] || error "Run this as your normal user, not root/sudo. The script escalates with sudo only where needed."

  command -v sudo &>/dev/null || error "sudo is required but not installed."

  info "Checking sudo access (you may be prompted for your password)..."
  sudo -v || error "Could not obtain sudo privileges."

  # Keep sudo alive for the duration of the script
  ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
      warn "This script targets Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown}. Continuing anyway..."
    fi
  else
    warn "Could not detect OS version. Continuing anyway..."
  fi
}

# ── Git identity + optional extras (asked up front so the long install can run unattended) ──
get_git_config() {
  echo -e "${BOLD}Git / GitHub Setup${NC}"
  echo "─────────────────────────────────────────────────"

  local default_name default_email
  default_name=$(git config --global user.name 2>/dev/null || true)
  default_email=$(git config --global user.email 2>/dev/null || true)

  read -rp "Git user.name${default_name:+ [$default_name]}: " GIT_NAME
  GIT_NAME="${GIT_NAME:-$default_name}"
  [[ -n "$GIT_NAME" ]] || error "Git user.name is required."

  read -rp "Git user.email${default_email:+ [$default_email]}: " GIT_EMAIL
  GIT_EMAIL="${GIT_EMAIL:-$default_email}"
  [[ -n "$GIT_EMAIL" ]] || error "Git user.email is required."

  read -rp "Set up GitHub access now (installs gh CLI + SSH key + 'gh auth login')? [Y/n]: " SETUP_GITHUB
  SETUP_GITHUB="${SETUP_GITHUB:-y}"
  echo ""

  echo -e "${BOLD}Optional Extras${NC}"
  echo "─────────────────────────────────────────────────"
  echo "The base install above (languages, build tools, Claude Code itself) always runs."
  echo "These are opinionated good-practice additions on top of it — decline any you don't want."
  echo ""

  read -rp "Install Docker Engine + Compose plugin? [Y/n]: " INSTALL_DOCKER
  INSTALL_DOCKER="${INSTALL_DOCKER:-y}"

  read -rp "Install the recommended Claude Code plugin bundle (frontend-design, code-review, commit-commands, security-guidance, context7, superpowers, deployment-engineer — plus docker/github plugins if you installed those above)? [Y/n]: " INSTALL_PLUGINS
  INSTALL_PLUGINS="${INSTALL_PLUGINS:-y}"

  read -rp "Install the webapp-testing skill + Playwright (browser-based UI testing for Claude Code)? [Y/n]: " INSTALL_WEBAPP_TESTING
  INSTALL_WEBAPP_TESTING="${INSTALL_WEBAPP_TESTING:-y}"
  echo ""
}

# ── Provision ───────────────────────────────────────────────────────────────
provision() {
  export DEBIAN_FRONTEND=noninteractive

  # Resilient apt installer: try the batch, then fall back to one-by-one so a
  # single renamed/dropped package can't abort the whole run under `set -e`.
  apt_install() {
    if ! sudo apt-get install -y -qq "$@" >/dev/null 2>&1; then
      echo "    [warn] batch install failed; retrying individually..."
      local p
      for p in "$@"; do
        sudo apt-get install -y -qq "$p" >/dev/null 2>&1 || echo "    [warn] skipped (unavailable): $p"
      done
    fi
  }

  CURRENT_STEP="Generating locale (en_GB.UTF-8)"
  echo ">>> Generating locale (en_GB.UTF-8)..."
  sudo apt-get update -qq
  apt_install locales
  sudo sed -i '/en_GB.UTF-8/s/^# //g' /etc/locale.gen
  sudo locale-gen en_GB.UTF-8 > /dev/null 2>&1
  sudo update-locale LANG=en_GB.UTF-8 LC_ALL=en_GB.UTF-8
  export LANG=en_GB.UTF-8
  export LC_ALL=en_GB.UTF-8

  CURRENT_STEP="Updating system"
  echo ">>> Updating system..."
  sudo apt-get upgrade -y -qq

  CURRENT_STEP="Installing core packages"
  echo ">>> Installing core packages..."
  apt_install \
    git curl wget unzip zip \
    ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
    bash-completion locales \
    htop nano vim tmux screen \
    jq yq tree \
    net-tools iproute2 iputils-ping bind9-dnsutils \
    cron logrotate

  CURRENT_STEP="Installing build tools & dev libraries"
  echo ">>> Installing build tools & dev libraries..."
  apt_install \
    build-essential make cmake pkg-config autoconf automake libtool \
    python3 python3-pip python3-venv python3-dev \
    libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
    libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt1-dev

  CURRENT_STEP="Installing search & productivity tools"
  echo ">>> Installing search & productivity tools..."
  apt_install \
    ripgrep fd-find fzf bat \
    rsync \
    sqlite3

  CURRENT_STEP="Installing database clients"
  echo ">>> Installing database clients..."
  apt_install \
    postgresql-client redis-tools

  CURRENT_STEP="Installing Node.js 22.x LTS"
  echo ">>> Installing Node.js 22.x LTS..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
  echo "    Node.js $(node --version) / npm $(npm --version)"

  CURRENT_STEP="Installing global npm packages"
  echo ">>> Installing global npm packages..."
  sudo npm install -g typescript ts-node eslint prettier

  CURRENT_STEP="Installing Go"
  echo ">>> Installing Go..."
  GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
  curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
  echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh > /dev/null
  echo "    Go $(/usr/local/go/bin/go version | awk '{print $3}')"

  CURRENT_STEP="Installing Rust"
  echo ">>> Installing Rust (as your user, no sudo needed)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
  echo "    Rust $(rustc --version | awk '{print $2}')"

  if [[ "${INSTALL_DOCKER,,}" == y* ]]; then
    CURRENT_STEP="Installing Docker"
    echo ">>> Installing Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo systemctl enable docker
    sudo apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
    echo "    Docker $(sudo docker --version | awk '{print $3}' | tr -d ',')"
    echo "    Compose $(sudo docker compose version --short 2>/dev/null || echo 'included with Docker')"

    CURRENT_STEP="Adding user to docker group"
    echo ">>> Adding $USER to the docker group (run docker without sudo)..."
    # get.docker.com's installer creates the docker group as part of installing
    # docker-ce, but groupadd here is a harmless, idempotent safety net in case
    # that ever changes or the group was removed some other way.
    getent group docker >/dev/null 2>&1 || sudo groupadd docker
    sudo usermod -aG docker "$USER"
    if groups | grep -qw docker; then
      info "docker group already active in this session."
    else
      warn "You must log out and back in (or run 'newgrp docker') before 'docker' works without sudo."
    fi
  else
    info "Skipping Docker (declined)."
  fi

  CURRENT_STEP="Setting up Git identity"
  echo ">>> Setting up Git identity..."
  git config --global user.name "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
  git config --global init.defaultBranch main
  git config --global core.editor nano
  git config --global pull.rebase false

  GITHUB_SSH_KEY="$HOME/.ssh/id_ed25519"
  if [[ "${SETUP_GITHUB,,}" == "y" || "${SETUP_GITHUB,,}" == "yes" ]]; then
    CURRENT_STEP="Installing GitHub CLI (gh)"
    echo ">>> Installing GitHub CLI (gh)..."
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update -qq
    apt_install gh
    echo "    gh $(gh --version | head -1 | awk '{print $3}')"

    CURRENT_STEP="Setting up SSH key for GitHub"
    echo ">>> Setting up SSH key for GitHub..."
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    if [[ ! -f "$GITHUB_SSH_KEY" ]]; then
      ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$GITHUB_SSH_KEY" -N ""
    else
      info "SSH key already exists at $GITHUB_SSH_KEY, reusing it."
    fi
    eval "$(ssh-agent -s)" > /dev/null
    ssh-add "$GITHUB_SSH_KEY" 2>/dev/null || true
    grep -q "github.com" "$HOME/.ssh/known_hosts" 2>/dev/null || ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

    echo ""
    echo -e "${BOLD}Your public key (add this at https://github.com/settings/keys if 'gh auth login' doesn't do it for you):${NC}"
    cat "${GITHUB_SSH_KEY}.pub"
    echo ""

    if gh auth status -h github.com >/dev/null 2>&1; then
      info "gh is already authenticated (gh auth status OK) — skipping gh auth login."
    else
      CURRENT_STEP="Running gh auth login"
      echo ">>> Running 'gh auth login' (interactive — follow the browser/device-code prompts)..."
      gh auth login -h github.com || warn "gh auth login did not complete; run it again later with: gh auth login"
    fi
    gh auth setup-git 2>/dev/null || true
  else
    info "Skipping GitHub CLI + SSH/auth setup (declined). Re-run this script section later, or install gh manually."
  fi

  CURRENT_STEP="Installing Claude Code (apt)"
  echo ">>> Installing Claude Code (via Anthropic's signed apt repo)..."
  # Uses Anthropic's official apt repo rather than the curl|bash native
  # installer: same underlying binary, but plain apt-managed updates
  # (sudo apt update && sudo apt upgrade claude-code) instead of a
  # self-updating background process, and gpg-verified end to end.
  CLAUDE_APT_KEYRING="/etc/apt/keyrings/claude-code.asc"
  sudo install -d -m 0755 /etc/apt/keyrings
  sudo curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o "$CLAUDE_APT_KEYRING"
  CLAUDE_KEY_FPR=$(gpg --show-keys --with-colons "$CLAUDE_APT_KEYRING" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')
  if [[ "$CLAUDE_KEY_FPR" != "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE" ]]; then
    error "Claude Code apt signing key fingerprint mismatch (got: ${CLAUDE_KEY_FPR:-none}, expected 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE) - refusing to trust it. See https://code.claude.com/docs/en/setup#install-with-linux-package-managers"
  fi
  echo "deb [signed-by=${CLAUDE_APT_KEYRING}] https://downloads.claude.ai/claude-code/apt/stable stable main" | sudo tee /etc/apt/sources.list.d/claude-code.list > /dev/null
  sudo apt-get update -qq
  apt_install claude-code
  echo "    Claude Code $(claude --version 2>/dev/null || echo 'installed')"

  CURRENT_STEP="Configuring Claude Code permissions + plugins"
  echo ">>> Configuring Claude Code permissions + plugins..."
  mkdir -p "$HOME/.claude"

  # Base settings.json: just enough to avoid permission prompts. No personal
  # opinions baked in here (no plugins, no env tuning) — those are opt-in below.
  cat > "$HOME/.claude/settings.json" << 'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "MultiEdit(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "TodoRead(*)",
      "TodoWrite(*)",
      "Grep(*)",
      "Glob(*)",
      "LS(*)",
      "Task(*)",
      "mcp__*"
    ]
  }
}
SETTINGS

  if [[ "${INSTALL_PLUGINS,,}" == y* ]]; then
    echo "    Adding recommended plugin bundle to settings.json..."
    # claude-plugins-official is built into every Claude Code install, so its
    # plugins need no marketplace declaration. Third-party marketplaces
    # (superpowers, awesome-claude-code-plugins) must be declared in
    # extraKnownMarketplaces. docker/github plugins are only added if the
    # matching tool was actually installed above.
    PLUGIN_JSON='{
      "frontend-design@claude-plugins-official": true,
      "code-review@claude-plugins-official": true,
      "commit-commands@claude-plugins-official": true,
      "security-guidance@claude-plugins-official": true,
      "context7@claude-plugins-official": true,
      "superpowers@superpowers-marketplace": true,
      "deployment-engineer@awesome-claude-code-plugins": true
    }'
    [[ "${INSTALL_DOCKER,,}" == y* ]] && PLUGIN_JSON=$(jq '. + {"docker@claude-plugins-official": true}' <<< "$PLUGIN_JSON")
    [[ "${SETUP_GITHUB,,}" == y* ]] && PLUGIN_JSON=$(jq '. + {"github@claude-plugins-official": true}' <<< "$PLUGIN_JSON")

    tmp=$(mktemp)
    jq --argjson plugins "$PLUGIN_JSON" '
      .extraKnownMarketplaces = {
        "superpowers-marketplace": { "source": { "source": "github", "repo": "obra/superpowers-marketplace" } },
        "awesome-claude-code-plugins": { "source": { "source": "github", "repo": "ccplugins/awesome-claude-code-plugins" } }
      } | .enabledPlugins = $plugins
    ' "$HOME/.claude/settings.json" > "$tmp" && mv "$tmp" "$HOME/.claude/settings.json"
  else
    info "Skipping recommended plugin bundle (declined)."
  fi

  CURRENT_STEP="Enabling Claude Code Remote Control auto-start"
  echo ">>> Enabling Claude Code Remote Control auto-start..."
  # The CLI auto-starts a phone/browser-controllable session when
  # remoteControlAtStartup=true in ~/.claude.json (connect from claude.ai/code or
  # the Claude mobile app). settings.json has no documented key for this; the
  # in-app equivalent is the /config toggle. Requires a Pro/Max login
  # (run: claude /login) — API keys are NOT supported for Remote Control.
  if command -v jq >/dev/null 2>&1; then
    if [[ -f "$HOME/.claude.json" ]]; then
      tmp=$(mktemp); jq '.remoteControlAtStartup = true' "$HOME/.claude.json" > "$tmp" && mv "$tmp" "$HOME/.claude.json"
    else
      echo '{ "remoteControlAtStartup": true }' > "$HOME/.claude.json"
    fi
  else
    echo "    [warn] jq missing; skipping remote-control auto-start (enable later via /config)."
  fi

  CURRENT_STEP="Setting up ~/project directory"
  echo ">>> Setting up ~/project directory..."
  mkdir -p "$HOME/project"

  DOCKER_TOOLS_LINE=""
  DOCKER_USAGE_SECTION=""
  if [[ "${INSTALL_DOCKER,,}" == y* ]]; then
    DOCKER_TOOLS_LINE="- **Docker**: Docker Engine + Compose plugin installed (\`$USER\` is in the \`docker\` group; no containers deployed by default)"
    DOCKER_USAGE_SECTION="
## Docker Usage
Docker and the Compose plugin are installed but no services are deployed by default. Log out and
back in (or run \`newgrp docker\`) so group membership takes effect, then \`docker run hello-world\`
to verify.
"
  fi

  GITHUB_ACCESS_SECTION=""
  if [[ "${SETUP_GITHUB,,}" == y* ]]; then
    GITHUB_ACCESS_SECTION="
## GitHub Access
- **gh CLI** is installed; auth was configured via \`gh auth login\` during setup (re-run any time).
- **SSH key**: ~/.ssh/id_ed25519(.pub) — add the public half at https://github.com/settings/keys
  if it isn't already linked via \`gh\`. github.com's host key is pre-seeded in ~/.ssh/known_hosts.
- Verify with: \`gh auth status\` and \`ssh -T git@github.com\`.
- Clone with either \`gh repo clone owner/repo\` or standard \`git clone git@github.com:owner/repo.git\`.
"
  fi

  PLUGINS_SECTION=""
  if [[ "${INSTALL_PLUGINS,,}" == y* ]]; then
    PLUGINS_SECTION="
## Installed Plugins
Declared in ~/.claude/settings.json and installed from their marketplaces on first launch.
Run /plugin to confirm they're active or add more.
- **frontend-design** (claude-plugins-official): production-grade UI aesthetics
- **code-review** (claude-plugins-official): multi-agent PR review with confidence scoring
- **commit-commands** (claude-plugins-official): git commit/push/PR workflows (/commit, /push, /pr)
- **security-guidance** (claude-plugins-official): warnings when editing sensitive files
- **context7** (claude-plugins-official): live, version-specific library docs (reduces API hallucinations)
- **superpowers** (superpowers-marketplace): brainstorm → plan → implement (TDD) workflow
  - /superpowers:brainstorm, /superpowers:write-plan, /superpowers:execute-plan
  - Auto-activating skills: test-driven-development, systematic-debugging, verification-before-completion
- **deployment-engineer** (awesome-claude-code-plugins, community): CI/CD pipelines, Docker,
  cloud/Kubernetes deployment workflows"
    [[ "${INSTALL_DOCKER,,}" == y* ]] && PLUGINS_SECTION="${PLUGINS_SECTION}
- **docker** (claude-plugins-official): build images, manage containers/Compose, container networking"
    [[ "${SETUP_GITHUB,,}" == y* ]] && PLUGINS_SECTION="${PLUGINS_SECTION}
- **github** (claude-plugins-official): issues, PRs, code review, repo search, Actions"
    PLUGINS_SECTION="${PLUGINS_SECTION}
"
  fi

  SKILLS_SECTION=""
  if [[ "${INSTALL_WEBAPP_TESTING,,}" == y* ]]; then
    SKILLS_SECTION="
## Installed Skills
- **webapp-testing** (~/.claude/skills/): Playwright-based browser testing for UI verification
"
  fi

  cat > "$HOME/project/CLAUDE.md" << CLAUDEMD
# Claude Code Workspace

## Environment
- **OS**: Ubuntu 24.04 VM
- **Working directory**: $HOME/project
- **User**: $USER (sudo-capable, not root)
- **Locale**: en_GB.UTF-8
- **Shell**: environment (PATH, aliases, cargo env, project auto-cd) is configured in both
  ~/.bashrc and ~/.zshrc (if zsh is installed)

## Available Tools
- **Languages**: Node.js 22 LTS, Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
$DOCKER_TOOLS_LINE
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
All tools are pre-approved — no permission prompts. Bash, Read, Write, Edit, WebFetch, WebSearch, Task, and MCP tools all run without confirmation.

## Subagents
Define reusable ones as Markdown files in ~/.claude/agents/ (see /agents). tmux is installed for
split-pane visualization if you're running several at once. Agent teams are an opt-in feature
(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in ~/.claude/settings.json env) — not enabled by default
by this setup; add it yourself if you want teammates that share findings and coordinate rather
than just report back.

## Remote Control (drive this VM from Claude Desktop on Windows)
Auto-start is configured (remoteControlAtStartup in ~/.claude.json), which corresponds to the
**Enable Remote Control for all sessions** setting (/config, or Settings → Claude Code → Enable
remote control by default in Claude Desktop). Requires a Pro/Max login — run \`claude\` then
\`/login\` on this VM first (API keys are not supported for Remote Control).

To connect from the Windows Claude Desktop app:
1. On this VM: \`cd ~/project && claude\` (or \`claude remote-control\` for server mode, which
   supports multiple concurrent sessions and shows a QR code).
2. In Claude Desktop on Windows: open Settings → Claude Code, confirm remote control is enabled,
   then find this machine's session in the session list (or open claude.ai/code in a browser).
3. The connection is outbound-HTTPS only from this VM — no inbound firewall/port-forwarding is
   needed on the VM or your router.
4. The local \`claude\` process must keep running for the remote session to stay connected.

$GITHUB_ACCESS_SECTION
$DOCKER_USAGE_SECTION
## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in $HOME/project/
- When installing Python packages, use: pip install --break-system-packages <package>
$PLUGINS_SECTION
$SKILLS_SECTION
CLAUDEMD

  if [[ "${INSTALL_WEBAPP_TESTING,,}" == y* ]]; then
    CURRENT_STEP="Installing webapp-testing skill"
    echo ">>> Installing webapp-testing skill (from anthropics/skills)..."
    rm -rf /tmp/anthropic-skills
    git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills
    (cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing)
    mkdir -p "$HOME/.claude/skills/"
    rm -rf "$HOME/.claude/skills/webapp-testing"
    cp -r /tmp/anthropic-skills/skills/webapp-testing "$HOME/.claude/skills/webapp-testing"
    rm -rf /tmp/anthropic-skills

    CURRENT_STEP="Installing Playwright"
    echo ">>> Installing Playwright for webapp-testing skill..."
    npx -y playwright install --with-deps chromium
  else
    info "Skipping webapp-testing skill + Playwright (declined)."
  fi

  CURRENT_STEP="Setting up shell environment"
  echo ">>> Setting up shell environment (bash + zsh if present)..."
  # Quoted heredoc: nothing here is expanded now — $HOME, $PATH, etc. stay
  # literal and get evaluated later, when each rc file is actually sourced.
  RC_BLOCK=$(cat <<'RCBLOCK'

# ── Claude Code Environment ──────────────────────────────────
export EDITOR=nano
export LANG=en_GB.UTF-8
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"

# Rust/Cargo (rustup normally wires this into shell profiles itself, but this
# makes it explicit and safe to re-source even if that ever doesn't happen)
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

# Aliases
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Start in ~/project on login (only for interactive login shells, so it
# doesn't hijack 'cd' in scripts or non-interactive sessions)
[[ $- == *i* ]] && cd "$HOME/project" 2>/dev/null || true
RCBLOCK
)

  RC_FILES=("$HOME/.bashrc")
  if command -v zsh >/dev/null 2>&1; then
    RC_FILES+=("$HOME/.zshrc")
  fi
  for rc in "${RC_FILES[@]}"; do
    touch "$rc"
    if grep -q "Claude Code Environment" "$rc" 2>/dev/null; then
      info "$(basename "$rc") already has the Claude Code block, skipping."
    else
      printf '%s\n' "$RC_BLOCK" >> "$rc"
      info "Added Claude Code environment block to $(basename "$rc")."
    fi
  done

  CURRENT_STEP="Setting up weekly auto-update cron"
  echo ">>> Setting up weekly auto-update cron..."
  cat > /tmp/system-update.cron << 'CRON'
# Weekly system update - Sunday 3:00 AM (system local time)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq >> /var/log/auto-update.log 2>&1
CRON
  sudo mv /tmp/system-update.cron /etc/cron.d/system-update
  sudo chown root:root /etc/cron.d/system-update
  sudo chmod 0644 /etc/cron.d/system-update

  cat > /tmp/auto-update.logrotate << 'LOGROTATE'
/var/log/auto-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE
  sudo mv /tmp/auto-update.logrotate /etc/logrotate.d/auto-update
  sudo chown root:root /etc/logrotate.d/auto-update

  CURRENT_STEP="Cleaning up"
  echo ">>> Cleaning up..."
  sudo apt-get autoremove -y -qq
  sudo apt-get clean -qq
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║       Claude Code VM Ready!                     ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}User:${NC}       $USER (sudo-capable)"
  echo -e "  ${BOLD}Project dir:${NC} $HOME/project"
  echo ""
  echo -e "  ${BOLD}Next steps:${NC}"
  step=1
  if [[ "${INSTALL_DOCKER,,}" == y* ]]; then
    echo -e "    ${step}. Log out and back in (or run: ${CYAN}newgrp docker${NC}) so the docker group applies"; step=$((step+1))
  fi
  echo -e "    ${step}. ${CYAN}source ~/.bashrc${NC} (or ~/.zshrc, or just open a new shell)"; step=$((step+1))
  if [[ "${SETUP_GITHUB,,}" == y* ]]; then
    echo -e "    ${step}. ${CYAN}gh auth status${NC}  /  ${CYAN}ssh -T git@github.com${NC}  — confirm GitHub access"; step=$((step+1))
  fi
  echo -e "    ${step}. ${CYAN}cd ~/project && claude${NC}, then ${CYAN}/login${NC} (Pro/Max required for Remote Control)"; step=$((step+1))
  echo -e "    ${step}. On Windows Claude Desktop: Settings → Claude Code → enable remote control, then"
  echo -e "       find this VM's session in the session list (or claude.ai/code) to drive it remotely"
  echo ""
  echo -e "  ${BOLD}Installed:${NC}"
  echo "    • Claude Code (apt)       • Node.js 22 LTS"
  echo "    • Python 3 + pip + venv   • Go (latest)"
  echo "    • Rust (via rustup)       • Build essentials"
  echo "    • ripgrep, fzf, fd        • PostgreSQL & Redis CLI"
  [[ "${INSTALL_DOCKER,,}" == y* ]] && echo "    • Docker + Compose (no containers deployed)"
  [[ "${SETUP_GITHUB,,}" == y* ]] && echo "    • Git + GitHub CLI (gh)"
  echo ""
  echo -e "  ${BOLD}Permissions:${NC}  All tools pre-approved (no prompts)"
  echo -e "  ${BOLD}Config:${NC}      ~/.claude/settings.json"
  if [[ "${INSTALL_PLUGINS,,}" == y* ]]; then
    plugin_list="frontend-design, code-review, commit-commands, security-guidance, context7, superpowers, deployment-engineer"
    [[ "${INSTALL_DOCKER,,}" == y* ]] && plugin_list="${plugin_list}, docker"
    [[ "${SETUP_GITHUB,,}" == y* ]] && plugin_list="${plugin_list}, github"
    echo -e "  ${BOLD}Plugins:${NC}     ${plugin_list}"
    echo -e "               (run /plugin to verify)"
  else
    echo -e "  ${BOLD}Plugins:${NC}     none (declined)"
  fi
  if [[ "${INSTALL_WEBAPP_TESTING,,}" == y* ]]; then
    echo -e "  ${BOLD}Skills:${NC}      webapp-testing"
  fi
  echo -e "  ${BOLD}Locale:${NC}      en_GB.UTF-8"
  echo -e "  ${BOLD}Auto-updates:${NC} System packages every Sunday 3 AM (local system time)"
  if [[ "${SETUP_GITHUB,,}" == y* ]]; then
    echo -e "  ${BOLD}GitHub:${NC}      SSH key at ~/.ssh/id_ed25519.pub — add at github.com/settings/keys"
    echo -e "               if 'gh auth login' didn't already link it"
  fi
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  header
  preflight
  get_git_config
  provision
  print_summary
}

main "$@"
