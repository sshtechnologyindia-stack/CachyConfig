#!/usr/bin/env bash
# =============================================================================
# CachyOS System Snapshot Script
# Captures installed packages, configs, services, and dotfiles
# Run this periodically to keep your snapshot current
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${BLUE}═══ $* ═══${RESET}\n"; }

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
DATA_DRIVE="/yourdrivename"
SNAPSHOT_BASE="$DATA_DRIVE/system-snapshots"
DATE=$(date +%Y-%m-%d)
SNAPSHOT_DIR="$SNAPSHOT_BASE/$DATE"
CURRENT_USER="${USER:-$(whoami)}"
HOME_DIR="/home/$CURRENT_USER"

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    error "Do not run as root. Run as your normal user — sudo will be called where needed."
    exit 1
fi

if ! mountpoint -q "$DATA_DRIVE"; then
    error "$DATA_DRIVE is not mounted."
    error "Mount your data drive first: sudo mount -a"
    error "Or check: lsblk / cat /etc/fstab"
    exit 1
fi

# -----------------------------------------------------------------------------
# Create snapshot directory
# -----------------------------------------------------------------------------
mkdir -p "$SNAPSHOT_DIR"/{packages,configs,system,dotfiles,services}

info "Snapshot destination: ${BOLD}$SNAPSHOT_DIR${RESET}"
info "Capturing system state for user: ${BOLD}$CURRENT_USER${RESET}"

# =============================================================================
# 1. PACKAGES
# =============================================================================
header "Packages"

# All explicitly installed pacman packages (not dependencies)
info "Exporting pacman package list..."
pacman -Qqen > "$SNAPSHOT_DIR/packages/pacman-explicit.txt"
success "Pacman packages: $(wc -l < "$SNAPSHOT_DIR/packages/pacman-explicit.txt") packages"

# AUR packages only
info "Exporting AUR package list..."
pacman -Qqem > "$SNAPSHOT_DIR/packages/aur-packages.txt"
success "AUR packages: $(wc -l < "$SNAPSHOT_DIR/packages/aur-packages.txt") packages"

# Full package list with versions (for reference/diffing)
pacman -Q > "$SNAPSHOT_DIR/packages/all-packages-with-versions.txt"
success "Full package list (with versions) saved."

# Flatpak apps (if flatpak is installed)
if command -v flatpak &>/dev/null; then
    info "Exporting Flatpak apps..."
    flatpak list --app --columns=application > "$SNAPSHOT_DIR/packages/flatpak-apps.txt"
    success "Flatpak apps: $(wc -l < "$SNAPSHOT_DIR/packages/flatpak-apps.txt") apps"
else
    info "Flatpak not installed — skipping."
fi

# =============================================================================
# 2. ENABLED SYSTEMD SERVICES
# =============================================================================
header "Systemd Services"

info "Exporting enabled user and system services..."

# System-level enabled services
systemctl list-unit-files --state=enabled --type=service --no-legend \
    | awk '{print $1}' \
    > "$SNAPSHOT_DIR/services/system-enabled.txt"
success "System services: $(wc -l < "$SNAPSHOT_DIR/services/system-enabled.txt") enabled"

# User-level enabled services
systemctl --user list-unit-files --state=enabled --type=service --no-legend \
    | awk '{print $1}' \
    > "$SNAPSHOT_DIR/services/user-enabled.txt" 2>/dev/null || true
success "User services exported."

# Enabled timers too
systemctl list-unit-files --state=enabled --type=timer --no-legend \
    | awk '{print $1}' \
    > "$SNAPSHOT_DIR/services/enabled-timers.txt"
success "Timers: $(wc -l < "$SNAPSHOT_DIR/services/enabled-timers.txt") enabled"

# =============================================================================
# 3. USER GROUPS
# =============================================================================
header "User Groups"

info "Capturing group memberships for $CURRENT_USER..."
groups "$CURRENT_USER" > "$SNAPSHOT_DIR/system/user-groups.txt"
success "Groups saved: $(cat "$SNAPSHOT_DIR/system/user-groups.txt")"

# =============================================================================
# 4. SYSTEM CONFIG FILES
# =============================================================================
header "System Configuration Files"

# We copy /etc files that are commonly modified — not the whole /etc
SYSTEM_CONFIGS=(
    "/etc/fstab"
    "/etc/vconsole.conf"
    "/etc/sysctl.d"
    "/etc/ufw"
    "/etc/default/grub"
    "/etc/apparmor/parser.conf"
    "/etc/hosts"
    "/etc/hostname"
    "/etc/locale.conf"
    "/etc/locale.gen"
    "/etc/mkinitcpio.conf"
    "/etc/environment"
)

mkdir -p "$SNAPSHOT_DIR/system/etc"

for cfg in "${SYSTEM_CONFIGS[@]}"; do
    if [[ -e "$cfg" ]]; then
        # Preserve directory structure under system/etc/
        dest="$SNAPSHOT_DIR/system/etc${cfg}"
        mkdir -p "$(dirname "$dest")"
        sudo cp -r "$cfg" "$dest"
        success "Copied: $cfg"
    else
        warn "Not found (skipping): $cfg"
    fi
done

# =============================================================================
# 5. DOTFILES AND USER CONFIGS
# =============================================================================
header "Dotfiles and User Configs"

# Specific dotfiles from home dir
HOME_DOTFILES=(
    ".zshrc"
    ".bashrc"
    ".bash_profile"
    ".profile"
    ".gitconfig"
    ".config/fish"
    ".config/fastfetch"
    ".config/environment.d"
    ".config/plasma-workspace"
    ".config/kwinrc"
    ".config/kdeglobals"
    ".config/plasmarc"
    ".config/plasmashellrc"
    ".config/ktimezonedrc"
    ".config/kscreenlockerrc"
    ".config/kglobalshortcutsrc"
    ".config/powermanagementprofilesrc"
    ".vmware/preferences"
)

mkdir -p "$SNAPSHOT_DIR/dotfiles"

for dotfile in "${HOME_DOTFILES[@]}"; do
    src="$HOME_DIR/$dotfile"
    if [[ -e "$src" ]]; then
        dest="$SNAPSHOT_DIR/dotfiles/$dotfile"
        mkdir -p "$(dirname "$dest")"
        cp -r "$src" "$dest"
        success "Copied: ~/$dotfile"
    else
        info "Not found (skipping): ~/$dotfile"
    fi
done

# =============================================================================
# 6. SNAPSHOT METADATA
# =============================================================================
header "Metadata"

cat > "$SNAPSHOT_DIR/snapshot-info.txt" <<EOF
Snapshot Date:    $DATE
Hostname:         $(hostname)
User:             $CURRENT_USER
Kernel:           $(uname -r)
OS:               $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')
Desktop:          ${XDG_CURRENT_DESKTOP:-unknown}
Uptime at snap:   $(uptime -p)
Pacman packages:  $(wc -l < "$SNAPSHOT_DIR/packages/pacman-explicit.txt")
AUR packages:     $(wc -l < "$SNAPSHOT_DIR/packages/aur-packages.txt")
EOF

if command -v flatpak &>/dev/null; then
    echo "Flatpak apps:     $(wc -l < "$SNAPSHOT_DIR/packages/flatpak-apps.txt")" \
        >> "$SNAPSHOT_DIR/snapshot-info.txt"
fi

success "Metadata written."
cat "$SNAPSHOT_DIR/snapshot-info.txt"

# =============================================================================
# 7. CLEANUP OLD SNAPSHOTS (keep last 5)
# =============================================================================
header "Cleanup"

SNAPSHOT_COUNT=$(ls -d "$SNAPSHOT_BASE"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] 2>/dev/null | wc -l)
info "Total snapshots stored: $SNAPSHOT_COUNT"

if (( SNAPSHOT_COUNT > 5 )); then
    info "Keeping the 5 most recent snapshots. Removing older ones..."
    ls -d "$SNAPSHOT_BASE"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \
        | sort \
        | head -n "$(( SNAPSHOT_COUNT - 5 ))" \
        | while read -r old_snap; do
            warn "Removing old snapshot: $old_snap"
            rm -rf "$old_snap"
        done
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Snapshot complete!${RESET}"
echo -e "${DIM}  Saved to: $SNAPSHOT_DIR${RESET}"
echo -e "${DIM}  Use restore.sh on a fresh install to replay.${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
echo ""
