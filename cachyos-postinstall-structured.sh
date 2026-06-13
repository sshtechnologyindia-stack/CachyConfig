#!/usr/bin/env bash
# =============================================================================
# CachyOS Structured Post-Install Setup Script
# Modular setup for system install, drivers, settings, appearance, and apps.
# Generated from the user's original cachyos-postinstall.sh and reorganized.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colors and formatting
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

LOG_FILE="$HOME/cachyos-postinstall.log"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Logging to $LOG_FILE"

if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root. It will call sudo where needed."
    exit 1
fi

sudo -v || { error "Could not obtain sudo. Exiting."; exit 1; }
(while true; do sudo -n true; sleep 50; done) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT

CURRENT_USER="${USER:-$(whoami)}"
info "Detected user: ${BOLD}$CURRENT_USER${RESET}"

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

try() {
    if ! "$@"; then
        warn "Command failed (non-fatal): $*"
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

first_available_helper() {
    if command_exists paru; then echo "paru"; return 0; fi
    if command_exists yay; then echo "yay"; return 0; fi
    return 1
}

require_aur_helper() {
    if first_available_helper >/dev/null; then
        return 0
    fi
    error "No AUR helper found. Install paru or yay before installing AUR packages."
    error "Most CachyOS installs include paru. If missing, install it first."
    return 1
}

require_multilib_if_needed() {
    local needs_multilib=0
    for pkg in "$@"; do
        [[ "$pkg" == lib32-* ]] && needs_multilib=1
    done
    if [[ $needs_multilib -eq 0 ]]; then
        return 0
    fi
    if pacman-conf --repo-list 2>/dev/null | grep -qx "multilib"; then
        success "multilib repository is enabled."
    else
        warn "This package group includes lib32 packages. Enable [multilib] in /etc/pacman.conf before installing them."
        warn "Without multilib, 32-bit gaming, Wine, Steam, and some GPU packages may fail."
    fi
}

require_dkms_headers_if_needed() {
    local needs_dkms=0
    for pkg in "$@"; do
        [[ "$pkg" == *dkms* || "$pkg" == virtualbox-host-dkms || "$pkg" == lkrg-dkms ]] && needs_dkms=1
    done
    if [[ $needs_dkms -eq 0 ]]; then
        return 0
    fi
    info "DKMS package detected. Checking installed kernel headers..."
    local missing=0
    while read -r kernel; do
        [[ -z "$kernel" ]] && continue
        local base="${kernel%%-*}"
        if ! pacman -Q "${kernel}-headers" >/dev/null 2>&1 && ! pacman -Q "linux-headers" >/dev/null 2>&1 && ! pacman -Q "linux-cachyos-headers" >/dev/null 2>&1; then
            warn "Could not confirm matching headers for kernel: $kernel"
            missing=1
        fi
    done < <(pacman -Qq | grep -E '^linux($|-|[0-9])' || true)
    if [[ $missing -eq 1 ]]; then
        warn "Install matching kernel headers before DKMS modules if module build fails."
    else
        success "Kernel headers appear to be present or CachyOS headers are installed."
    fi
}

package_available_official() {
    pacman -Si "$1" >/dev/null 2>&1
}

show_pkg_dependencies() {
    local pkg="$1"
    local helper=""
    helper="$(first_available_helper 2>/dev/null || true)"

    echo -e "${DIM}Dependency check for ${pkg}:${RESET}"
    if pacman -Si "$pkg" >/tmp/pkginfo.$$ 2>/dev/null; then
        grep -E '^(Repository|Depends On|Optional Deps|Conflicts With|Provides)' /tmp/pkginfo.$$ | sed 's/^/  /' || true
        rm -f /tmp/pkginfo.$$
        return 0
    fi

    if [[ -n "$helper" ]] && "$helper" -Si "$pkg" >/tmp/pkginfo.$$ 2>/dev/null; then
        grep -E '^(Repository|Depends On|Optional Deps|Conflicts With|Provides)' /tmp/pkginfo.$$ | sed 's/^/  /' || true
        rm -f /tmp/pkginfo.$$
        return 0
    fi

    rm -f /tmp/pkginfo.$$
    warn "Could not query dependency metadata for $pkg. It may be renamed, unavailable, or require another repository."
}

install_pkgs() {
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && return 0

    require_multilib_if_needed "${packages[@]}"
    require_dkms_headers_if_needed "${packages[@]}"

    local official=()
    local aur=()
    local pkg
    for pkg in "${packages[@]}"; do
        if package_available_official "$pkg"; then
            official+=("$pkg")
        else
            aur+=("$pkg")
        fi
    done

    if [[ ${#official[@]} -gt 0 ]]; then
        sudo pacman -S --needed --noconfirm "${official[@]}"
    fi

    if [[ ${#aur[@]} -gt 0 ]]; then
        require_aur_helper || return 1
        local helper
        helper="$(first_available_helper)"
        "$helper" -S --needed --noconfirm "${aur[@]}"
    fi
}

install_described_pkgs() {
    local category="$1"
    shift
    local entries=("$@")
    local packages=()
    local entry pkg desc notes

    header "$category"
    echo -e "${BOLD}Package plan:${RESET}"
    for entry in "${entries[@]}"; do
        pkg="${entry%%|*}"
        desc="${entry#*|}"; desc="${desc%%|*}"
        notes="${entry##*|}"
        packages+=("$pkg")
        echo -e "  ${CYAN}${pkg}${RESET} — ${desc}"
        if [[ "$notes" != "$desc" && -n "$notes" && "$notes" != "-" ]]; then
            echo -e "    ${DIM}Dependency note: ${notes}${RESET}"
        fi
    done
    echo ""

    if ask "Show dependency metadata before installing $category?"; then
        for pkg in "${packages[@]}"; do
            show_pkg_dependencies "$pkg"
        done
        echo ""
    fi

    if ask "Install $category?"; then
        install_pkgs "${packages[@]}"
        success "$category installed."
    else
        warn "$category skipped."
    fi
}

# =============================================================================
# SYSTEM INSTALL & BASE MAINTENANCE
# =============================================================================

section_base_install() {
    header "System Install — Base Utilities and Maintenance"
    info "Installing base post-install utilities."
    install_pkgs pacman-contrib realtime-privileges lolcat fastfetch fwupd power-profiles-daemon fish git curl jq appstream

    info "Enabling package cache cleanup timer."
    sudo systemctl enable paccache.timer

    info "Enabling periodic SSD TRIM."
    sudo systemctl enable fstrim.timer

    if ask "Set vm.swappiness=150 for CachyOS zram tuning?"; then
        SYSCTL_CONF="/etc/sysctl.d/100-arch.conf"
        if grep -q "^vm.swappiness" "$SYSCTL_CONF" 2>/dev/null; then
            sudo sed -i 's/^vm.swappiness=.*/vm.swappiness=150/' "$SYSCTL_CONF"
        else
            echo "vm.swappiness=150" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        fi
        success "vm.swappiness set to 150."
    fi
}

section_firmware() {
    header "System Install — Kernel Firmware Warning Fixes"
    info "Installing firmware packages often referenced in mkinitcpio/kernel warnings."
    install_pkgs aic94xx-firmware wd719x-firmware upd72020x-fw

    if ask "Fix console font warning by setting FONT=gr737c-8x14 in vconsole.conf?"; then
        VCONSOLE="/etc/vconsole.conf"
        if grep -q "^FONT=" "$VCONSOLE" 2>/dev/null; then
            sudo sed -i 's/^FONT=.*/FONT=gr737c-8x14/' "$VCONSOLE"
        else
            echo "FONT=gr737c-8x14" | sudo tee -a "$VCONSOLE" > /dev/null
        fi
        success "vconsole.conf updated."
    fi
}

section_mount_drive() {
    header "System Install — Storage Mounts"
    if ask "Mount an additional drive via fstab?"; then
        info "Available block devices:"
        sudo blkid
        echo ""
        prompt "Enter the UUID of the drive to mount: "
        read -r DRIVE_UUID
        prompt "Enter the mount point, e.g. /LinuxData: "
        read -r MOUNT_POINT
        prompt "Enter filesystem type, e.g. btrfs or ext4: "
        read -r FS_TYPE

        if [[ -z "$DRIVE_UUID" || -z "$MOUNT_POINT" || -z "$FS_TYPE" ]]; then
            warn "Incomplete input — skipping fstab entry."
        else
            sudo mkdir -p "$MOUNT_POINT"
            FSTAB_ENTRY="UUID=$DRIVE_UUID $MOUNT_POINT    $FS_TYPE    defaults,noatime 0 0"
            if grep -q "$DRIVE_UUID" /etc/fstab 2>/dev/null; then
                warn "UUID already exists in /etc/fstab — skipping."
            else
                echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null
                success "fstab entry added: $FSTAB_ENTRY"
                info "Run 'sudo mount -a' to mount now, or reboot."
            fi
        fi
    fi
}

section_groups() {
    header "System Install — User Group Permissions"
    info "Adding $CURRENT_USER to common desktop, hardware, and realtime groups."
    sudo usermod -aG audio,video,storage,network,optical,power,sys,rfkill,wheel,users,realtime "$CURRENT_USER"
    success "Groups updated. Log out and back in for group changes to take effect."
}

# =============================================================================
# SYSTEM DRIVERS INSTALLATION
# =============================================================================

section_amd_gpu() {
    header "System Drivers Installation — AMD GPU"
    install_described_pkgs "AMD GPU Core Drivers" \
        "xf86-video-amdgpu|X.org AMD display driver for 2D acceleration.|Requires AMD GPU hardware." \
        "mesa|OpenGL graphics stack for AMD and Intel GPUs.|Core dependency for most Linux graphics apps." \
        "lib32-mesa|32-bit Mesa libraries for Steam/Wine compatibility.|Requires multilib repository." \
        "vulkan-radeon|Open-source AMD Vulkan driver.|Requires supported AMD GPU." \
        "lib32-vulkan-radeon|32-bit AMD Vulkan driver for games and Wine.|Requires multilib repository." \
        "libva-mesa-driver|VA-API hardware video decode/encode support through Mesa.|Works with Mesa-compatible AMD GPUs." \
        "mesa-vdpau|VDPAU acceleration support through Mesa.|Optional video acceleration layer."

    if ask "Install AMD proprietary Vulkan drivers? Usually not needed unless a specific game/app needs them."; then
        install_described_pkgs "AMD Proprietary Vulkan Drivers" \
            "vulkan-amdgpu-pro|AMD proprietary Vulkan runtime.|May conflict with or be less useful than RADV for many users." \
            "amdvlk|AMDVLK Vulkan driver.|Alternative Vulkan implementation for AMD GPUs." \
            "lib32-vulkan-amdgpu-pro|32-bit proprietary AMD Vulkan runtime.|Requires multilib." \
            "lib32-amdvlk|32-bit AMDVLK runtime.|Requires multilib."
    fi

    if ask "Install OpenCL support for AMD?"; then
        install_described_pkgs "AMD OpenCL Stack" \
            "opencl-legacy-amdgpu-pro|Legacy AMD OpenCL runtime for older workloads.|AUR package; GPU support varies by generation." \
            "ocl-icd|OpenCL ICD loader.|Required by OpenCL runtimes." \
            "clinfo|Utility to verify OpenCL platforms/devices.|Useful for testing OpenCL installation." \
            "lib32-opencl-legacy-amdgpu-pro|32-bit legacy AMD OpenCL runtime.|Requires multilib." \
            "lib32-ocl-icd|32-bit OpenCL ICD loader.|Requires multilib." \
            "rocm-opencl-runtime|ROCm OpenCL runtime for supported AMD GPUs.|ROCm hardware support is GPU-generation dependent."
    fi

    if ask "Install AMF encoder and image format libraries for OBS/FFmpeg?"; then
        install_described_pkgs "AMD AMF and Image Codec Support" \
            "amf-amdgpu-pro|AMD AMF encoder support, useful for OBS/FFmpeg workflows.|AUR package; requires compatible AMD GPU/driver stack." \
            "openjpeg|JPEG 2000 image codec library.|Codec dependency for media apps." \
            "libwebp|WebP image codec library.|Codec dependency for browsers and image apps." \
            "libavif|AVIF image codec library.|Codec dependency for modern image support." \
            "libheif|HEIF/HEIC image codec library.|Useful for iPhone image compatibility." \
            "libvpx|VP8/VP9 video codec library.|Used by browsers and media tools."
    fi
}

section_nvidia_primary() {
    header "System Drivers Installation — NVIDIA Primary GPU Laptop Mode"
    warn "This does not install NVIDIA drivers. It sets environment variables to prefer NVIDIA on hybrid laptops."
    if ask "Write NVIDIA offload environment configuration?"; then
        mkdir -p "$HOME/.config/environment.d/"
        NVIDIA_CONF="$HOME/.config/environment.d/90-nvidia.conf"
        cat > "$NVIDIA_CONF" <<'EOF_NVIDIA'
__NV_PRIME_RENDER_OFFLOAD=1
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_only
EOF_NVIDIA
        success "NVIDIA config written to $NVIDIA_CONF. Reboot required."
    fi
}

section_bluetooth_printing_audio() {
    header "System Drivers Installation — Bluetooth, Printing, Audio, Wi-Fi Hotspot"
    install_described_pkgs "Bluetooth Extras" \
        "bluez-hid2hci|Bluetooth HID mode switching support.|Requires BlueZ stack." \
        "bluez-plugins|Extra Bluetooth plugins.|Requires BlueZ stack." \
        "python-prctl|Python bindings for process control capabilities.|Dependency for some Bluetooth tooling."

    install_described_pkgs "Printing and Scanning Stack" \
        "cups-pk-helper|PolicyKit helper for CUPS administration.|Requires CUPS stack." \
        "hplip|HP printer and scanner driver suite.|Needed for many HP devices." \
        "sane-airscan|Driverless network scanner support.|Requires SANE-compatible scanner/network device." \
        "splix|Samsung/Xerox printer driver support.|Needed only for supported models." \
        "bluez-cups|Bluetooth printing support.|Requires Bluetooth and CUPS." \
        "python-pysmbc|Python SMB bindings for printer discovery/sharing.|Useful for Windows/Samba print environments." \
        "python-reportlab|PDF/report generation library used by printing tools.|Dependency for HPLIP utilities." \
        "colord-sane|Color management support for scanners.|Useful for color-managed scanning." \
        "a2ps|Text-to-PostScript conversion utility.|Legacy printing helper." \
        "psutils|PostScript manipulation utilities.|Legacy printing helper." \
        "libvncserver|VNC server/client support library.|Dependency for some scanner/virtualization tools." \
        "paper|Paper size management utility/library.|Used by printing workflows." \
        "perl-alien-build|Perl Alien build helper.|Dependency/helper for Perl XML/printing modules." \
        "perl-alien-libxml2|Perl Alien wrapper for libxml2.|Dependency/helper for XML print tooling." \
        "perl-capture-tiny|Perl output capture module.|Dependency/helper for print/XML tooling." \
        "perl-dbi|Perl database interface.|Dependency for some print/helper tools." \
        "perl-ffi-checklib|Perl library detection helper.|Dependency/helper for Perl modules." \
        "perl-file-chdir|Perl directory change helper.|Dependency/helper for Perl modules." \
        "perl-file-which|Perl executable lookup helper.|Dependency/helper for Perl modules." \
        "perl-ipc-run|Perl IPC execution module.|Dependency/helper for Perl modules." \
        "perl-path-tiny|Perl path utility module.|Dependency/helper for Perl modules." \
        "perl-xml-libxml|Perl libxml2 XML bindings.|Used by XML-heavy print/scanning tooling." \
        "perl-xml-sax|Perl SAX XML framework.|Used by XML modules." \
        "perl-xml-sax-base|Base classes for Perl SAX XML modules.|Used by XML modules." \
        "vde2|Virtual Distributed Ethernet tools.|Optional virtual networking support."

    if ask "Install/reinstall PipeWire audio stack? CachyOS normally ships PipeWire already."; then
        install_described_pkgs "PipeWire Audio Stack" \
            "pipewire|Modern Linux audio/video server.|Core audio component." \
            "pipewire-alsa|ALSA compatibility for PipeWire.|Required for ALSA apps through PipeWire." \
            "pipewire-jack|JACK compatibility for PipeWire.|Useful for pro-audio apps." \
            "pipewire-jack-dropin|Drop-in JACK replacement configuration for PipeWire.|Useful for JACK apps expecting JACK libraries." \
            "pipewire-media-session|Legacy PipeWire session manager.|Usually replaced by WirePlumber; install only if needed." \
            "pipewire-pulse|PulseAudio compatibility for PipeWire.|Required for most desktop audio apps." \
            "pipewire-zeroconf|Zeroconf/RTP support for PipeWire.|Useful for network audio discovery." \
            "wireplumber|PipeWire session/policy manager.|Required for normal PipeWire desktop use." \
            "plasma-pa|KDE Plasma audio control applet.|Requires Plasma desktop." \
            "gst-plugin-pipewire|GStreamer PipeWire plugin.|Needed by apps using GStreamer capture/playback."
    fi

    install_described_pkgs "Wi-Fi Hotspot Tools" \
        "hostapd|Turns Wi-Fi adapter into access point mode.|Requires Wi-Fi chipset/driver supporting AP mode." \
        "linux-wifi-hotspot|GUI/utility for creating Linux Wi-Fi hotspots.|Uses hostapd and networking tools." \
        "wireless_tools|Legacy Wi-Fi command-line tools.|Useful for diagnostics." \
        "ethtool|Network interface configuration/diagnostic utility.|Useful for NIC diagnostics."
}

# =============================================================================
# SYSTEM SETTINGS, SECURITY & SERVICES
# =============================================================================

section_networking_security() {
    header "System Settings — Networking and Security Tools"
    install_described_pkgs "Network and Security Monitoring" \
        "lkrg-dkms|Linux Kernel Runtime Guard module for kernel integrity checks.|Requires DKMS and matching kernel headers." \
        "usbguard|USB device allow/block policy framework.|Requires service configuration after install." \
        "bettercap|Network attack/monitoring framework for audits and labs.|Use only on networks you own or are authorized to test." \
        "dsniff|Network auditing/sniffing utility collection.|Use only with authorization." \
        "nmap|Network scanner for host/service discovery.|No special dependencies beyond network access." \
        "smb4k|KDE Samba share browser.|Requires Samba client packages for SMB shares." \
        "tcpdump|Packet capture utility.|Requires permissions/capabilities for capture." \
        "portmaster|Application firewall/privacy network monitor.|Service may need enabling after install." \
        "snort|Network intrusion detection/prevention engine.|Needs rules and interface configuration after install."

    install_described_pkgs "NetworkManager VPN Plugins" \
        "networkmanager-openvpn|OpenVPN integration for NetworkManager.|Requires NetworkManager." \
        "networkmanager-openconnect|Cisco/GlobalProtect-compatible VPN integration.|Requires NetworkManager." \
        "networkmanager-fortisslvpn|Fortinet SSL VPN integration.|Requires NetworkManager." \
        "networkmanager-strongswan|IPsec/IKEv2 VPN integration.|Requires NetworkManager and strongSwan." \
        "networkmanager-pptp|PPTP VPN integration.|Legacy VPN protocol; avoid unless required." \
        "networkmanager-vpnc|Cisco VPNC integration.|Requires NetworkManager." \
        "network-manager-sstp|SSTP VPN integration.|Requires NetworkManager." \
        "wireguard-tools|WireGuard command-line tools.|Kernel support is built into modern Linux kernels." \
        "openvpn|OpenVPN client/server.|Used by OpenVPN profiles and NetworkManager plugin." \
        "strongswan|IPsec/IKEv2 VPN suite.|Used by strongSwan plugin." \
        "openfortivpn|Fortinet VPN command-line client.|Used for Fortinet SSL VPN." \
        "vpnc|Cisco-compatible VPN client.|Used by NetworkManager vpnc plugin." \
        "pptpclient|PPTP VPN client.|Legacy; use only if required." \
        "sstp-client|SSTP VPN client.|Used by SSTP plugin." \
        "xl2tpd|L2TP daemon.|Needed for L2TP/IPsec VPN workflows." \
        "openresolv|resolv.conf management helper.|Used by VPN/network tools." \
        "dnsmasq|Lightweight DNS/DHCP service.|Used by networking/hotspot scenarios." \
        "dhclient|DHCP client utility.|Required by some VPN/network workflows." \
        "gpsd|GPS service daemon.|Optional dependency for some network/location tooling." \
        "libnma|NetworkManager applet client library.|Used by NetworkManager GUI/VPN plugins." \
        "nm-cloud-setup|NetworkManager cloud network setup helper.|Useful mainly for cloud images." \
        "openldap|LDAP client libraries/tools.|Used by some enterprise VPN/auth integrations." \
        "pkcs11-helper|PKCS#11 helper library.|Needed for smart-card/certificate VPN authentication." \
        "pps-tools|Pulse-per-second timing tools.|Optional GPS/timing dependency." \
        "rp-pppoe|PPPoE client tools.|Needed for PPPoE network links." \
        "stoken|RSA SecurID-compatible token utility.|Used by some enterprise VPN workflows." \
        "tcl|Tool Command Language runtime.|Dependency for some VPN/helper tools." \
        "unixodbc|ODBC driver manager.|Optional dependency for some enterprise clients." \
        "usb_modeswitch|Switches USB modem devices from storage to modem mode.|Needed for some USB cellular modems."
}

section_antivirus() {
    header "System Settings — Antivirus Setup"
    install_described_pkgs "ClamAV Antivirus" \
        "clamav|Open-source antivirus engine and scanner.|freshclam service updates definitions." \
        "clamtk|GTK graphical interface for ClamAV.|Requires ClamAV."

    if ask "Update ClamAV definitions now?"; then
        sudo freshclam || warn "freshclam failed. Try again after the service starts or after network settles."
    fi
    if ask "Enable ClamAV freshclam and daemon services?"; then
        sudo systemctl enable --now clamav-freshclam.service
        sudo systemctl enable --now clamav-daemon.service
    fi
}

section_firewall() {
    header "System Settings — Firewall"
    install_described_pkgs "Firewall Tools" \
        "ufw|Simple command-line firewall frontend.|Uses Linux netfilter/nftables backend." \
        "gufw|Graphical interface for UFW.|Requires UFW."

    if ask "Enable UFW now?"; then
        sudo ufw enable
    fi
    if ask "Allow KDE Connect ports 1714-1764 UDP/TCP?"; then
        sudo ufw allow 1714:1764/udp
        sudo ufw allow 1714:1764/tcp
        sudo ufw reload
        success "KDE Connect ports opened."
    fi
}

section_apparmor() {
    header "System Settings — AppArmor"
    install_described_pkgs "AppArmor Mandatory Access Control" \
        "apparmor|Linux application confinement framework.|Requires kernel support and service enabled." \
        "apparmor.d-git|Community AppArmor profiles.|AUR package; profiles may need tuning."

    if ask "Enable AppArmor service now?"; then
        sudo systemctl enable --now apparmor.service
    fi
}

section_shell() {
    header "System Settings — Shell Configuration"
    warn "CachyOS commonly defaults to Fish. ZSH is optional."
    install_described_pkgs "ZSH Shell Stack" \
        "zsh|Z shell command interpreter.|Can be set as login shell with chsh." \
        "zsh-completions|Additional completion definitions for ZSH.|Requires zsh." \
        "zsh-syntax-highlighting|Command syntax highlighting for ZSH.|Must be sourced in .zshrc." \
        "zsh-theme-powerlevel10k-git|Powerlevel10k prompt theme.|Requires compatible font for icons." \
        "arcolinux-zsh-git|ArcoLinux ZSH defaults.|AUR package; opinionated config." \
        "oh-my-zsh-git|Oh My Zsh plugin/theme framework.|AUR package." \
        "oh-my-zsh-powerline-theme-git|Powerline theme for Oh My Zsh.|Requires Oh My Zsh and icon font."

    if ask "Copy .zshrc from a data drive?"; then
        prompt "Enter the full path to your .zshrc file: "
        read -r ZSHRC_PATH
        if [[ -f "$ZSHRC_PATH" ]]; then
            cp "$ZSHRC_PATH" "$HOME/.zshrc"
            success ".zshrc copied from $ZSHRC_PATH"
        else
            warn "File not found: $ZSHRC_PATH — skipping."
        fi
    fi
}

section_fastfetch() {
    header "System Settings — Fastfetch Configuration"
    info "Writing fastfetch config to ~/.config/fastfetch/config.jsonc."
    mkdir -p "$HOME/.config/fastfetch"
    cat > "$HOME/.config/fastfetch/config.jsonc" <<'EOF_FASTFETCH'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": { "type": "builtin", "height": 15, "width": 30, "padding": { "top": 5, "left": 3 } },
    "modules": [
        "break",
        { "type": "custom", "format": "\u001b[90m┌──────────────────────Hardware──────────────────────┐" },
        { "type": "host", "key": " PC", "keyColor": "green" },
        { "type": "cpu", "key": "│ ├", "keyColor": "green" },
        { "type": "gpu", "key": "│ ├󰍛", "keyColor": "green" },
        { "type": "memory", "key": "│ ├󰍛", "keyColor": "green" },
        { "type": "disk", "key": "└ └", "keyColor": "green" },
        { "type": "custom", "format": "\u001b[90m└────────────────────────────────────────────────────┘" },
        "break",
        { "type": "custom", "format": "\u001b[90m┌──────────────────────Software──────────────────────┐" },
        { "type": "os", "key": " OS", "keyColor": "yellow" },
        { "type": "kernel", "key": "│ ├", "keyColor": "yellow" },
        { "type": "bios", "key": "│ ├", "keyColor": "yellow" },
        { "type": "packages", "key": "│ ├󰏖", "keyColor": "yellow" },
        { "type": "shell", "key": "└ └", "keyColor": "yellow" },
        "break",
        { "type": "de", "key": " DE", "keyColor": "blue" },
        { "type": "lm", "key": "│ ├", "keyColor": "blue" },
        { "type": "wm", "key": "│ ├", "keyColor": "blue" },
        { "type": "wmtheme", "key": "│ ├󰉼", "keyColor": "blue" },
        { "type": "terminal", "key": "└ └", "keyColor": "blue" },
        "break",
        { "type": "uptime", "key": " Uptime", "keyColor": "magenta" },
        { "type": "datetime", "key": " DateTime", "keyColor": "magenta" },
        "break"
    ]
}
EOF_FASTFETCH
    success "Fastfetch config written. Run 'fastfetch' to test."
}

section_howdy() {
    header "System Settings — Face ID Login with Howdy"
    warn "Howdy modifies PAM behavior. This script does NOT auto-edit PAM files because a bad PAM edit can lock you out."
    install_described_pkgs "Howdy Face Authentication" \
        "howdy|Face authentication for Linux using webcam/IR camera.|Requires compatible camera and manual PAM configuration."

    info "Available video devices:"
    ls /dev/video* 2>/dev/null || warn "No video devices found."
    prompt "Enter webcam device path, e.g. /dev/video0, or leave blank to skip config: "
    read -r VIDEO_DEVICE
    if [[ -n "$VIDEO_DEVICE" ]]; then
        info "Open Howdy config and set device_path = $VIDEO_DEVICE."
        sleep 2
        sudo howdy config
        if ask "Enroll your face now?"; then
            sudo howdy add
        fi
    fi

    warn "Manual PAM lines to review for /etc/pam.d/sudo and /etc/pam.d/sddm:"
    echo -e "${DIM}  auth    sufficient    pam_python.so /lib/security/howdy/pam.py"
    echo -e "  auth    sufficient    pam_unix.so try_first_pass likeauth nullok${RESET}"
}

# =============================================================================
# SYSTEM SETTINGS — APPEARANCE: FONTS, ICONS, CURSORS, BOOT THEME
# =============================================================================

section_fonts() {
    install_described_pkgs "System Settings — Fonts" \
        "ttf-mac-fonts|Apple-style TrueType fonts.|AUR package." \
        "apple-fonts|Apple font package.|AUR package; licensing/source can change." \
        "adobe-source-sans-fonts|Adobe Source Sans font family.|Official repo package." \
        "noto-fonts|Google Noto font family for broad Unicode coverage.|Recommended base font set." \
        "noto-fonts-emoji|Emoji font support.|Required for color emoji rendering." \
        "ttf-droid|Droid font family.|General-purpose UI/text font." \
        "ttf-font-awesome|Font Awesome icon font.|Useful for terminals/widgets." \
        "ttf-roboto|Roboto font family.|Common Android/Google UI font." \
        "awesome-terminal-fonts|Icon fonts for terminal prompts/status bars.|Useful with shell themes." \
        "ttf-anonymous-pro|Monospace programming font.|Developer/editor font." \
        "ttf-hack|Hack monospace programming font.|Good terminal/editor font." \
        "ttf-ibm-plex|IBM Plex font family.|Modern UI/document font." \
        "ttf-liberation|Metric-compatible fonts for Arial/Times/Courier replacement.|Useful for document compatibility." \
        "ttf-dejavu|DejaVu font family.|Broad glyph coverage." \
        "ttf-ubuntu-font-family|Ubuntu font family.|Clean desktop/document font."

    if ask "Install Microsoft Windows fonts too?"; then
        install_described_pkgs "Microsoft Fonts" \
            "ttf-ms-win10-auto|Microsoft Windows 10 fonts from Microsoft CDN.|AUR package; download source availability may change."
    fi
}

section_icons_cursors() {
    install_described_pkgs "System Settings — Icon Themes" \
        "tela-icon-theme-git|Tela icon theme.|AUR package." \
        "flat-remix|Flat Remix icon theme.|AUR package." \
        "fluent-icon-theme-git|Fluent-style icon theme.|AUR package." \
        "surfn-icons-git|Surfn icon theme.|AUR package."

    install_described_pkgs "System Settings — Cursor Themes" \
        "xcursor-premium|Premium X cursor theme.|Desktop cursor theme." \
        "whitesur-cursor-theme-git|WhiteSur/macOS-like cursor theme.|AUR package." \
        "vimix-cursors|Vimix cursor theme.|Desktop cursor theme."
}

section_boot_theme() {
    header "System Settings — Boot Theme"
    warn "CachyOS may not use GRUB depending on your install. Only install this if your bootloader is GRUB."
    if ask "Install and apply GRUB Vimix theme?"; then
        install_pkgs arcolinux-grub-theme-vimix-git
        sudo sed -i 's|^#\?GRUB_THEME=.*|GRUB_THEME="/boot/grub/Vimix/theme.txt"|' /etc/default/grub
        sudo grub-mkconfig -o /boot/grub/grub.cfg
        success "GRUB Vimix theme applied."
    fi
}

# =============================================================================
# SYSTEM APPS — CATEGORIZED APPLICATION INSTALLERS
# =============================================================================

apps_browsers() {
    install_described_pkgs "System Apps — Browsers" \
        "firefox|Mainstream open-source web browser.|Official repo; extensions installed separately." \
        "firefox-ublock-origin|uBlock Origin ad/content blocker for Firefox.|Requires Firefox-compatible browser." \
        "brave-bin|Privacy-focused Chromium-based browser.|AUR binary package." \
        "google-chrome|Google Chrome browser.|AUR package; requires Google binary source availability." \
        "microsoft-edge-stable-bin|Microsoft Edge stable browser.|AUR binary package." \
        "firefox-developer-edition|Firefox build for web developers.|Can coexist with Firefox." \
        "zen-browser-bin|Zen browser, Firefox-based.|AUR binary package."
}

apps_office_productivity() {
    install_described_pkgs "System Apps — Office, Documents and Productivity" \
        "libreoffice-fresh|Full office suite for documents, spreadsheets, and presentations.|Java optional for some advanced features." \
        "libreoffice-extension-languagetool|LanguageTool integration for LibreOffice grammar checks.|Works best with LanguageTool/Java stack." \
        "calibre|E-book library manager and converter.|Large dependency set; handles many formats." \
        "notion|Notion desktop client.|AUR package; Electron-based." \
        "atom-ng-bin|Community continuation of Atom editor.|AUR binary; Electron-based." \
        "sublime-text-4|Fast proprietary text/code editor.|AUR package/repository availability required." \
        "filezilla|FTP/SFTP client.|No special runtime dependency beyond network access." \
        "qbittorrent|BitTorrent client with Qt interface.|Network/firewall rules may affect seeding." \
        "transmission-gtk|Lightweight BitTorrent client.|GTK interface."
}

apps_communication() {
    install_described_pkgs "System Apps — Communication, Meetings and Mail" \
        "zoom|Zoom video conferencing client.|AUR package; camera/microphone permissions required." \
        "webex-bin|Cisco Webex desktop client.|AUR binary package." \
        "thunderbird|Email, calendar, and contacts client.|Official repo." \
        "evolution|GNOME email/calendar/groupware client.|Integrates with GNOME keyring/online accounts." \
        "mailspring-bin|Modern email client.|AUR binary; account sync may require Mailspring services."
}

apps_development() {
    install_described_pkgs "System Apps — Development and Engineering" \
        "intellij-idea-community-edition|JetBrains IntelliJ IDEA Community IDE for JVM development.|Requires Java runtime/toolchain for projects." \
        "pycharm-community-edition|JetBrains PyCharm Community IDE for Python.|Requires Python interpreter for projects." \
        "kdevelop|KDE IDE for C/C++ and other languages.|Best with compilers/build tools installed." \
        "meld|Visual diff and merge tool.|Useful for source code/file comparison." \
        "the_platinum_searcher-bin|Fast code search utility similar to ag/pt.|AUR binary package." \
        "openscad|Programmatic 3D CAD modeler.|Useful for CAD/STL generation." \
        "dconf-editor|GUI editor for GNOME/dconf settings.|Relevant for GTK/GNOME app settings." \
        "leafpad|Simple lightweight text editor.|Legacy GTK app." \
        "github-desktop-bin|GitHub Desktop client.|AUR binary; requires git account/workflow." \
        "gitahead|Graphical Git client.|Uses git under the hood."
}

apps_screenshot_recording() {
    install_described_pkgs "System Apps — Screenshots and Screen Recording" \
        "flameshot|Screenshot and annotation tool.|Works best with proper Wayland/X11 portal support." \
        "simplescreenrecorder|Screen recording application.|X11 support stronger than Wayland." \
        "scrot|Command-line screenshot utility.|Primarily X11-oriented." \
        "kazam|Simple screen recorder/screenshot app.|Older GTK app; Wayland support may be limited." \
        "peek|Simple animated GIF screen recorder.|Wayland support may vary." \
        "replay-sorcery|Instant replay screen recorder.|Requires GPU/video encoding support for best results."
}

apps_creative_multimedia() {
    install_described_pkgs "System Apps — Creative, Graphics, Audio and Video" \
        "inkscape|Vector graphics editor.|No special dependency beyond graphics stack." \
        "blender|3D creation suite for modeling, rendering, animation, and VFX.|GPU acceleration depends on GPU drivers." \
        "pinta|Simple paint/image editor.|Good lightweight alternative for quick edits." \
        "krita|Digital painting and illustration application.|Tablet support depends on input driver setup." \
        "scribus|Desktop publishing/layout application.|Useful for print/PDF design." \
        "kdenlive|Non-linear video editor from KDE.|Uses FFmpeg/MLT stack." \
        "pitivi|GNOME video editor.|Uses GStreamer multimedia stack." \
        "openshot|Beginner-friendly video editor.|Python/Qt based." \
        "shotcut|Cross-platform video editor.|Uses FFmpeg/MLT stack." \
        "handbrake|Video transcoder.|Uses codec libraries; GPU encoding depends on driver support." \
        "obs-studio|Streaming and recording studio.|GPU encoder support depends on AMD/NVIDIA/Intel driver stack." \
        "audacity|Audio recording and editing application.|Audio backend depends on PipeWire/Pulse/JACK setup." \
        "lmms|Music production workstation.|Audio/MIDI setup may need tuning." \
        "digikam|Photo management and RAW workflow application.|Large KDE dependency set." \
        "darktable|RAW photo editor and workflow tool.|OpenCL acceleration depends on GPU/OpenCL stack." \
        "synfigstudio|2D animation studio.|No special runtime dependency." \
        "gwenview|KDE image viewer.|Useful with KDE thumbnail plugins." \
        "kamoso|KDE webcam/camera application.|Requires working camera device." \
        "youtube-dl|Command-line video downloader.|Site support changes often; yt-dlp may be a better maintained alternative." \
        "vlc|Media player with broad codec support.|Extra codecs improve format support." \
        "spotify|Spotify desktop client.|AUR package; account required."

    if ask "Install DaVinci Resolve? Heavy app; check GPU/OpenCL/ROCm/NVIDIA setup first."; then
        install_described_pkgs "System Apps — DaVinci Resolve" \
            "davinci-resolve|Professional video editing/color grading suite.|Requires supported GPU drivers and OpenCL/CUDA stack; AMD support can be sensitive."
    fi
}

apps_kde_suite() {
    install_described_pkgs "System Apps — KDE Application Suites" \
        "kde-multimedia-meta|KDE multimedia application meta-package.|Installs a broad set of KDE multimedia apps." \
        "kde-system-meta|KDE system tools meta-package.|Installs a broad set of KDE system utilities." \
        "kde-utilities-meta|KDE utilities meta-package.|Installs many KDE desktop utilities." \
        "kde-pim-meta|KDE personal information management suite.|Large mail/calendar/contact dependency set." \
        "kde-network-meta|KDE networking applications meta-package.|Installs KDE network tools." \
        "kde-sdk-meta|KDE software development tools meta-package.|Large KDE development tooling set."
}

apps_language_tools() {
    install_described_pkgs "System Apps — Language, Spell Check and Java Runtime" \
        "aspell-en|English dictionary for GNU Aspell.|Used by apps that support Aspell." \
        "hunspell-en_US|US English dictionary for Hunspell.|Used by LibreOffice, browsers, editors." \
        "libmythes|Thesaurus library.|Used by office/editor apps." \
        "mythes-en|English thesaurus data.|Requires libmythes." \
        "languagetool|Grammar and style checker.|Java runtime required." \
        "enchant|Spell-checking provider abstraction library.|Used by GTK/desktop apps." \
        "pkgstats|Arch package statistics reporting tool.|Optional; sends anonymous package stats if enabled." \
        "gst-plugins-good|Good-quality GStreamer plugins.|Used by media apps." \
        "gst-libav|FFmpeg-based GStreamer plugin.|Improves media format support." \
        "icedtea-web|Open-source Java Web Start/browser plugin replacement.|Legacy Java web app support." \
        "jre8-openjdk|OpenJDK 8 Java runtime.|Needed by some older Java apps."
}

apps_gaming() {
    install_described_pkgs "System Apps — Gaming Stack" \
        "steam-native-runtime|Steam client using native Arch libraries.|Requires multilib and GPU drivers for best compatibility." \
        "lutris|Game manager for Wine, emulators, and native games.|Wine/DXVK dependencies vary by game." \
        "heroic-games-launcher|Epic/GOG game launcher alternative.|Electron-based; uses Wine/Proton for Windows games." \
        "bottles|Wine environment manager.|Requires Wine-related runtime components." \
        "playonlinux|Wine prefix manager for Windows applications/games.|Legacy; Bottles/Lutris often better." \
        "gamehub|Game library manager.|AUR package." \
        "minigalaxy|GOG game downloader/client.|GOG account needed." \
        "itch-bin|itch.io desktop app.|AUR binary package." \
        "dxvk-mingw-git|DirectX-to-Vulkan translation layer for Wine.|Requires Vulkan-capable GPU drivers." \
        "boxtron|Steam Play compatibility tool for DOSBox games.|Works with Steam compatibility tool setup." \
        "mangohud|Vulkan/OpenGL performance overlay.|Requires compatible graphics stack." \
        "goverlay|GUI configuration tool for MangoHud and vkBasalt.|Requires MangoHud for overlay config." \
        "gamemode|Performance tuning daemon for games.|Service/user permissions may need setup." \
        "displaycal|Display calibration and profiling tool.|Requires colorimeter for actual calibration." \
        "droidcam|Use Android phone as webcam.|Requires phone app and matching kernel/video setup." \
        "fastgame-git|Gaming performance helper.|AUR package; review behavior before relying on it." \
        "rare|Alternative Epic Games launcher.|AUR package." \
        "playitslowly|Audio slow-down/transcription practice tool.|Useful for audio learning, not gaming-specific."
}

apps_file_storage() {
    install_described_pkgs "System Apps — File, Archive and Storage Utilities" \
        "thunar|Lightweight file manager.|Can coexist with Dolphin." \
        "thunar-archive-plugin|Archive integration for Thunar.|Requires Thunar and archive backend." \
        "thunar-volman|Removable media management for Thunar.|Requires Thunar." \
        "ark|KDE archive manager.|Works with archive backend packages." \
        "file-roller|GNOME archive manager.|Alternative to Ark." \
        "p7zip|7z archive support.|Backend for archive managers." \
        "p7zip-gui|Graphical 7z archive interface.|AUR package." \
        "unrar|RAR extraction utility.|Needed for RAR archives." \
        "unace|ACE archive extraction utility.|Legacy archive format support." \
        "zip|ZIP archive creation utility.|Common archive tool." \
        "unzip|ZIP archive extraction utility.|Common archive tool." \
        "cabextract|Microsoft CAB archive extractor.|Useful for driver/font extraction." \
        "uudeview|UUencoded file decoder.|Legacy file decoding utility." \
        "lzop|LZO compression utility.|Specialized compression format support." \
        "cryfs|Encrypted cloud/file-system overlay.|Requires FUSE." \
        "fuse2|FUSE 2 userspace filesystem support.|Needed by some AppImages and legacy FUSE apps." \
        "fuse3|FUSE 3 userspace filesystem support.|Modern FUSE apps." \
        "ntfs-3g|NTFS read/write filesystem driver.|Needed for Windows drives." \
        "fuse-exfat|exFAT FUSE filesystem support.|Modern kernels also have native exFAT." \
        "dosfstools|FAT filesystem utilities.|Useful for USB/EFI partitions." \
        "cifs-utils|SMB/CIFS mount utilities.|Needed to mount Windows/Samba shares." \
        "smbclient|SMB/CIFS client tools.|Useful for Windows/Samba shares." \
        "os-prober|Detects other OS installs for bootloader config.|Useful with GRUB multi-boot."
}

apps_system_tools() {
    install_described_pkgs "System Apps — System Monitoring, Maintenance and Hardware Tools" \
        "htop|Interactive process viewer.|No special dependency." \
        "bpytop|Resource monitor with rich terminal UI.|Python-based." \
        "lm_sensors|Hardware sensor detection/readout.|Run sensors-detect after install if needed." \
        "lshw|Hardware inventory utility.|Run with sudo for full detail." \
        "inxi|System information script.|Useful for support/debugging." \
        "cpu-x|CPU/system information GUI.|Linux alternative to CPU-Z." \
        "cpufetch-git|CPU information fetch tool.|AUR package." \
        "s-tui|Terminal CPU stress/temperature monitor.|Works best with sensors configured." \
        "radeontop-git|AMD GPU utilization monitor.|Requires AMD GPU." \
        "bleachbit|System cleanup tool.|Use carefully; can delete browser/app data." \
        "stacer-bin|System optimizer/monitor GUI.|AUR binary; use cleanup features carefully." \
        "auto-cpufreq|Automatic CPU frequency and power optimizer.|Conflicts conceptually with some power-profile tools; review before enabling service." \
        "downgrade|Utility to downgrade Arch packages.|Requires package cache or Arch archive access." \
        "arch-audit|Checks installed packages for known vulnerabilities.|Uses Arch security data." \
        "ventoy-bin|Bootable USB multiboot creator.|Needs removable drive; destructive if wrong disk selected." \
        "hardcode-fixer-git|Fixes hardcoded tray icon paths in some apps.|AUR package; use selectively." \
        "ocs-url|Helper for installing items from OpenDesktop/Pling.|AUR package; review downloads before installing." \
        "variety|Wallpaper changer.|Can download wallpapers from online sources." \
        "redshift|Adjusts screen color temperature.|May be less relevant on Wayland/KDE Night Color." \
        "rsync|Fast file synchronization and backup utility.|Useful for backups and migration." \
        "partitionmanager|KDE partition manager.|Requires admin privileges; dangerous if used carelessly." \
        "bitwarden|Password manager desktop app.|Account required; browser extension installed separately." \
        "piper|GUI for configuring gaming mice.|Requires libratbag-supported device." \
        "gnome-keyring|Secret storage service used by many desktop apps.|Useful even outside GNOME." \
        "wireshark-qt|Network protocol analyzer GUI.|Add user to wireshark group if capture permission needed."
}

apps_network_tools() {
    install_described_pkgs "System Apps — Network Utilities" \
        "traceroute|Network route diagnostic utility.|No special dependency." \
        "dnsutils|DNS lookup tools such as dig/nslookup.|Useful for DNS troubleshooting." \
        "speedtest-cli|Command-line internet speed test utility.|Network access required." \
        "wavemon|Wireless signal monitoring utility.|Requires Wi-Fi interface." \
        "net-tools|Legacy tools such as ifconfig/netstat.|Modern alternatives are ip/ss." \
        "w3m|Terminal web browser.|Useful for quick CLI browsing." \
        "curl|Command-line data transfer utility.|Base scripting/networking tool." \
        "jq|Command-line JSON processor.|Useful for APIs/scripts." \
        "yajl|JSON parsing library/tools.|Dependency/helper for JSON workflows." \
        "ffmpegthumbs|Video thumbnailer for KDE/Dolphin.|Requires FFmpeg libraries." \
        "kde-gtk-config|KDE settings bridge for GTK app appearance.|Requires KDE Plasma." \
        "kdeconnect|Phone/desktop integration tool.|Firewall ports may need opening." \
        "dolphin-plugins|Extra Dolphin file manager plugins.|Requires Dolphin/KDE." \
        "kdegraphics-thumbnailers|Additional KDE thumbnailers.|Requires KDE file manager integration." \
        "kimageformats|Extra image format plugins for KDE/Qt apps.|Improves image format support." \
        "qt5-imageformats|Extra Qt5 image format plugins.|Helps older Qt5 apps." \
        "kdesdk-thumbnailers|Source/design thumbnailers for KDE.|Requires KDE thumbnail infrastructure." \
        "imagemagick|Image conversion and manipulation toolkit.|Powerful CLI; be careful with untrusted files." \
        "okular|KDE document/PDF viewer.|Useful general document viewer." \
        "evince|GNOME document/PDF viewer.|Alternative document viewer." \
        "dupeguru|Duplicate file finder.|Review results before deleting files." \
        "fluent-reader|RSS/news reader.|AUR package." \
        "4kvideodownloader|Video downloader GUI.|AUR package; site support may change."
}

apps_codecs() {
    install_described_pkgs "System Apps — Codecs and Media Format Support" \
        "a52dec|ATSC A/52 audio decoder.|Codec support." \
        "faad2|AAC decoder.|Codec support." \
        "faac|AAC encoder.|Codec support." \
        "flac|FLAC audio codec/tools.|Lossless audio support." \
        "jasper|JPEG 2000 codec library.|Image codec support." \
        "lame|MP3 encoder.|Audio codec support." \
        "libdca|DTS Coherent Acoustics decoder.|Audio codec support." \
        "libdv|DV video codec library.|Legacy video support." \
        "libmad|MPEG audio decoder library.|Legacy audio codec support." \
        "libmpeg2|MPEG-2 video decoder library.|Video codec support." \
        "libxv|XVideo extension library.|Legacy video output support." \
        "wavpack|WavPack audio codec/tools.|Lossless audio support." \
        "x264|H.264 encoder library.|Video encoding support." \
        "x265|H.265/HEVC encoder library.|Video encoding support." \
        "xvidcore|Xvid MPEG-4 codec.|Legacy video codec support." \
        "taglib|Audio metadata/tagging library.|Used by media players/managers."
}

apps_virtualization() {
    header "System Apps — Virtual Machines"
    if ask "Install VirtualBox?"; then
        install_described_pkgs "VirtualBox" \
            "virtualbox-host-dkms|VirtualBox host kernel modules built through DKMS.|Requires matching kernel headers." \
            "virtualbox|VirtualBox virtualization application.|Requires kernel modules loaded." \
            "virtualbox-guest-iso|Guest additions ISO for VMs.|Useful for guest integration." \
            "virtualbox-sdk|VirtualBox software development kit.|Needed only for development/automation." \
            "virtualbox-ext-vnc|VNC extension for VirtualBox.|Optional remote display support." \
            "virtualbox-ext-oracle|Oracle VirtualBox extension pack.|Licensing applies; AUR package."
        sudo gpasswd -a "$CURRENT_USER" vboxusers
        try sudo modprobe vboxdrv
        try sudo systemctl start vboxweb.service
        VBoxManage setextradata global GUI/SuppressMessages "all" 2>/dev/null || true
    fi

    if ask "Install VMware Workstation?"; then
        install_described_pkgs "VMware Workstation" \
            "vmware-keymaps|Keyboard map files for VMware.|Dependency/helper for VMware." \
            "vmware-workstation|VMware Workstation virtualization application.|Requires kernel modules and services."
        try sudo modprobe vmw_vmci vmmon
        sudo systemctl enable vmware-networks.service
        sudo systemctl enable vmware-usbarbitrator.service
        if ask "Apply AMD GPU blacklist fix for VMware?"; then
            VMWARE_PREFS="$HOME/.vmware/preferences"
            mkdir -p "$HOME/.vmware"
            if grep -q "mks.gl.allowBlacklistedDrivers" "$VMWARE_PREFS" 2>/dev/null; then
                warn "AMD GPU fix already present — skipping."
            else
                echo 'mks.gl.allowBlacklistedDrivers = "TRUE"' >> "$VMWARE_PREFS"
                success "AMD GPU fix applied."
            fi
        fi
    fi
}

apps_mobile_kde_extensions() {
    install_described_pkgs "System Apps — Mobile Device and KDE Service Extensions" \
        "ifuse|Mount iPhone/iOS filesystem through FUSE.|Requires libimobiledevice/usbmuxd and trusted device pairing." \
        "usbmuxd|USB multiplexing daemon for iOS devices.|Service needed for iPhone communication." \
        "libplist|Apple property list library.|Dependency for iOS tooling." \
        "libimobiledevice|Library/tools for iOS device communication.|Requires device trust pairing." \
        "shotwell|Photo manager/importer.|Useful for importing phone photos." \
        "kf5-servicemenus-clamtkscan|KDE service menu to scan files with ClamTK.|Requires ClamTK/ClamAV." \
        "kf6-servicemenus-pdftools|KDE 6 PDF tools service menu.|Requires KDE service menu support." \
        "kf6-servicemenus-rootactions|KDE 6 root actions service menu.|Use carefully; elevated file actions are risky." \
        "jamesdsp-git|Audio DSP/effects processor.|AUR package; PipeWire/Pulse routing may need setup." \
        "kde-material-you-colors|KDE Material You color integration.|AUR package; KDE Plasma required."

    mkdir -p "$HOME/iPhone"
    info "iPhone mount point created at ~/iPhone. To mount: unlock phone, trust computer, run: ifuse ~/iPhone"
}

apps_benchmarking() {
    install_described_pkgs "System Apps — Benchmarking" \
        "hardinfo|Hardware information and benchmark tool.|GTK app." \
        "blender-benchmark|Official Blender benchmark launcher.|GPU results depend on graphics drivers." \
        "geekbench|Cross-platform CPU/GPU benchmark.|AUR package; license/account may apply." \
        "gputest|GPU stress/benchmark tests.|Requires working OpenGL/Vulkan stack." \
        "phoronix-test-suite|Comprehensive Linux benchmark framework.|Downloads benchmark tests/data as needed."
}

# =============================================================================
# SYSTEM MAINTENANCE & AUDIT
# =============================================================================

section_maintenance() {
    header "System Maintenance"
    if ask "Remove orphaned packages now?"; then
        ORPHANS=$(paru -Qtdq 2>/dev/null || yay -Qtdq 2>/dev/null || pacman -Qtdq 2>/dev/null || true)
        if [[ -n "$ORPHANS" ]]; then
            if command_exists paru; then echo "$ORPHANS" | paru -Rns --noconfirm -
            elif command_exists yay; then echo "$ORPHANS" | yay -Rns --noconfirm -
            else echo "$ORPHANS" | sudo pacman -Rns --noconfirm -
            fi
            success "Orphaned packages removed."
        else
            info "No orphaned packages found."
        fi
    fi

    info "Checking failed systemd services."
    sudo systemctl --failed || true
    info "Recent system errors from last boot."
    sudo journalctl -p 3 -xb --no-pager | tail -30 || true
}

section_lynis() {
    header "System Audit — Lynis"
    if [[ ! -d /opt/lynis ]]; then
        info "Cloning Lynis into /opt/lynis."
        sudo git clone https://github.com/CISOfy/lynis.git /opt/lynis
    else
        info "Lynis already present. Pulling latest."
        sudo git -C /opt/lynis pull
    fi
    info "Running Lynis audit."
    cd /opt/lynis && sudo ./lynis audit system
    cd "$OLDPWD"
}

# =============================================================================
# MENUS
# =============================================================================

SECTIONS=(
    "1:System Install — Base Utilities and Maintenance"
    "2:System Install — Firmware Warning Fixes"
    "3:System Install — Storage Mounts"
    "4:System Install — User Group Permissions"
    "5:System Drivers Installation — AMD GPU"
    "6:System Drivers Installation — NVIDIA Primary GPU Laptop Mode"
    "7:System Drivers Installation — Bluetooth, Printing, Audio, Wi-Fi Hotspot"
    "8:System Settings — Networking and Security Tools"
    "9:System Settings — Antivirus"
    "10:System Settings — Firewall"
    "11:System Settings — AppArmor"
    "12:System Settings — Shell"
    "13:System Settings — Fastfetch"
    "14:System Settings — Face ID Login"
    "15:System Settings — Fonts"
    "16:System Settings — Icons and Cursors"
    "17:System Settings — Boot Theme"
    "18:System Apps — Browsers"
    "19:System Apps — Office, Documents and Productivity"
    "20:System Apps — Communication, Meetings and Mail"
    "21:System Apps — Development and Engineering"
    "22:System Apps — Screenshots and Recording"
    "23:System Apps — Creative, Graphics, Audio and Video"
    "24:System Apps — KDE Application Suites"
    "25:System Apps — Language, Spell Check and Java"
    "26:System Apps — Gaming"
    "27:System Apps — File, Archive and Storage Utilities"
    "28:System Apps — System Monitoring and Hardware Tools"
    "29:System Apps — Network Utilities and KDE Desktop Helpers"
    "30:System Apps — Codecs and Media Format Support"
    "31:System Apps — Virtual Machines"
    "32:System Apps — Mobile Device and KDE Service Extensions"
    "33:System Apps — Benchmarking"
    "34:System Maintenance"
    "35:System Audit — Lynis"
)

print_menu() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "  ██████╗ █████╗  ██████╗██╗  ██╗██╗   ██╗ ██████╗ ███████╗"
    echo "  ██╔════╝██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝██╔═══██╗██╔════╝"
    echo "  ██║     ███████║██║     ███████║ ╚████╔╝ ██║   ██║███████╗"
    echo "  ██║     ██╔══██║██║     ██╔══██║  ╚██╔╝  ██║   ██║╚════██║"
    echo "  ╚██████╗██║  ██║╚██████╗██║  ██║   ██║   ╚██████╔╝███████║"
    echo "   ╚═════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚══════╝"
    echo -e "${RESET}"
    echo -e "${BOLD}  Structured Post-Install Setup Script${RESET}  ${DIM}User: $CURRENT_USER${RESET}"
    echo -e "${DIM}  ─────────────────────────────────────────────────────${RESET}"
    echo ""

    for entry in "${SECTIONS[@]}"; do
        local num="${entry%%:*}"
        local label="${entry#*:}"
        printf "  ${CYAN}%2s${RESET}. %s\n" "$num" "$label"
    done

    echo ""
    echo -e "  ${CYAN} A${RESET}. Run ALL sections"
    echo -e "  ${RED} Q${RESET}. Quit"
    echo ""
    echo -e "${DIM}  You can enter multiple numbers separated by spaces, e.g. 1 5 18 23${RESET}"
    echo ""
}

run_section() {
    case "$1" in
        1) section_base_install ;;
        2) section_firmware ;;
        3) section_mount_drive ;;
        4) section_groups ;;
        5) section_amd_gpu ;;
        6) section_nvidia_primary ;;
        7) section_bluetooth_printing_audio ;;
        8) section_networking_security ;;
        9) section_antivirus ;;
        10) section_firewall ;;
        11) section_apparmor ;;
        12) section_shell ;;
        13) section_fastfetch ;;
        14) section_howdy ;;
        15) section_fonts ;;
        16) section_icons_cursors ;;
        17) section_boot_theme ;;
        18) apps_browsers ;;
        19) apps_office_productivity ;;
        20) apps_communication ;;
        21) apps_development ;;
        22) apps_screenshot_recording ;;
        23) apps_creative_multimedia ;;
        24) apps_kde_suite ;;
        25) apps_language_tools ;;
        26) apps_gaming ;;
        27) apps_file_storage ;;
        28) apps_system_tools ;;
        29) apps_network_tools ;;
        30) apps_codecs ;;
        31) apps_virtualization ;;
        32) apps_mobile_kde_extensions ;;
        33) apps_benchmarking ;;
        34) section_maintenance ;;
        35) section_lynis ;;
        *) warn "Unknown section: $1" ;;
    esac
}

main() {
    while true; do
        print_menu
        prompt "Enter your selection: "
        read -r -a CHOICES

        [[ ${#CHOICES[@]} -eq 0 ]] && continue

        if [[ "${CHOICES[0],,}" == "q" ]]; then
            echo ""
            info "Exiting. Log saved to $LOG_FILE"
            break
        fi

        if [[ "${CHOICES[0],,}" == "a" ]]; then
            warn "Run ALL will prompt inside each section. This is still a large install."
            if ask "Proceed with all sections?"; then
                for entry in "${SECTIONS[@]}"; do
                    num="${entry%%:*}"
                    run_section "$num"
                done
                success "All sections complete. A reboot is recommended."
            fi
            prompt "Press Enter to return to menu..."
            read -r
            continue
        fi

        for choice in "${CHOICES[@]}"; do
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= 35 )); then
                run_section "$choice"
            else
                warn "Invalid selection: $choice — skipping."
            fi
        done

        echo ""
        prompt "Press Enter to return to menu..."
        read -r
    done
}

main
