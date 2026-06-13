#!/usr/bin/env bash
# =============================================================================
# CachyOS Dev Environment Checker
# Scans your system against the dev-ready guide, then offers to install missing
# items. Run with: bash cachyos-dev-check.sh
# =============================================================================

# No set -e — checks intentionally test for missing tools (non-zero exits).
# We handle errors explicitly throughout.

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── State ─────────────────────────────────────────────────────────────────────
MISSING_PACMAN=()
MISSING_PARU=()
MISSING_MANUAL=()
PASS=0
FAIL=0

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()      { echo -e "  ${GREEN}✔${RESET}  $1"; PASS=$(( PASS + 1 )); }
fail()    { echo -e "  ${RED}✘${RESET}  $1${DIM} — missing${RESET}"; FAIL=$(( FAIL + 1 )); }
warn()    { echo -e "  ${YELLOW}~${RESET}  $1"; }
section() { echo -e "\n${BOLD}${BLUE}▸ $1${RESET}"; }
note()    { echo -e "    ${DIM}$1${RESET}"; }

has()           { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { pacman -Qi "$1" >/dev/null 2>&1; }
need_pacman()   { MISSING_PACMAN+=("$1"); }
need_paru()     { MISSING_PARU+=("$1"); }
need_manual()   { MISSING_MANUAL+=("$1"); }

# ── Section: System Foundation ────────────────────────────────────────────────
section "System Foundation"

if pkg_installed base-devel; then
  ok "base-devel group"
else
  fail "base-devel group"
  need_pacman "base-devel"
fi

for tool in git curl wget unzip zip; do
  if has "$tool"; then
    ok "$tool"
  else
    fail "$tool"
    need_pacman "$tool"
  fi
done

# xclip — used to copy SSH public key to clipboard
if has xclip; then
  ok "xclip"
else
  fail "xclip"
  need_pacman "xclip"
fi

# openssh binary is 'ssh', not 'openssh'
if has ssh; then
  ok "openssh (ssh)"
else
  fail "openssh"
  need_pacman "openssh"
fi

if has paru; then
  ok "paru (AUR helper)"
else
  fail "paru (AUR helper)"
  need_manual "paru: git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si"
fi

# SSH key
if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
  ok "SSH key (ed25519)"
elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
  warn "SSH key found but it's RSA — consider regenerating as ed25519"
else
  fail "SSH key (none found)"
  note "Generate: ssh-keygen -t ed25519 -C \"you@example.com\""
  need_manual "SSH key: ssh-keygen -t ed25519 -C \"you@email.com\""
fi

# git global config — name + email
GIT_NAME=$(git config --global user.name 2>/dev/null || true)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
  ok "git global config ($GIT_NAME <$GIT_EMAIL>)"
else
  fail "git global config (name or email missing)"
  note "Fix: git config --global user.name \"Name\" && git config --global user.email \"you@example.com\""
  need_manual "git config: git config --global user.name \"Your Name\" && git config --global user.email \"you@email.com\""
fi

# git editor
GIT_EDITOR=$(git config --global core.editor 2>/dev/null || true)
if [[ -n "$GIT_EDITOR" ]]; then
  ok "git core.editor: $GIT_EDITOR"
else
  warn "git core.editor not set"
  note "Fix: git config --global core.editor nvim  (or code --wait, nano, etc.)"
fi

# git pull strategy
GIT_PULL=$(git config --global pull.rebase 2>/dev/null || true)
if [[ -n "$GIT_PULL" ]]; then
  ok "git pull.rebase: $GIT_PULL"
else
  warn "git pull.rebase not set (implicit default — can cause unexpected merges)"
  note "Fix: git config --global pull.rebase false"
fi

# git default branch
GIT_BRANCH=$(git config --global init.defaultBranch 2>/dev/null || true)
if [[ -n "$GIT_BRANCH" ]]; then
  ok "git init.defaultBranch: $GIT_BRANCH"
else
  warn "git init.defaultBranch not set (defaults to 'master')"
  note "Fix: git config --global init.defaultBranch main"
fi

# ── Section: Shell ─────────────────────────────────────────────────────────────
section "Shell Environment"

CURRENT_SHELL=$(basename "$SHELL")
case "$CURRENT_SHELL" in
  zsh|fish) ok "Shell: $CURRENT_SHELL" ;;
  bash)     warn "Shell: bash — consider switching to zsh or fish" ;;
  *)        warn "Shell: $CURRENT_SHELL" ;;
esac

# Check starship binary and whether it's wired into shell config
if has starship; then
  ok "starship (binary)"
  # Check shell rc for starship init
  STARSHIP_INIT=false
  case "$CURRENT_SHELL" in
    zsh)
      if grep -q "starship init" "$HOME/.zshrc" 2>/dev/null; then
        STARSHIP_INIT=true
      fi
      ;;
    fish)
      if grep -rq "starship init" "$HOME/.config/fish/" 2>/dev/null; then
        STARSHIP_INIT=true
      fi
      ;;
    bash)
      if grep -q "starship init" "$HOME/.bashrc" 2>/dev/null; then
        STARSHIP_INIT=true
      fi
      ;;
  esac
  if [ "$STARSHIP_INIT" = true ]; then
    ok "starship wired into shell config"
  else
    warn "starship installed but not initialized in shell config"
    note "Add to your shell rc: eval \"\$(starship init $CURRENT_SHELL)\""
  fi
else
  fail "starship"
  need_pacman "starship"
fi

for tool in eza bat fzf zoxide htop; do
  if has "$tool"; then
    ok "$tool"
  else
    fail "$tool"
    need_pacman "$tool"
  fi
done

# Check zoxide wired into shell
if has zoxide; then
  ZOXIDE_INIT=false
  case "$CURRENT_SHELL" in
    zsh)  grep -q "zoxide init" "$HOME/.zshrc" 2>/dev/null && ZOXIDE_INIT=true ;;
    fish) grep -rq "zoxide init" "$HOME/.config/fish/" 2>/dev/null && ZOXIDE_INIT=true ;;
    bash) grep -q "zoxide init" "$HOME/.bashrc" 2>/dev/null && ZOXIDE_INIT=true ;;
  esac
  if [ "$ZOXIDE_INIT" = true ]; then
    ok "zoxide wired into shell config"
  else
    warn "zoxide installed but not initialized in shell config"
    note "Add to your shell rc: eval \"\$(zoxide init $CURRENT_SHELL)\""
  fi
fi

# ripgrep binary is 'rg', package is 'ripgrep'
if has rg; then
  ok "ripgrep (rg)"
else
  fail "ripgrep (rg)"
  need_pacman "ripgrep"
fi

# fd
if has fd; then
  ok "fd"
else
  fail "fd"
  need_pacman "fd"
fi

if has tmux && has zellij; then
  ok "tmux"
  ok "zellij"
elif has tmux; then
  ok "tmux"
  warn "zellij not installed (optional)"
elif has zellij; then
  ok "zellij"
  warn "tmux not installed (optional)"
else
  fail "terminal multiplexer (neither tmux nor zellij)"
  need_pacman "tmux"
fi

# ── Section: Languages ─────────────────────────────────────────────────────────
section "Languages & Runtimes"

# fnm
if has fnm; then
  ok "fnm (Node version manager)"
  # Check fnm wired into shell
  FNM_INIT=false
  case "$CURRENT_SHELL" in
    zsh)  grep -q "fnm env" "$HOME/.zshrc" 2>/dev/null && FNM_INIT=true ;;
    fish) grep -rq "fnm env" "$HOME/.config/fish/" 2>/dev/null && FNM_INIT=true ;;
    bash) grep -q "fnm env" "$HOME/.bashrc" 2>/dev/null && FNM_INIT=true ;;
  esac
  if [ "$FNM_INIT" = true ]; then
    ok "fnm wired into shell config"
  else
    warn "fnm installed but not initialized in shell config"
    note "Add to your shell rc: eval \"\$(fnm env --use-on-cd)\""
  fi
else
  fail "fnm"
  need_pacman "fnm"
fi

# Node
if has node; then
  NODE_VER=$(node --version 2>/dev/null || true)
  ok "Node.js $NODE_VER"
else
  if has fnm; then
    warn "Node.js not in PATH — fnm present but no version active"
    note "Run: fnm install --lts && fnm use lts-latest && fnm default lts-latest"
  else
    fail "Node.js"
    need_manual "Node.js: fnm install --lts && fnm use lts-latest && fnm default lts-latest"
  fi
fi

if has pnpm; then
  ok "pnpm"
else
  fail "pnpm"
  note "Install after Node: npm install -g pnpm"
  need_manual "pnpm: npm install -g pnpm"
fi

# pyenv
if has pyenv; then
  ok "pyenv"
else
  fail "pyenv"
  need_paru "pyenv"
fi

# Python
if has python3 || has python; then
  PY_VER=$(python3 --version 2>/dev/null || python --version 2>/dev/null || true)
  if has pyenv; then
    ok "Python $PY_VER (via pyenv)"
  else
    warn "Python found ($PY_VER) but not managed by pyenv"
  fi
else
  fail "Python"
  note "After pyenv: pyenv install 3.12 && pyenv global 3.12"
  need_manual "Python: pyenv install 3.12 && pyenv global 3.12"
fi

if has uv; then
  ok "uv (Python toolchain)"
else
  fail "uv"
  note "Install after Python: pip install uv"
  need_manual "uv: pip install uv"
fi

# Rust / rustup
if has rustup; then
  ok "rustup"
else
  fail "rustup"
  need_pacman "rustup"
  need_manual "After rustup install: rustup default stable"
fi

if has rustc; then
  RUST_VER=$(rustc --version 2>/dev/null | awk '{print $2}' || true)
  ok "Rust $RUST_VER"

  # Rust components — only checkable if rustup is present
  if has rustup; then
    INSTALLED_COMPONENTS=$(rustup component list --installed 2>/dev/null || true)
    for component in rust-analyzer clippy rustfmt; do
      if echo "$INSTALLED_COMPONENTS" | grep -q "^${component}"; then
        ok "rustup component: $component"
      else
        fail "rustup component: $component"
        need_manual "rustup component add $component"
      fi
    done
  fi
else
  if has rustup; then
    warn "rustup installed but no toolchain — run: rustup default stable"
  else
    fail "Rust (rustc)"
  fi
fi

# Go
if has go; then
  GO_VER=$(go version 2>/dev/null | awk '{print $3}' || true)
  ok "Go $GO_VER"
  # Check GOPATH/bin in PATH
  GOPATH_BIN="${GOPATH:-$HOME/go}/bin"
  if echo "$PATH" | grep -q "$GOPATH_BIN"; then
    ok "GOPATH/bin in PATH ($GOPATH_BIN)"
  else
    warn "GOPATH/bin not in PATH — Go-installed binaries won't be found"
    note "Add to shell rc: export GOPATH=\"\$HOME/go\" && export PATH=\"\$PATH:\$GOPATH/bin\""
  fi
else
  fail "Go"
  need_pacman "go"
fi

# Java
if has java; then
  JAVA_VER=$(java -version 2>&1 | head -1 || true)
  ok "Java ($JAVA_VER)"
else
  warn "Java not installed (optional — skip if not doing JVM work)"
  note "Install via SDKMAN: curl -s https://get.sdkman.io | bash, then: sdk install java 21-tem"
fi

if [[ -d "$HOME/.sdkman" ]]; then
  ok "SDKMAN"
else
  warn "SDKMAN not found (optional)"
fi

# ── Section: Dev Tools ─────────────────────────────────────────────────────────
section "Developer Tools"

if has gh; then
  ok "GitHub CLI (gh)"
  # Check if authenticated
  GH_AUTH=$(gh auth status 2>&1 || true)
  if echo "$GH_AUTH" | grep -q "Logged in"; then
    ok "GitHub CLI authenticated"
  else
    warn "GitHub CLI installed but not authenticated"
    note "Run: gh auth login"
  fi
else
  fail "GitHub CLI (gh)"
  need_pacman "github-cli"
fi

# Database CLI clients
for tool in pgcli mycli; do
  if has "$tool"; then
    ok "$tool"
  else
    fail "$tool"
    need_paru "$tool"
  fi
done

# Database libs
for pkg in sqlite postgresql-libs; do
  if pkg_installed "$pkg"; then
    ok "$pkg"
  else
    fail "$pkg"
    need_pacman "$pkg"
  fi
done

# DBeaver — binary is 'dbeaver'
if has dbeaver; then
  ok "DBeaver (GUI DB client)"
else
  warn "DBeaver not installed (optional GUI)"
  note "Install: paru -S dbeaver"
fi

# httpie binary is 'http' on Arch
if has http || has httpie; then
  ok "httpie"
else
  fail "httpie"
  need_pacman "httpie"
fi

if has xh; then
  ok "xh (fast http client)"
else
  fail "xh"
  need_paru "xh"
fi

# Hoppscotch — binary may be 'hoppscotch'
if has hoppscotch || pkg_installed "hoppscotch-bin"; then
  ok "Hoppscotch (API client)"
else
  warn "Hoppscotch not installed (optional GUI API client)"
  note "Install: paru -S hoppscotch-bin"
fi

if has just; then
  ok "just (task runner)"
else
  fail "just"
  need_pacman "just"
fi

if has terraform; then
  ok "terraform"
else
  warn "terraform not installed (skip if not using IaC)"
fi

for cli in aws gcloud az; do
  if has "$cli"; then
    ok "Cloud CLI: $cli"
  fi
done

# ── Section: Containers & VMs ──────────────────────────────────────────────────
section "Containers & VMs"

if has docker; then
  DOCKER_VER=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)
  ok "Docker $DOCKER_VER"

  USER_GROUPS=$(groups "$USER" 2>/dev/null || true)
  if echo "$USER_GROUPS" | grep -q '\bdocker\b'; then
    ok "User in docker group"
  else
    warn "User not in docker group — every docker command needs sudo"
    note "Fix: sudo usermod -aG docker \$USER  (then log out and back in)"
  fi

  if has docker-compose; then
    ok "docker-compose (standalone)"
  elif docker compose version >/dev/null 2>&1; then
    ok "docker compose (plugin)"
  else
    fail "docker-compose"
    need_pacman "docker-compose"
  fi

  if systemctl is-active docker >/dev/null 2>&1; then
    ok "Docker service: running"
  else
    warn "Docker service not running"
    note "Fix: sudo systemctl enable --now docker"
  fi
else
  fail "Docker"
  need_pacman "docker"
  need_pacman "docker-compose"
fi

if has podman; then
  ok "podman (rootless)"
else
  warn "podman not installed (optional)"
fi

if has lazydocker; then
  ok "lazydocker"
else
  warn "lazydocker not installed (optional TUI)"
  need_paru "lazydocker"
fi

# QEMU / KVM stack
if has qemu-system-x86_64 || pkg_installed "qemu-full"; then
  ok "QEMU"
else
  warn "QEMU not installed (optional — needed for VMs)"
  note "Install: sudo pacman -S qemu-full virt-manager libvirt dnsmasq"
fi

if has virt-manager; then
  ok "virt-manager"
else
  warn "virt-manager not installed (optional)"
fi

if pkg_installed libvirt; then
  ok "libvirt"
  if systemctl is-active libvirtd >/dev/null 2>&1; then
    ok "libvirtd service: running"
  else
    warn "libvirtd not running"
    note "Fix: sudo systemctl enable --now libvirtd"
  fi
  # Check libvirt group
  USER_GROUPS=$(groups "$USER" 2>/dev/null || true)
  if echo "$USER_GROUPS" | grep -q '\blibvirt\b'; then
    ok "User in libvirt group"
  else
    warn "User not in libvirt group"
    note "Fix: sudo usermod -aG libvirt \$USER"
  fi
else
  warn "libvirt not installed (optional)"
fi

# ── Section: Editor & Fonts ────────────────────────────────────────────────────
section "Editor & Fonts"

if has code || has codium; then
  ok "VS Code / VSCodium"
else
  warn "VS Code not found"
  note "Install: sudo pacman -S code  OR  paru -S visual-studio-code-bin"
fi

if has nvim; then
  NVIM_VER=$(nvim --version 2>/dev/null | head -1 | awk '{print $2}' || true)
  ok "Neovim $NVIM_VER"
else
  warn "Neovim not installed (optional)"
fi

if has jetbrains-toolbox || pkg_installed "jetbrains-toolbox"; then
  ok "JetBrains Toolbox"
else
  warn "JetBrains Toolbox not installed (optional)"
  note "Install: paru -S jetbrains-toolbox"
fi

# Nerd Fonts
NERD_FONT=$(fc-list 2>/dev/null | grep -i "nerd" || true)
if [[ -n "$NERD_FONT" ]]; then
  ok "Nerd Font detected"
else
  warn "No Nerd Font found — icons in Starship/eza will show as boxes"
  note "Install: paru -S ttf-jetbrains-mono-nerd"
  need_paru "ttf-jetbrains-mono-nerd"
fi

# ── Section: Dotfiles ──────────────────────────────────────────────────────────
section "Dotfiles Management"

if has chezmoi; then
  ok "chezmoi"
elif has stow; then
  ok "stow"
elif [[ -d "$HOME/.dotfiles" ]]; then
  ok "dotfiles repo (~/.dotfiles bare repo)"
else
  warn "No dotfiles manager detected (chezmoi, stow, or bare git repo)"
  note "Recommended: paru -S chezmoi  OR  sudo pacman -S stow"
fi

# ── Section: System Configuration ─────────────────────────────────────────────
section "System Configuration"

INOTIFY=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo "0")
if [ "$INOTIFY" -ge 524288 ] 2>/dev/null; then
  ok "inotify max_user_watches: $INOTIFY"
else
  warn "inotify max_user_watches: $INOTIFY (low — large JS/TS projects may silently break)"
  note "Fix: echo fs.inotify.max_user_watches=524288 | sudo tee /etc/sysctl.d/40-inotify.conf && sudo sysctl --system"
fi

if systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
  ok "SSD TRIM timer enabled"
else
  warn "fstrim.timer not enabled"
  note "Fix: sudo systemctl enable fstrim.timer"
fi

SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
if [ "$SWAPPINESS" -le 10 ] 2>/dev/null; then
  ok "vm.swappiness: $SWAPPINESS (tuned for dev)"
else
  warn "vm.swappiness: $SWAPPINESS (consider lowering to 10)"
  note "Fix: echo vm.swappiness=10 | sudo tee /etc/sysctl.d/99-swappiness.conf"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${GREEN}✔ Installed:${RESET}  $PASS items"
echo -e "  ${RED}✘ Missing:${RESET}    $FAIL items"

TOTAL_AUTO=$(( ${#MISSING_PACMAN[@]} + ${#MISSING_PARU[@]} ))

if [ "$TOTAL_AUTO" -eq 0 ] && [ "${#MISSING_MANUAL[@]}" -eq 0 ]; then
  echo -e "\n  ${GREEN}${BOLD}Your machine looks dev-ready.${RESET}\n"
  exit 0
fi

echo ""

if [ "${#MISSING_PACMAN[@]}" -gt 0 ]; then
  echo -e "  ${BOLD}Installable via pacman:${RESET}"
  for p in "${MISSING_PACMAN[@]}"; do
    echo -e "    ${CYAN}·${RESET} $p"
  done
fi

if [ "${#MISSING_PARU[@]}" -gt 0 ]; then
  echo -e "  ${BOLD}Installable via paru (AUR):${RESET}"
  for p in "${MISSING_PARU[@]}"; do
    echo -e "    ${CYAN}·${RESET} $p"
  done
fi

if [ "${#MISSING_MANUAL[@]}" -gt 0 ]; then
  echo -e "  ${BOLD}Require manual steps:${RESET}"
  for p in "${MISSING_MANUAL[@]}"; do
    echo -e "    ${YELLOW}·${RESET} $p"
  done
fi

# ── Install Prompt ─────────────────────────────────────────────────────────────
echo ""

if [ "$TOTAL_AUTO" -gt 0 ]; then
  echo -e "${BOLD}Install options:${RESET}"
  echo -e "  ${CYAN}[a]${RESET} Install all auto-installable packages now"
  echo -e "  ${CYAN}[p]${RESET} pacman packages only"
  echo -e "  ${CYAN}[u]${RESET} AUR (paru) packages only"
  echo -e "  ${CYAN}[n]${RESET} Skip — just print the commands"
  echo ""
  read -rp "  Choice [a/p/u/n]: " CHOICE

  CHOICE=$(echo "$CHOICE" | tr '[:upper:]' '[:lower:]')

  case "$CHOICE" in
    a)
      if [ "${#MISSING_PACMAN[@]}" -gt 0 ]; then
        echo -e "\n${BOLD}Installing via pacman...${RESET}"
        sudo pacman -S --needed "${MISSING_PACMAN[@]}"
      fi
      if [ "${#MISSING_PARU[@]}" -gt 0 ]; then
        if has paru; then
          echo -e "\n${BOLD}Installing via paru...${RESET}"
          paru -S --needed "${MISSING_PARU[@]}"
        else
          echo -e "\n${YELLOW}paru not installed — skipping AUR packages. Install paru first, then re-run.${RESET}"
        fi
      fi
      ;;
    p)
      if [ "${#MISSING_PACMAN[@]}" -gt 0 ]; then
        echo -e "\n${BOLD}Installing via pacman...${RESET}"
        sudo pacman -S --needed "${MISSING_PACMAN[@]}"
      else
        echo -e "\n${DIM}No pacman packages queued.${RESET}"
      fi
      ;;
    u)
      if [ "${#MISSING_PARU[@]}" -gt 0 ]; then
        if has paru; then
          echo -e "\n${BOLD}Installing via paru...${RESET}"
          paru -S --needed "${MISSING_PARU[@]}"
        else
          echo -e "\n${YELLOW}paru not installed. Install it first, then re-run.${RESET}"
        fi
      else
        echo -e "\n${DIM}No AUR packages queued.${RESET}"
      fi
      ;;
    *)
      echo -e "\n${BOLD}Commands to run manually:${RESET}"
      if [ "${#MISSING_PACMAN[@]}" -gt 0 ]; then
        echo -e "\n  ${CYAN}# pacman${RESET}"
        echo "  sudo pacman -S --needed ${MISSING_PACMAN[*]}"
      fi
      if [ "${#MISSING_PARU[@]}" -gt 0 ]; then
        echo -e "\n  ${CYAN}# AUR (paru)${RESET}"
        echo "  paru -S --needed ${MISSING_PARU[*]}"
      fi
      if [ "${#MISSING_MANUAL[@]}" -gt 0 ]; then
        echo -e "\n  ${YELLOW}# Manual steps${RESET}"
        for m in "${MISSING_MANUAL[@]}"; do
          echo "  # $m"
        done
      fi
      ;;
  esac
fi

echo -e "\n${DIM}Re-run this script after installing to verify.${RESET}\n"
