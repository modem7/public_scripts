#!/usr/bin/env bash
# ============================================================================
#  Claude Code VM Provisioner (Ubuntu 24.04)
#  Installs and configures a full Claude Code dev environment on an existing
#  Ubuntu VM, as a regular sudo-capable user (no root login required).
#
#  Adapted from https://github.com/serversathome/ServersatHome/blob/main/agentic.sh
#
#  What it does:
#  - Always: locale, core/build packages, Node.js LTS, Go, Rust, Claude Code.
#  - Optional (asked up front, default yes): Docker, GitHub CLI + SSH key +
#    `gh auth login`, the webapp-testing skill (Python Playwright), weekly
#    unattended apt upgrades.
#  - Claude Code config comes from ONE of:
#      a) claude-config-sync (https://github.com/modem7/claude-config-sync):
#         give it your private sync repo URL and it clones it to
#         ~/claude-config and runs its install.sh, so settings.json, CLAUDE.md,
#         hooks, skills, plugins and memory all come from your repo; or
#      b) a local baseline settings.json (+ optional plugin bundle), MERGED
#         into any existing file rather than overwriting it.
#  - Remote Control auto-start, so the VM can be driven from Claude Desktop /
#    claude.ai/code (outbound HTTPS only, no inbound ports).
#
#  Safe to re-run: every step checks existing state first. Generated shell rc
#  and CLAUDE.md content lives between marker comments and is refreshed in
#  place; anything you add outside the markers is left alone.
#
#  Usage (as the sudo user, NOT root):
#    curl -fsSL <raw-url-to-this-file> -o /tmp/claude-code-vm-setup.sh
#    bash /tmp/claude-code-vm-setup.sh [--yes] [--sync-repo URL | --no-sync]
#
#  Every prompt can be pre-answered with an environment variable, for
#  unattended runs (booleans accept y/yes/true/1 or n/no/false/0):
#    GIT_NAME, GIT_EMAIL             git identity
#    SETUP_GITHUB                    gh CLI + SSH key + gh auth login
#    INSTALL_DOCKER                  Docker Engine + Compose plugin
#    CLAUDE_SYNC_REPO_URL            claude-config-sync repo ("" = don't use it)
#    INSTALL_PLUGINS                 plugin bundle (local config mode only)
#    INSTALL_WEBAPP_TESTING          webapp-testing skill + Playwright
#    AUTO_UPDATE                     weekly apt upgrade cron
#  Other knobs:
#    PROJECT_DIR      (default ~/project)   LOCALE (default en_GB.UTF-8)
#    NODE_MAJOR       (default 24)          CLAUDE_INSTALL_METHOD (apt|native)
#    CLAUDE_SYNC_REPO_DIR (default ~/claude-config)
# ============================================================================

set -euo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-$HOME/project}"
LOCALE="${LOCALE:-en_GB.UTF-8}"
NODE_MAJOR_EXPLICIT="${NODE_MAJOR:+true}"
NODE_MAJOR="${NODE_MAJOR:-24}"
CLAUDE_INSTALL_METHOD="${CLAUDE_INSTALL_METHOD:-apt}"
CLAUDE_SYNC_REPO_DIR="${CLAUDE_SYNC_REPO_DIR:-$HOME/claude-config}"
CLAUDE_APT_KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
ASSUME_YES="false"
# Distinguishes "not set" from "set to empty" (= explicitly don't sync).
SYNC_URL_PRESET="${CLAUDE_SYNC_REPO_URL+set}"
CLAUDE_SYNC_REPO_URL="${CLAUDE_SYNC_REPO_URL:-}"

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
have()    { command -v "$1" >/dev/null 2>&1; }
# Prints "<cmd output> | <awk field>" or "n/a" — never fails, so it's safe
# inside assignments under set -e / pipefail.
ver()     { local out; out=$("${@:2}" 2>/dev/null | head -1 | awk "{print \$$1}") || true; echo "${out:-n/a}"; }
is_true() { [[ "${1,,}" =~ ^(y|yes|true|1)$ ]]; }

step() {
  CURRENT_STEP="$1"
  echo -e "\n${BOLD}>>> $1${NC}"
}

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        Claude Code VM Provisioner (Ubuntu)       ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

usage() {
  sed -n '2,/^# =====/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^=====/d'
}

# ask_yn VAR "question" — leaves a preset env value alone (normalised to
# true/false); otherwise prompts (default yes), or takes the default when
# --yes was given or there's no terminal to ask on.
ask_yn() {
  local var="$1" question="$2" answer="${!1:-}"
  if [[ -z "$answer" ]]; then
    if is_true "$ASSUME_YES" || [[ ! -t 0 ]]; then
      answer="y"
    else
      read -rp "$question [Y/n]: " answer
      answer="${answer:-y}"
    fi
  fi
  if is_true "$answer"; then printf -v "$var" true; else printf -v "$var" false; fi
}

# ask VAR "question" "default" — free-text version of ask_yn.
ask() {
  local var="$1" question="$2" default="${3:-}" answer="${!1:-}"
  if [[ -z "$answer" ]]; then
    if ! is_true "$ASSUME_YES" && [[ -t 0 ]]; then
      read -rp "${question}${default:+ [$default]}: " answer
    fi
    answer="${answer:-$default}"
  fi
  printf -v "$var" '%s' "$answer"
}

# Lenient installer for nice-to-have packages: try the batch, then fall back
# to one-by-one so a single renamed/dropped package can't abort the run.
apt_install() {
  if ! sudo apt-get install -y -qq "$@" >/dev/null 2>&1; then
    warn "batch install failed; retrying individually..."
    local p
    for p in "$@"; do
      sudo apt-get install -y -qq "$p" >/dev/null 2>&1 || warn "skipped (unavailable): $p"
    done
  fi
}

# Strict installer for packages the rest of the script depends on.
apt_install_required() {
  sudo apt-get install -y -qq "$@" >/dev/null || error "Failed to install required package(s): $*"
}

# write_managed_block FILE BEGIN END CONTENT — replaces the text between the
# BEGIN/END marker lines (or appends it if absent), so re-runs refresh the
# generated content without duplicating it or touching anything around it.
write_managed_block() {
  local file="$1" begin="$2" end="$3" content="$4" tmp
  touch "$file"
  tmp=$(mktemp -p "$WORK_DIR")
  awk -v b="$begin" -v e="$end" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$file" > "$tmp"
  # Drop trailing blank lines so repeated runs don't grow the file.
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp"
  # shellcheck disable=SC2094 # -s check happens before the append
  { [[ -s "$tmp" ]] && echo ""; printf '%s\n%s\n%s\n' "$begin" "$content" "$end"; } >> "$tmp"
  cat "$tmp" > "$file"   # cat, not mv: keeps the original file's owner/mode
}

# ── Signal handling / cleanup ───────────────────────────────────────────────
# CURRENT_STEP is updated before each stage so Ctrl+C / a failure says where
# things stopped instead of dying silently mid-install.
CURRENT_STEP="startup"
SUDO_KEEPALIVE_PID=""
WORK_DIR=$(mktemp -d)

cleanup() {
  local exit_code=$?
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  rm -rf "$WORK_DIR"
  if [[ $exit_code -ne 0 && $exit_code -ne 130 ]]; then
    echo -e "${RED}[ERROR]${NC} Failed during: ${CURRENT_STEP} (exit ${exit_code}). Fix the cause and re-run; completed steps are skipped." >&2
  fi
  exit "$exit_code"
}

on_interrupt() {
  echo ""
  warn "Interrupted during: ${CURRENT_STEP}"
  warn "Re-run the script to pick up where it left off; if apt looks locked afterwards, run: sudo dpkg --configure -a"
  exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# ── Arguments ──────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)    ASSUME_YES="true" ;;
      --sync-repo) [[ -n "${2:-}" ]] || error "--sync-repo needs a URL"
                   CLAUDE_SYNC_REPO_URL="$2"; SYNC_URL_PRESET="set"; shift ;;
      --no-sync)   CLAUDE_SYNC_REPO_URL=""; SYNC_URL_PRESET="set" ;;
      -h|--help)   usage; exit 0 ;;
      *)           error "Unknown argument: $1 (see --help)" ;;
    esac
    shift
  done
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -ne 0 ]] || error "Run this as your normal user, not root/sudo. The script escalates with sudo only where needed."
  have sudo    || error "sudo is required but not installed."
  have apt-get || error "This script needs an apt-based distro (Ubuntu 24.04 targeted)."

  info "Checking sudo access (you may be prompted for your password)..."
  sudo -v || error "Could not obtain sudo privileges."

  # Keep sudo alive for the duration of the script.
  ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
      warn "This script targets Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown}. Continuing anyway..."
    fi
  else
    warn "Could not detect OS version. Continuing anyway..."
  fi

  DPKG_ARCH=$(dpkg --print-architecture)
}

# ── Questions (all asked up front so the long install can run unattended) ──
gather_config() {
  echo -e "${BOLD}Git / GitHub Setup${NC}"
  echo "─────────────────────────────────────────────────"
  ask GIT_NAME  "Git user.name"  "$(git config --global user.name 2>/dev/null || true)"
  [[ -n "$GIT_NAME" ]]  || error "Git user.name is required (set GIT_NAME for unattended runs)."
  ask GIT_EMAIL "Git user.email" "$(git config --global user.email 2>/dev/null || true)"
  [[ -n "$GIT_EMAIL" ]] || error "Git user.email is required (set GIT_EMAIL for unattended runs)."
  ask_yn SETUP_GITHUB "Set up GitHub access (gh CLI + SSH key + 'gh auth login')?"
  echo ""

  echo -e "${BOLD}Claude Code Config${NC}"
  echo "─────────────────────────────────────────────────"
  if [[ -z "$SYNC_URL_PRESET" && -d "$CLAUDE_SYNC_REPO_DIR/.git" ]]; then
    # Already set up on a previous run — reuse it rather than asking again.
    CLAUDE_SYNC_REPO_URL=$(git -C "$CLAUDE_SYNC_REPO_DIR" remote get-url origin 2>/dev/null || true)
    info "Found existing claude-config-sync clone at $CLAUDE_SYNC_REPO_DIR ($CLAUDE_SYNC_REPO_URL)."
  elif [[ -z "$SYNC_URL_PRESET" ]]; then
    echo "If you keep your Claude Code config in a claude-config-sync repo"
    echo "(https://github.com/modem7/claude-config-sync), enter its git URL to pull"
    echo "settings, CLAUDE.md, hooks, skills, plugins and memory from it."
    echo "Leave blank to generate a local baseline config instead."
    ask CLAUDE_SYNC_REPO_URL "Sync repo URL" ""
  fi
  USE_SYNC=false
  [[ -n "$CLAUDE_SYNC_REPO_URL" ]] && USE_SYNC=true
  if $USE_SYNC && [[ "$CLAUDE_SYNC_REPO_URL" == git@github.com:* ]] && ! is_true "$SETUP_GITHUB" \
     && ! ssh-keygen -F github.com >/dev/null 2>&1; then
    warn "Sync repo uses SSH but GitHub setup was declined — the clone will only work if this VM already has a key GitHub trusts."
  fi
  echo ""

  echo -e "${BOLD}Optional Extras${NC}"
  echo "─────────────────────────────────────────────────"
  ask_yn INSTALL_DOCKER "Install Docker Engine + Compose plugin?"
  if $USE_SYNC; then
    INSTALL_PLUGINS=false   # plugins come from the synced settings.json
  else
    ask_yn INSTALL_PLUGINS "Enable the recommended Claude Code plugin bundle (frontend-design, code-review, commit-commands, security-guidance, context7, superpowers, deployment-engineer, + docker if installed)?"
  fi
  ask_yn INSTALL_WEBAPP_TESTING "Install the webapp-testing skill + Playwright (browser-based UI testing)?"
  ask_yn AUTO_UPDATE "Enable weekly unattended apt upgrades (Sunday 03:00)?"
  echo ""
}

# ── System ─────────────────────────────────────────────────────────────────
setup_locale() {
  step "Configuring locale ($LOCALE)"
  sudo apt-get update -qq
  apt_install_required locales
  local normalised="${LOCALE,,}"; normalised="${normalised/utf-8/utf8}"
  if locale -a 2>/dev/null | grep -qix "$normalised"; then
    info "$LOCALE already generated."
  else
    sudo sed -i "s/^# *\(${LOCALE//./\\.} \)/\1/" /etc/locale.gen
    sudo locale-gen "$LOCALE" >/dev/null
  fi
  # LANG only: a global LC_ALL overrides every per-category setting and is
  # meant for one-off debugging, not as a system default.
  sudo update-locale LANG="$LOCALE"
  export LANG="$LOCALE"
}

install_packages() {
  step "Updating system"
  sudo apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y -qq >/dev/null

  step "Installing core packages"
  apt_install_required git curl wget ca-certificates gnupg jq rsync
  apt_install \
    unzip zip lsb-release software-properties-common \
    bash-completion htop nano vim tmux screen \
    yq tree \
    net-tools iproute2 iputils-ping bind9-dnsutils \
    cron logrotate

  step "Installing build tools & dev libraries"
  apt_install \
    build-essential make cmake pkg-config autoconf automake libtool \
    python3 python3-pip python3-venv python3-dev \
    libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
    libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt1-dev

  step "Installing search, productivity & database tools"
  apt_install ripgrep fd-find fzf bat sqlite3 postgresql-client redis-tools
}

install_node() {
  step "Installing Node.js ${NODE_MAJOR}.x"
  local current=""
  have node && current=$(node --version | sed 's/^v//; s/\..*//')
  if [[ "$current" == "$NODE_MAJOR" ]]; then
    info "Node.js $(node --version) already installed."
  elif [[ -n "$current" && -z "$NODE_MAJOR_EXPLICIT" ]]; then
    info "Keeping existing Node.js $(node --version) (set NODE_MAJOR=${NODE_MAJOR} to switch)."
  else
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$WORK_DIR/nodesource.sh"
    sudo -E bash "$WORK_DIR/nodesource.sh" >/dev/null
    apt_install_required nodejs
  fi
  echo "    Node.js $(node --version) / npm $(npm --version)"

  # User-owned global prefix: `npm install -g` then works without sudo, which
  # claude-config-sync's npm-tools.sh (and Claude itself) rely on.
  if [[ ! -w "$(npm config get prefix)" ]]; then
    npm config set prefix "$HOME/.npm-global"
    info "npm global prefix set to ~/.npm-global (no sudo needed for npm -g)."
  fi
  PATH="$(npm config get prefix)/bin:$PATH"; export PATH

  step "Installing global npm packages"
  local pkgs=(typescript ts-node eslint prettier) missing=() p
  for p in "${pkgs[@]}"; do
    npm ls -g --depth=0 "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    npm install -g --no-fund --no-audit "${missing[@]}"
  else
    info "All present: ${pkgs[*]}"
  fi
}

install_go() {
  step "Installing Go"
  local go_arch
  case "$DPKG_ARCH" in
    amd64|arm64) go_arch="$DPKG_ARCH" ;;
    armhf)       go_arch="armv6l" ;;
    i386)        go_arch="386" ;;
    *) warn "No official Go build for $DPKG_ARCH — skipping Go."; return 0 ;;
  esac

  # go.dev's JSON index gives the latest stable release *and* its sha256, so
  # the tarball is verified rather than trusted blindly.
  local index version sha file current=""
  index=$(curl -fsSL "https://go.dev/dl/?mode=json")
  version=$(jq -r '.[0].version' <<<"$index")
  file=$(jq -r --arg a "$go_arch" '.[0].files[] | select(.os=="linux" and .arch==$a and .kind=="archive") | .filename' <<<"$index")
  sha=$(jq -r --arg a "$go_arch" '.[0].files[] | select(.os=="linux" and .arch==$a and .kind=="archive") | .sha256' <<<"$index")
  [[ -x /usr/local/go/bin/go ]] && current=$(/usr/local/go/bin/go version | awk '{print $3}')

  if [[ "$current" == "$version" ]]; then
    info "Go $version already installed."
  else
    [[ -n "$file" && -n "$sha" ]] || error "Could not find a Go $version download for linux/$go_arch."
    curl -fsSL "https://go.dev/dl/$file" -o "$WORK_DIR/$file"
    echo "$sha  $WORK_DIR/$file" | sha256sum -c --quiet - || error "Go tarball checksum mismatch — refusing to install."
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$WORK_DIR/$file"
    # shellcheck disable=SC2016 # expanded at login, not now
    echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh >/dev/null
  fi
  echo "    Go $(/usr/local/go/bin/go version | awk '{print $3}')"
}

install_rust() {
  step "Installing Rust (as your user)"
  local rustup_bin
  rustup_bin=$(command -v rustup || echo "$HOME/.cargo/bin/rustup")
  if [[ -x "$rustup_bin" ]]; then
    "$rustup_bin" update stable --no-self-update >/dev/null 2>&1 || warn "rustup update failed; keeping current toolchain."
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$WORK_DIR/rustup.sh"
    sh "$WORK_DIR/rustup.sh" -y -q
  fi
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  echo "    Rust $(rustc --version | awk '{print $2}')"
}

install_docker() {
  is_true "$INSTALL_DOCKER" || { info "Skipping Docker (declined)."; return 0; }
  step "Installing Docker"
  if have docker; then
    info "Docker already installed."
  else
    curl -fsSL https://get.docker.com -o "$WORK_DIR/get-docker.sh"
    sudo sh "$WORK_DIR/get-docker.sh" >/dev/null
    sudo systemctl enable --now docker || warn "Could not enable the docker service (no systemd?)."
  fi
  echo "    Docker $(sudo docker --version | awk '{print $3}' | tr -d ',')"
  echo "    Compose $(sudo docker compose version --short 2>/dev/null || echo 'missing')"

  getent group docker >/dev/null 2>&1 || sudo groupadd docker
  if id -nG "$USER" | grep -qw docker; then
    info "$USER is already in the docker group."
  else
    sudo usermod -aG docker "$USER"
    warn "Log out and back in (or run 'newgrp docker') before 'docker' works without sudo."
  fi
}

# ── Git / GitHub ───────────────────────────────────────────────────────────
setup_git() {
  step "Setting up Git identity"
  git config --global user.name "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
  # Defaults only — never override choices already made on this machine.
  local kv
  for kv in init.defaultBranch=main core.editor=nano pull.rebase=false; do
    git config --global --get "${kv%%=*}" >/dev/null || git config --global "${kv%%=*}" "${kv#*=}"
  done
}

setup_github() {
  is_true "$SETUP_GITHUB" || { info "Skipping GitHub CLI + SSH/auth setup (declined)."; return 0; }

  step "Installing GitHub CLI (gh)"
  if have gh; then
    info "gh already installed."
  else
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=${DPKG_ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    apt_install_required gh
  fi
  echo "    gh $(gh --version | head -1 | awk '{print $3}')"

  step "Setting up SSH key for GitHub"
  local key="$HOME/.ssh/id_ed25519"
  install -d -m 700 "$HOME/.ssh"
  if [[ -f "$key" ]]; then
    info "Reusing existing SSH key at $key."
  else
    ssh-keygen -q -t ed25519 -C "$GIT_EMAIL" -f "$key" -N ""
  fi
  # Pin github.com's host keys from its HTTPS API (authenticated by TLS)
  # rather than trusting whatever ssh-keyscan happens to be told.
  if ssh-keygen -F github.com >/dev/null 2>&1; then
    info "github.com host key already in known_hosts."
  elif curl -fsSL https://api.github.com/meta | jq -er '.ssh_keys[] | "github.com " + .' >> "$HOME/.ssh/known_hosts"; then
    info "Pinned github.com host keys from api.github.com/meta."
  else
    warn "Could not fetch GitHub's published host keys; falling back to ssh-keyscan."
    ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
  fi

  if gh auth status -h github.com >/dev/null 2>&1; then
    info "gh is already authenticated — skipping gh auth login."
  elif [[ -t 0 ]]; then
    step "Running 'gh auth login' (interactive — follow the browser/device-code prompts)"
    # -p ssh makes gh offer to upload the key generated above.
    gh auth login -h github.com -p ssh || warn "gh auth login did not complete; run it later with: gh auth login -p ssh"
  else
    warn "No terminal attached — skipping gh auth login. Run it later with: gh auth login -p ssh"
  fi

  if gh auth status -h github.com >/dev/null 2>&1; then
    gh auth setup-git >/dev/null 2>&1 || true
    # Make sure the key is actually registered (covers re-runs, and logins
    # where the upload prompt was skipped). Needs the public_key scopes, so
    # this is best-effort.
    local pub; pub=$(awk '{print $1" "$2}' "$key.pub")
    if gh api user/keys --jq '.[].key' 2>/dev/null | grep -qxF "$pub"; then
      info "SSH key is registered with GitHub."
    elif gh ssh-key add "$key.pub" --title "$(hostname) (claude-code-vm-setup)" >/dev/null 2>&1; then
      success "Uploaded SSH key to GitHub."
    else
      echo -e "${BOLD}Add this public key at https://github.com/settings/keys (or: gh auth refresh -s admin:public_key && gh ssh-key add $key.pub):${NC}"
      cat "$key.pub"
    fi
  fi
}

# ── Claude Code ────────────────────────────────────────────────────────────
install_claude_code() {
  step "Installing Claude Code"
  # The native installer puts claude in ~/.local/bin, which a fresh VM's
  # shell may not have on PATH yet — without this, re-runs reinstall it.
  export PATH="$HOME/.local/bin:$PATH"
  local existing=""
  have claude && existing=$(readlink -f "$(command -v claude)")

  # Don't stack a second install on top of one made by the other method —
  # whichever comes first on PATH would silently shadow the other.
  if [[ -n "$existing" ]] && ! dpkg -S "$existing" >/dev/null 2>&1; then
    info "Claude Code is already installed natively ($existing); it self-updates, so apt is skipped."
    CLAUDE_INSTALL_METHOD="native"
  elif [[ -z "$existing" && "$CLAUDE_INSTALL_METHOD" == "native" ]]; then
    curl -fsSL https://claude.ai/install.sh -o "$WORK_DIR/claude-install.sh"
    bash "$WORK_DIR/claude-install.sh"
  else
    CLAUDE_INSTALL_METHOD="apt"
    # Anthropic's signed apt repo: same binary as the native installer, but
    # updated by apt (including the weekly cron below) instead of in-process.
    local keyring="/etc/apt/keyrings/claude-code.asc" fpr
    sudo install -d -m 0755 /etc/apt/keyrings
    sudo curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o "$keyring"
    fpr=$(gpg --show-keys --with-colons "$keyring" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')
    if [[ "$fpr" != "$CLAUDE_APT_KEY_FPR" ]]; then
      sudo rm -f "$keyring"
      error "Claude Code apt signing key fingerprint mismatch (got: ${fpr:-none}, expected $CLAUDE_APT_KEY_FPR) - refusing to trust it. See https://code.claude.com/docs/en/setup#install-with-linux-package-managers"
    fi
    echo "deb [signed-by=${keyring}] https://downloads.claude.ai/claude-code/apt/stable stable main" \
      | sudo tee /etc/apt/sources.list.d/claude-code.list >/dev/null
    sudo apt-get update -qq
    apt_install_required claude-code
  fi
  echo "    Claude Code $(claude --version 2>/dev/null || echo 'installed')"
}

# Option a) claude-config-sync owns ~/.claude — clone the user's sync repo and
# hand over to its install.sh (bootstrap on first run, sync afterwards). It
# also provisions gh and its companion npm tools.
setup_config_sync() {
  step "Applying Claude Code config from claude-config-sync"
  if [[ ! -d "$CLAUDE_SYNC_REPO_DIR/.git" ]]; then
    git clone -q "$CLAUDE_SYNC_REPO_URL" "$CLAUDE_SYNC_REPO_DIR" || {
      warn "Could not clone $CLAUDE_SYNC_REPO_URL — check the URL and that this VM has access (SSH key registered / gh authenticated)."
      SYNC_FAILED=true; return 0
    }
  fi
  if [[ ! -x "$CLAUDE_SYNC_REPO_DIR/install.sh" ]]; then
    warn "$CLAUDE_SYNC_REPO_DIR has no install.sh — is it a claude-config-sync repo?"
    SYNC_FAILED=true; return 0
  fi
  export CLAUDE_SYNC_REPO_URL CLAUDE_SYNC_REPO_DIR CLAUDE_SYNC_PROJECT_PATH="$PROJECT_DIR"
  if "$CLAUDE_SYNC_REPO_DIR/install.sh"; then
    success "Config synced from $CLAUDE_SYNC_REPO_URL."
  else
    warn "claude-config-sync install failed. Fix it, then run: $CLAUDE_SYNC_REPO_DIR/install.sh (or claude-sync.sh doctor)"
    SYNC_FAILED=true
  fi
}

# Option b) no sync repo — merge a baseline into ~/.claude/settings.json.
# Existing keys win, so re-runs never undo changes made since.
setup_local_config() {
  step "Configuring Claude Code settings (local)"
  local settings="$HOME/.claude/settings.json" plugins='{}' markets='{}' tmp
  mkdir -p "$HOME/.claude"

  if is_true "$INSTALL_PLUGINS"; then
    # claude-plugins-official is built in; third-party marketplaces must be
    # declared. No github plugin: gh CLI covers the same ground without the
    # MCP server's separate token setup.
    plugins='{
      "frontend-design@claude-plugins-official": true,
      "code-review@claude-plugins-official": true,
      "commit-commands@claude-plugins-official": true,
      "security-guidance@claude-plugins-official": true,
      "context7@claude-plugins-official": true,
      "superpowers@superpowers-marketplace": true,
      "deployment-engineer@awesome-claude-code-plugins": true
    }'
    is_true "$INSTALL_DOCKER" && plugins=$(jq '. + {"docker@claude-plugins-official": true}' <<<"$plugins")
    markets='{
      "superpowers-marketplace":     { "source": { "source": "github", "repo": "obra/superpowers-marketplace" } },
      "awesome-claude-code-plugins": { "source": { "source": "github", "repo": "ccplugins/awesome-claude-code-plugins" } }
    }'
  fi

  if [[ -f "$settings" ]] && ! jq -e . "$settings" >/dev/null 2>&1; then
    warn "$settings is not valid JSON — moving it to $settings.invalid and starting fresh."
    mv "$settings" "$settings.invalid"
  fi
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  tmp=$(mktemp -p "$WORK_DIR")
  jq --argjson plugins "$plugins" --argjson markets "$markets" '
    {"$schema": "https://json.schemastore.org/claude-code-settings.json"} + .
    | .permissions.allow = ((.permissions.allow // []) + [
        "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)",
        "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)",
        "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"
      ] | unique)
    | if $plugins == {} then . else
        .enabledPlugins = ($plugins + (.enabledPlugins // {}))
        | .extraKnownMarketplaces = ($markets + (.extraKnownMarketplaces // {}))
      end
  ' "$settings" > "$tmp"

  if cmp -s "$tmp" "$settings"; then
    info "settings.json already up to date."
  else
    cp "$settings" "$settings.bak"
    cat "$tmp" > "$settings"
    success "Updated $settings (previous version at settings.json.bak)."
  fi
}

enable_remote_control() {
  step "Enabling Claude Code Remote Control auto-start"
  # remoteControlAtStartup in ~/.claude.json is the /config toggle "Enable
  # Remote Control for all sessions". Requires a Pro/Max login (claude, then
  # /login) — API keys are NOT supported for Remote Control.
  local cfg="$HOME/.claude.json" tmp
  [[ -f "$cfg" ]] || echo '{}' > "$cfg"
  if ! jq -e . "$cfg" >/dev/null 2>&1; then
    warn "$cfg isn't valid JSON — not touching it (it holds login state). Enable Remote Control via /config instead."
    return 0
  fi
  tmp=$(mktemp -p "$WORK_DIR")
  jq '.remoteControlAtStartup = true' "$cfg" > "$tmp" && cat "$tmp" > "$cfg"
}

install_webapp_testing() {
  is_true "$INSTALL_WEBAPP_TESTING" || { info "Skipping webapp-testing skill + Playwright (declined)."; return 0; }

  step "Installing webapp-testing skill (from anthropics/skills)"
  local dest="$HOME/.claude/skills/webapp-testing" src="$WORK_DIR/anthropic-skills"
  if [[ -L "$dest" ]]; then
    info "$dest is a symlink (managed elsewhere, e.g. claude-config-sync) — leaving it alone."
  else
    git clone -q --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git "$src"
    git -C "$src" sparse-checkout set skills/webapp-testing
    mkdir -p "$dest"
    rsync -a --delete "$src/skills/webapp-testing/" "$dest/"
  fi

  # The skill drives Playwright from Python scripts, so it needs the Python
  # package — the npm one alone leaves it broken.
  step "Installing Playwright (Python) + Chromium"
  python3 -m pip install --user --break-system-packages --quiet --upgrade playwright
  python3 -m playwright install --with-deps chromium
}

# ── Workspace ──────────────────────────────────────────────────────────────
write_project_claude_md() {
  step "Writing $PROJECT_DIR/CLAUDE.md"
  mkdir -p "$PROJECT_DIR"
  local file="$PROJECT_DIR/CLAUDE.md"
  local begin="<!-- >>> claude-code-vm-setup (generated; edits inside this block are overwritten on re-run) >>> -->"
  local end="<!-- <<< claude-code-vm-setup <<< -->"

  # CLAUDE.md written by older versions of this script had no markers; back
  # it up and replace it rather than appending a second copy.
  if [[ -f "$file" ]] && ! grep -qF "$end" "$file" && head -1 "$file" | grep -q '^# Claude Code Workspace'; then
    mv "$file" "$file.bak"
    info "Replaced pre-marker CLAUDE.md (old copy at CLAUDE.md.bak)."
  fi

  local body sections="" docker_plugin=""
  is_true "$INSTALL_DOCKER" && docker_plugin=", docker"
  if is_true "$INSTALL_DOCKER"; then
    sections+="
## Docker
Docker Engine + Compose plugin are installed (\`$USER\` is in the \`docker\` group); no containers
are deployed by default."
  fi
  if is_true "$SETUP_GITHUB"; then
    sections+="
## GitHub Access
- **gh CLI** is installed and authenticated via \`gh auth login\` (verify: \`gh auth status\`).
  Prefer \`gh\` for issues/PRs/Actions.
- **SSH key**: ~/.ssh/id_ed25519 (verify: \`ssh -T git@github.com\`)."
  fi
  if $USE_SYNC; then
    sections+="
## Claude Code Config
Global config (~/.claude/CLAUDE.md, settings.json, hooks, skills, plugins, memory) is managed by
claude-config-sync from \`$CLAUDE_SYNC_REPO_URL\` (clone: $CLAUDE_SYNC_REPO_DIR) and synced on
session start/end. Change it there, not by hand-editing ~/.claude."
  elif is_true "$INSTALL_PLUGINS"; then
    sections+="
## Plugins
Declared in ~/.claude/settings.json and installed on first launch (check with /plugin):
frontend-design, code-review, commit-commands, security-guidance, context7, superpowers,
deployment-engineer${docker_plugin}."
  fi
  if is_true "$INSTALL_WEBAPP_TESTING"; then
    sections+="
## Skills
- **webapp-testing** (~/.claude/skills/): Python Playwright browser testing for UI verification."
  fi

  body="# Claude Code Workspace

## Environment
- **OS**: ${PRETTY_NAME:-Ubuntu} VM ($DPKG_ARCH)
- **Working directory**: $PROJECT_DIR
- **User**: $USER (sudo-capable, not root)
- **Locale**: $LOCALE

## Available Tools
- **Languages**: Node.js $(ver 1 node --version), Python $(ver 2 python3 --version), Go $(ver 3 /usr/local/go/bin/go version), Rust $(ver 2 rustc --version)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3
${sections}

## Remote Control
Auto-start is on (remoteControlAtStartup in ~/.claude.json). Needs a Pro/Max login. Run
\`claude\` in $PROJECT_DIR (or \`claude remote-control\` for multi-session server mode), then pick
this machine's session in Claude Desktop or claude.ai/code. Outbound HTTPS only; the local
\`claude\` process must stay running.

## Conventions
- Use git for version control on all projects in $PROJECT_DIR/
- When installing Python packages, use: pip install --break-system-packages <package>"

  write_managed_block "$file" "$begin" "$end" "$body"
}

setup_shell() {
  step "Setting up shell environment (bash + zsh if present)"
  local begin="# >>> claude-code-vm-setup >>>" end="# <<< claude-code-vm-setup <<<" block rc tmp
  # Quoted heredoc: $HOME, $PATH etc. stay literal and expand when the rc file
  # is sourced; @PLACEHOLDERS@ are filled in below.
  block=$(cat <<'RCBLOCK'
export EDITOR=nano
export LANG=@LOCALE@
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
@DOCKER_ALIASES@
# Land in the project dir for new interactive shells that start in $HOME,
# without hijacking terminals opened elsewhere (IDEs, tmux splits, scripts).
case $- in *i*) [ "$PWD" = "$HOME" ] && cd "@PROJECT_DIR@" 2>/dev/null ;; esac
true
RCBLOCK
)
  block=${block//@LOCALE@/$LOCALE}
  block=${block//@PROJECT_DIR@/$PROJECT_DIR}
  local docker_aliases=""
  if is_true "$INSTALL_DOCKER"; then
    docker_aliases='alias dc="docker compose"'$'\n'"alias dps=\"docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'\""
  fi
  block=${block//@DOCKER_ALIASES@/$docker_aliases}

  local rc_files=("$HOME/.bashrc")
  have zsh && rc_files+=("$HOME/.zshrc")
  for rc in "${rc_files[@]}"; do
    touch "$rc"
    # Migrate the unmarked block written by older versions of this script.
    # shellcheck disable=SC2016 # matching a literal $HOME
    if grep -q '^# ── Claude Code Environment' "$rc" && grep -q 'cd "\$HOME/project" 2>/dev/null || true$' "$rc"; then
      tmp=$(mktemp -p "$WORK_DIR")
      awk '/^# ── Claude Code Environment/{skip=1} !skip{print} skip && /cd "\$HOME\/project" 2>\/dev\/null \|\| true$/{skip=0}' "$rc" > "$tmp"
      cat "$tmp" > "$rc"
      info "Migrated old Claude Code block in $(basename "$rc")."
    fi
    write_managed_block "$rc" "$begin" "$end" "$block"
    info "Updated Claude Code block in $(basename "$rc")."
  done
}

setup_auto_update() {
  is_true "$AUTO_UPDATE" || { info "Skipping weekly auto-update cron (declined)."; return 0; }
  step "Setting up weekly auto-update cron"
  # Braces so the log captures every command, not just the last one; confold
  # keeps local config files so an upgrade can never block on a prompt.
  sudo tee /etc/cron.d/system-update >/dev/null <<'CRON'
# Weekly system update - Sunday 03:00 (system local time). Managed by claude-code-vm-setup.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root { date; export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq; } >> /var/log/auto-update.log 2>&1
CRON
  sudo chmod 0644 /etc/cron.d/system-update

  sudo tee /etc/logrotate.d/auto-update >/dev/null <<'LOGROTATE'
/var/log/auto-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE
}

final_cleanup() {
  step "Cleaning up"
  sudo apt-get autoremove -y -qq >/dev/null
  sudo apt-get clean -qq
}

# ── Summary ────────────────────────────────────────────────────────────────
print_summary() {
  local n=1
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║               Claude Code VM Ready!              ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}User:${NC}         $USER (sudo-capable)"
  echo -e "  ${BOLD}Project dir:${NC}  $PROJECT_DIR"
  echo -e "  ${BOLD}Claude Code:${NC}  $(claude --version 2>/dev/null || echo '?') via $CLAUDE_INSTALL_METHOD"
  if $USE_SYNC; then
    if [[ "${SYNC_FAILED:-false}" == "true" ]]; then
      echo -e "  ${BOLD}Config:${NC}       ${YELLOW}claude-config-sync FAILED${NC} — see warnings above"
    else
      echo -e "  ${BOLD}Config:${NC}       claude-config-sync ← $CLAUDE_SYNC_REPO_URL"
    fi
  else
    echo -e "  ${BOLD}Config:${NC}       local ~/.claude/settings.json (plugins: $(is_true "$INSTALL_PLUGINS" && echo bundle || echo none))"
  fi
  echo -e "  ${BOLD}Locale:${NC}       $LOCALE"
  is_true "$AUTO_UPDATE" && echo -e "  ${BOLD}Auto-updates:${NC} apt upgrade every Sunday 03:00 (log: /var/log/auto-update.log)"
  echo ""
  echo -e "  ${BOLD}Next steps:${NC}"
  if is_true "$INSTALL_DOCKER" && ! id -nG | grep -qw docker; then
    echo -e "    $((n++)). Log out and back in (or ${CYAN}newgrp docker${NC}) so the docker group applies"
  fi
  echo -e "    $((n++)). Open a new shell (or ${CYAN}source ~/.bashrc${NC})"
  if is_true "$SETUP_GITHUB"; then
    echo -e "    $((n++)). ${CYAN}gh auth status${NC} / ${CYAN}ssh -T git@github.com${NC} — confirm GitHub access"
  fi
  if [[ "${SYNC_FAILED:-false}" == "true" ]]; then
    echo -e "    $((n++)). Re-run ${CYAN}$0 --sync-repo $CLAUDE_SYNC_REPO_URL${NC} once the cause is fixed"
  fi
  echo -e "    $((n++)). ${CYAN}cd $PROJECT_DIR && claude${NC}, then ${CYAN}/login${NC} (Pro/Max needed for Remote Control)"
  echo -e "    $((n++)). In Claude Desktop / claude.ai/code, pick this VM's session to drive it remotely"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  header
  preflight
  gather_config

  export DEBIAN_FRONTEND=noninteractive
  setup_locale
  install_packages
  install_node
  install_go
  install_rust
  install_docker
  setup_git
  setup_github
  install_claude_code
  SYNC_FAILED=false
  if $USE_SYNC; then setup_config_sync; else setup_local_config; fi
  enable_remote_control
  install_webapp_testing
  write_project_claude_md
  setup_shell
  setup_auto_update
  final_cleanup
  print_summary
}

main "$@"
