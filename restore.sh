#!/usr/bin/env bash
# =============================================================================
# CachyOS System Restore Script
# Replays a snapshot captured by snapshot.sh on a fresh install
# Run this after cachyos-postinstall.sh, or standalone
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
prompt()  { echo -e "${YELLOW}[INPUT]${RESET} $*"; }

ask() {
    local question="$1"
    local response
    while true; do
        prompt "$question [y/N]: "
        read -r response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
DATA_DRIVE="/LinuxData"
SNAPSHOT_BASE="$DATA_DRIVE/system-snapshots"
CURRENT_USER="${USER:-$(whoami)}"
HOME_DIR="/home/$CURRENT_USER"
LOG_FILE="$HOME_DIR/cachyos-restore.log"

exec > >(tee -a "$LOG_FILE") 2>&1
info "Logging to $LOG_FILE"

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    error "Do not run as root. Run as your normal user."
    exit 1
fi

if ! mountpoint -q "$DATA_DRIVE"; then
    error "$DATA_DRIVE is not mounted."
    error "Mount your data drive first, then rerun this script."
    error "  sudo mount -a    (if fstab is already configured)"
    error "  or manually:     sudo mount /dev/sdXN /LinuxData"
    exit 1
fi

sudo -v || { error "Could not obtain sudo."; exit 1; }
(while true; do sudo -n true; sleep 50; done) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT

# =============================================================================
# SELECT SNAPSHOT
# =============================================================================
header "Select Snapshot to Restore"

# List available snapshots
SNAPSHOTS=()
while IFS= read -r snap; do
    SNAPSHOTS+=("$snap")
done < <(ls -d "$SNAPSHOT_BASE"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] 2>/dev/null | sort -r)

if [[ ${#SNAPSHOTS[@]} -eq 0 ]]; then
    error "No snapshots found in $SNAPSHOT_BASE"
    error "Run snapshot.sh first to create one."
    exit 1
fi

echo ""
echo -e "${BOLD}Available snapshots:${RESET}"
echo ""
for i in "${!SNAPSHOTS[@]}"; do
    SNAP_DATE=$(basename "${SNAPSHOTS[$i]}")
    INFO_FILE="${SNAPSHOTS[$i]}/snapshot-info.txt"
    if [[ -f "$INFO_FILE" ]]; then
        PKG_COUNT=$(grep "Pacman packages" "$INFO_FILE" | awk -F: '{print $2}' | xargs)
        AUR_COUNT=$(grep "AUR packages" "$INFO_FILE" | awk -F: '{print $2}' | xargs)
        KERNEL=$(grep "Kernel" "$INFO_FILE" | awk -F: '{print $2}' | xargs)
        printf "  ${CYAN}%2d${RESET}. %s  ${DIM}[%s pacman | %s AUR | kernel %s]${RESET}\n" \
            "$((i+1))" "$SNAP_DATE" "$PKG_COUNT" "$AUR_COUNT" "$KERNEL"
    else
        printf "  ${CYAN}%2d${RESET}. %s\n" "$((i+1))" "$SNAP_DATE"
    fi
done

echo ""
prompt "Enter snapshot number to restore from: "
read -r SNAP_CHOICE

if ! [[ "$SNAP_CHOICE" =~ ^[0-9]+$ ]] || \
   (( SNAP_CHOICE < 1 || SNAP_CHOICE > ${#SNAPSHOTS[@]} )); then
    error "Invalid selection."
    exit 1
fi

SNAPSHOT_DIR="${SNAPSHOTS[$((SNAP_CHOICE-1))]}"
info "Using snapshot: ${BOLD}$(basename "$SNAPSHOT_DIR")${RESET}"

# Show snapshot info
if [[ -f "$SNAPSHOT_DIR/snapshot-info.txt" ]]; then
    echo ""
    cat "$SNAPSHOT_DIR/snapshot-info.txt"
    echo ""
fi

ask "Proceed with this snapshot?" || { info "Aborted."; exit 0; }

# =============================================================================
# 1. INSTALL PACMAN PACKAGES
# =============================================================================
header "Pacman Packages"

PACMAN_LIST="$SNAPSHOT_DIR/packages/pacman-explicit.txt"

if [[ -f "$PACMAN_LIST" ]]; then
    PKG_COUNT=$(wc -l < "$PACMAN_LIST")
    info "Installing $PKG_COUNT pacman packages..."
    warn "Packages that no longer exist in the repos will be skipped with a warning."

    # Install in one shot; --needed skips already-installed ones
    if sudo pacman -S --needed --noconfirm - < "$PACMAN_LIST"; then
        success "Pacman packages installed."
    else
        warn "Some packages may have failed. Check $LOG_FILE for details."
    fi
else
    warn "No pacman package list found — skipping."
fi

# =============================================================================
# 2. INSTALL AUR PACKAGES
# =============================================================================
header "AUR Packages"

AUR_LIST="$SNAPSHOT_DIR/packages/aur-packages.txt"

if [[ -f "$AUR_LIST" ]]; then
    AUR_COUNT=$(wc -l < "$AUR_LIST")
    info "Installing $AUR_COUNT AUR packages via paru..."
    warn "AUR packages that have been removed or renamed will fail individually."

    # Install one by one so a single failure doesn't abort the rest
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if paru -S --needed --noconfirm "$pkg" 2>/dev/null; then
            success "Installed: $pkg"
        else
            warn "Failed (skipped): $pkg"
        fi
    done < "$AUR_LIST"

    success "AUR package pass complete."
else
    warn "No AUR package list found — skipping."
fi

# =============================================================================
# 3. INSTALL FLATPAK APPS
# =============================================================================
header "Flatpak Apps"

FLATPAK_LIST="$SNAPSHOT_DIR/packages/flatpak-apps.txt"

if [[ -f "$FLATPAK_LIST" ]] && [[ -s "$FLATPAK_LIST" ]]; then
    if command -v flatpak &>/dev/null; then
        FLAT_COUNT=$(wc -l < "$FLATPAK_LIST")
        info "Installing $FLAT_COUNT Flatpak apps..."
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            if flatpak install --noninteractive flathub "$app" 2>/dev/null; then
                success "Installed: $app"
            else
                warn "Failed (skipped): $app"
            fi
        done < "$FLATPAK_LIST"
    else
        warn "Flatpak not installed on this system — skipping Flatpak restore."
        warn "Install flatpak first: sudo pacman -S flatpak"
    fi
else
    info "No Flatpak apps in snapshot — skipping."
fi

# =============================================================================
# 4. RESTORE USER GROUPS
# =============================================================================
header "User Group Permissions"

GROUPS_FILE="$SNAPSHOT_DIR/system/user-groups.txt"

if [[ -f "$GROUPS_FILE" ]]; then
    # The file looks like: "username : group1 group2 group3"
    # Extract just the group names, excluding the username
    SAVED_GROUPS=$(cat "$GROUPS_FILE" | sed 's/.*: //' | tr ' ' ',')
    info "Restoring groups: $SAVED_GROUPS"
    sudo usermod -aG "$SAVED_GROUPS" "$CURRENT_USER"
    success "Groups restored. Log out and back in for changes to take effect."
else
    warn "No group file found — skipping."
fi

# =============================================================================
# 5. RESTORE SYSTEM CONFIG FILES
# =============================================================================
header "System Configuration Files"

warn "System config restore will overwrite files in /etc."
warn "Review each one before confirming."
echo ""

ETC_BACKUP="$SNAPSHOT_DIR/system/etc"

if [[ -d "$ETC_BACKUP" ]]; then
    # Walk the backed-up etc structure and restore each file
    while IFS= read -r -d '' src_file; do
        # Convert backup path back to real /etc path
        rel_path="${src_file#$ETC_BACKUP}"
        dest_file="$rel_path"

        if [[ -f "$src_file" ]]; then
            echo ""
            info "File: $dest_file"
            if [[ -f "$dest_file" ]]; then
                echo -e "${DIM}--- Differences from current: ---${RESET}"
                diff "$dest_file" "$src_file" || true
                echo -e "${DIM}--- End diff ---${RESET}"
            else
                warn "File does not exist on this system yet — will be created."
            fi

            if ask "Restore $dest_file?"; then
                sudo mkdir -p "$(dirname "$dest_file")"
                sudo cp "$src_file" "$dest_file"
                success "Restored: $dest_file"
            else
                info "Skipped: $dest_file"
            fi

        elif [[ -d "$src_file" ]]; then
            # Handle directories (e.g. sysctl.d)
            if ask "Restore directory $dest_file/?"; then
                sudo cp -r "$src_file" "$dest_file"
                success "Restored directory: $dest_file"
            fi
        fi
    done < <(find "$ETC_BACKUP" -mindepth 1 -maxdepth 3 -print0 | sort -z)
else
    warn "No system config backup found — skipping."
fi

# =============================================================================
# 6. RESTORE DOTFILES
# =============================================================================
header "Dotfiles and User Configs"

DOTFILES_BACKUP="$SNAPSHOT_DIR/dotfiles"

if [[ -d "$DOTFILES_BACKUP" ]]; then
    while IFS= read -r -d '' src_file; do
        rel_path="${src_file#$DOTFILES_BACKUP/}"
        dest_file="$HOME_DIR/$rel_path"

        if [[ -f "$src_file" ]]; then
            if ask "Restore ~/$rel_path?"; then
                mkdir -p "$(dirname "$dest_file")"
                cp "$src_file" "$dest_file"
                success "Restored: ~/$rel_path"
            else
                info "Skipped: ~/$rel_path"
            fi
        fi
    done < <(find "$DOTFILES_BACKUP" -type f -print0 | sort -z)
else
    warn "No dotfiles backup found — skipping."
fi

# =============================================================================
# 7. RE-ENABLE SYSTEMD SERVICES
# =============================================================================
header "Systemd Services"

SERVICES_FILE="$SNAPSHOT_DIR/services/system-enabled.txt"
TIMERS_FILE="$SNAPSHOT_DIR/services/enabled-timers.txt"
USER_SERVICES_FILE="$SNAPSHOT_DIR/services/user-enabled.txt"

# These are managed by pacman/systemd itself and shouldn't be force-enabled
SKIP_SERVICES=(
    "dbus.service"
    "getty@tty1.service"
    "systemd-logind.service"
    "systemd-journald.service"
    "systemd-udevd.service"
    "systemd-resolved.service"
    "user@1000.service"
)

enable_if_available() {
    local unit="$1"
    local scope="${2:-system}"  # system or user

    # Skip internal systemd units
    for skip in "${SKIP_SERVICES[@]}"; do
        [[ "$unit" == "$skip" ]] && return 0
    done

    if [[ "$scope" == "user" ]]; then
        if systemctl --user enable "$unit" 2>/dev/null; then
            success "Enabled (user): $unit"
        else
            warn "Could not enable (user): $unit — may not be installed"
        fi
    else
        if sudo systemctl enable "$unit" 2>/dev/null; then
            success "Enabled: $unit"
        else
            warn "Could not enable: $unit — may not be installed"
        fi
    fi
}

if [[ -f "$SERVICES_FILE" ]]; then
    info "Re-enabling system services..."
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        enable_if_available "$svc" "system"
    done < "$SERVICES_FILE"
fi

if [[ -f "$TIMERS_FILE" ]]; then
    info "Re-enabling timers..."
    while IFS= read -r timer; do
        [[ -z "$timer" ]] && continue
        enable_if_available "$timer" "system"
    done < "$TIMERS_FILE"
fi

if [[ -f "$USER_SERVICES_FILE" ]] && [[ -s "$USER_SERVICES_FILE" ]]; then
    info "Re-enabling user services..."
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        enable_if_available "$svc" "user"
    done < "$USER_SERVICES_FILE"
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Restore complete!${RESET}"
echo -e "${DIM}  Log saved to: $LOG_FILE${RESET}"
echo ""
echo -e "${YELLOW}  Next steps:${RESET}"
echo -e "  1. Log out and back in (group changes need this)"
echo -e "  2. Reboot if you restored /etc/fstab or sysctl files"
echo -e "  3. Run 'sudo mkinitcpio -P' if you restored mkinitcpio.conf"
echo -e "  4. Run 'sudo grub-mkconfig -o /boot/grub/grub.cfg' if you restored GRUB config"
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
echo ""
