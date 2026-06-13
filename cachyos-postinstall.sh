#!/usr/bin/env bash
# =============================================================================
# CachyOS Post-Install Setup Script
# Interactive modular configuration for a fresh CachyOS install
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

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${BLUE}═══ $* ═══${RESET}\n"; }
prompt()  { echo -e "${YELLOW}[INPUT]${RESET} $*"; }

# Log file
LOG_FILE="$HOME/cachyos-postinstall.log"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Logging to $LOG_FILE"

# -----------------------------------------------------------------------------
# Root check — most sections need sudo but we don't run the whole script as root
# -----------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root. It will call sudo where needed."
    exit 1
fi

# Verify sudo access upfront so we don't get prompted mid-section
sudo -v || { error "Could not obtain sudo. Exiting."; exit 1; }

# Keep sudo alive throughout the script
(while true; do sudo -n true; sleep 50; done) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT

# -----------------------------------------------------------------------------
# Detect the current username
# -----------------------------------------------------------------------------
CURRENT_USER="${USER:-$(whoami)}"
info "Detected user: ${BOLD}$CURRENT_USER${RESET}"

# -----------------------------------------------------------------------------
# Helper: ask yes/no
# -----------------------------------------------------------------------------
ask() {
    # Usage: ask "Question?" && do_something
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
# Helper: run with error tolerance (warn on failure, don't exit)
# -----------------------------------------------------------------------------
try() {
    if ! "$@"; then
        warn "Command failed (non-fatal): $*"
    fi
}

# =============================================================================
# SECTION FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# 1. AMD GPU Drivers
# -----------------------------------------------------------------------------
section_amd_gpu() {
    header "AMD GPU Drivers"

    info "Installing X.org 2D acceleration driver..."
    sudo pacman -S --needed --noconfirm xf86-video-amdgpu

    info "Installing Mesa OpenGL..."
    sudo pacman -S --needed --noconfirm mesa lib32-mesa

    info "Installing Vulkan drivers (Mesa + AMD proprietary)..."
    sudo pacman -S --needed --noconfirm vulkan-radeon lib32-vulkan-radeon

    if ask "Install AMD proprietary Vulkan drivers (amdvlk)? Not required for most users."; then
        sudo pacman -S --needed --noconfirm vulkan-amdgpu-pro amdvlk
        sudo pacman -S --needed --noconfirm lib32-vulkan-amdgpu-pro lib32-amdvlk
    fi

    info "Installing hardware video decode support..."
    sudo pacman -S --needed --noconfirm libva-mesa-driver mesa-vdpau

    if ask "Install OpenCL support (legacy + ROCm)?"; then
        paru -S --needed --noconfirm opencl-legacy-amdgpu-pro ocl-icd clinfo
        paru -S --needed --noconfirm lib32-opencl-legacy-amdgpu-pro lib32-ocl-icd
        paru -S --needed --noconfirm rocm-opencl-runtime
    fi

    if ask "Install AMF encoder and image format libraries (useful for OBS/FFmpeg)?"; then
        paru -S --needed --noconfirm amf-amdgpu-pro
        paru -S --needed --noconfirm openjpeg libwebp libavif libheif libvpx
    fi

    success "AMD GPU drivers section complete."
}

# -----------------------------------------------------------------------------
# 2. Networking and Security
# -----------------------------------------------------------------------------
section_networking() {
    header "Networking and Security"

    info "Installing pacman-contrib and enabling cache cleanup timer..."
    sudo pacman -S --needed --noconfirm pacman-contrib
    sudo systemctl enable paccache.timer

    if ask "Install security/network monitoring tools (lkrg, usbguard, bettercap, nmap, portmaster, snort)?"; then
        paru -S --needed --noconfirm lkrg-dkms usbguard bettercap dsniff nmap smb4k tcpdump portmaster
        yay -S --needed --noconfirm snort
    fi

    if ask "Install extended NetworkManager VPN plugins (OpenVPN, WireGuard, StrongSwan, PPTP, etc.)?"; then
        paru -S --needed --noconfirm dhclient dnsmasq gpsd libnma network-manager-sstp \
            networkmanager-fortisslvpn networkmanager-openconnect \
            networkmanager-openvpn networkmanager-pptp networkmanager-strongswan \
            networkmanager-vpnc nm-cloud-setup openfortivpn openldap openresolv \
            openvpn pkcs11-helper pps-tools pptpclient rp-pppoe sstp-client \
            stoken strongswan tcl unixodbc usb_modeswitch vpnc wireguard-tools xl2tpd
    fi

    success "Networking section complete."
}

# -----------------------------------------------------------------------------
# 3. Antivirus (ClamAV)
# -----------------------------------------------------------------------------
section_antivirus() {
    header "Antivirus Setup (ClamAV)"

    info "Installing ClamAV and GUI..."
    paru -S --needed --noconfirm clamav clamtk

    info "Updating virus definitions (this may take a moment)..."
    sudo freshclam || warn "freshclam failed — may need to run manually after service starts."

    info "Enabling ClamAV services..."
    sudo systemctl enable --now clamav-freshclam.service
    sudo systemctl enable --now clamav-daemon.service

    success "ClamAV setup complete."
}

# -----------------------------------------------------------------------------
# 4. Firewall (UFW)
# -----------------------------------------------------------------------------
section_firewall() {
    header "Firewall Configuration (UFW)"

    info "Installing UFW and GUFW..."
    sudo pacman -S --needed --noconfirm ufw gufw

    info "Enabling UFW..."
    sudo ufw enable

    if ask "Allow KDE Connect ports (1714-1764 UDP/TCP)?"; then
        sudo ufw allow 1714:1764/udp
        sudo ufw allow 1714:1764/tcp
        sudo ufw reload
        success "KDE Connect ports opened."
    fi

    success "Firewall section complete."
}

# -----------------------------------------------------------------------------
# 5. AppArmor
# -----------------------------------------------------------------------------
section_apparmor() {
    header "AppArmor (Mandatory Access Control)"

    info "Installing AppArmor and community profiles..."
    paru -S --needed --noconfirm apparmor apparmor.d-git

    info "Enabling AppArmor service..."
    sudo systemctl enable --now apparmor.service

    success "AppArmor enabled."
}

# -----------------------------------------------------------------------------
# 6. Virtual Machines
# -----------------------------------------------------------------------------
section_vms() {
    header "Virtual Machines"

    if ask "Install VirtualBox?"; then
        info "Installing VirtualBox..."
        paru -S --needed --noconfirm virtualbox-host-dkms virtualbox virtualbox-guest-iso \
            virtualbox-sdk virtualbox-ext-vnc virtualbox-ext-oracle

        info "Adding $CURRENT_USER to vboxusers group..."
        sudo gpasswd -a "$CURRENT_USER" vboxusers

        info "Loading vboxdrv kernel module..."
        sudo modprobe vboxdrv

        try sudo systemctl start vboxweb.service

        VBoxManage setextradata global GUI/SuppressMessages "all" 2>/dev/null || true
        success "VirtualBox installed."
    fi

    if ask "Install VMware Workstation?"; then
        info "Installing VMware Workstation..."
        paru -S --needed --noconfirm vmware-keymaps vmware-workstation

        info "Loading VMware kernel modules..."
        sudo modprobe vmw_vmci vmmon

        sudo systemctl enable vmware-networks.service
        sudo systemctl enable vmware-usbarbitrator.service

        if ask "Apply AMD GPU blacklist fix for VMware?"; then
            VMWARE_PREFS="$HOME/.vmware/preferences"
            mkdir -p "$HOME/.vmware"
            if grep -q "mks.gl.allowBlacklistedDrivers" "$VMWARE_PREFS" 2>/dev/null; then
                warn "AMD GPU fix already present in $VMWARE_PREFS — skipping."
            else
                echo 'mks.gl.allowBlacklistedDrivers = "TRUE"' >> "$VMWARE_PREFS"
                success "AMD GPU fix applied."
            fi
        fi

        success "VMware Workstation installed."
    fi
}

# -----------------------------------------------------------------------------
# 7. Kernel Firmware Warnings Fix
# -----------------------------------------------------------------------------
section_firmware() {
    header "Kernel Firmware Warnings Fix"

    info "Installing missing firmware packages..."
    paru -S --needed --noconfirm aic94xx-firmware wd719x-firmware upd72020x-fw

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

# -----------------------------------------------------------------------------
# 8. Storage and Drive Utilities
# -----------------------------------------------------------------------------
section_storage() {
    header "Storage and Drive Utilities"

    info "Installing core utilities..."
    sudo pacman -S --needed --noconfirm realtime-privileges lolcat fastfetch fwupd \
        power-profiles-daemon fish

    info "Enabling periodic TRIM for SSDs..."
    sudo systemctl enable fstrim.timer

    if ask "Set vm.swappiness=150 (CachyOS zram tuning)?"; then
        SYSCTL_CONF="/etc/sysctl.d/100-arch.conf"
        if grep -q "^vm.swappiness" "$SYSCTL_CONF" 2>/dev/null; then
            sudo sed -i 's/^vm.swappiness=.*/vm.swappiness=150/' "$SYSCTL_CONF"
        else
            echo "vm.swappiness=150" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        fi
        success "vm.swappiness set to 150."
    fi

    if ask "Mount an additional drive via fstab?"; then
        info "Available block devices:"
        sudo blkid
        echo ""
        prompt "Enter the UUID of the drive to mount (from the list above): "
        read -r DRIVE_UUID
        prompt "Enter the mount point (e.g. /LinuxData): "
        read -r MOUNT_POINT
        prompt "Enter the filesystem type (e.g. btrfs, ext4): "
        read -r FS_TYPE

        if [[ -z "$DRIVE_UUID" || -z "$MOUNT_POINT" || -z "$FS_TYPE" ]]; then
            warn "Incomplete input — skipping fstab entry."
        else
            sudo mkdir -p "$MOUNT_POINT"
            FSTAB_ENTRY="UUID=$DRIVE_UUID $MOUNT_POINT    $FS_TYPE    defaults,noatime 0 0"
            if grep -q "$DRIVE_UUID" /etc/fstab 2>/dev/null; then
                warn "UUID already present in /etc/fstab — skipping."
            else
                echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null
                success "fstab entry added: $FSTAB_ENTRY"
                info "Run 'sudo mount -a' to mount now, or reboot."
            fi
        fi
    fi

    success "Storage section complete."
}

# -----------------------------------------------------------------------------
# 9. User Group Permissions
# -----------------------------------------------------------------------------
section_groups() {
    header "User Group Permissions"

    info "Adding $CURRENT_USER to essential system groups..."
    sudo usermod -aG audio,video,storage,network,optical,power,sys,rfkill,wheel,users,realtime "$CURRENT_USER"

    success "Groups updated. Log out and back in for group changes to take effect."
}

# -----------------------------------------------------------------------------
# 10. Bluetooth, Printing, Audio
# -----------------------------------------------------------------------------
section_bluetooth_printing_audio() {
    header "Bluetooth, Printing, and Audio"

    if ask "Install Bluetooth extras (bluez-hid2hci, plugins)?"; then
        paru -S --needed --noconfirm bluez-hid2hci bluez-plugins python-prctl
    fi

    if ask "Install full CUPS printing stack with HP printer support?"; then
        paru -S --needed --noconfirm a2ps bluez-cups colord-sane cups-pk-helper hplip \
            libvncserver noto-fonts-emoji paper perl-alien-build perl-alien-libxml2 \
            perl-capture-tiny perl-dbi perl-ffi-checklib perl-file-chdir perl-file-which \
            perl-ipc-run perl-path-tiny perl-xml-libxml perl-xml-sax perl-xml-sax-base \
            psutils python-pysmbc python-reportlab sane-airscan splix vde2
    fi

    if ask "Install/reinstall PipeWire audio stack?"; then
        warn "CachyOS ships PipeWire pre-installed. Only do this if you need to reinstall it."
        paru -S --needed --noconfirm pipewire pipewire-alsa pipewire-jack pipewire-jack-dropin \
            pipewire-media-session pipewire-pulse pipewire-zeroconf plasma-pa \
            gst-plugin-pipewire wireplumber
    fi

    if ask "Install Wi-Fi hotspot tools (hostapd, linux-wifi-hotspot)?"; then
        paru -S --needed --noconfirm ethtool hostapd linux-wifi-hotspot wireless_tools
    fi

    success "Bluetooth/Printing/Audio section complete."
}

# -----------------------------------------------------------------------------
# 11. Shell Configuration (ZSH)
# -----------------------------------------------------------------------------
section_zsh() {
    header "Shell Configuration (ZSH)"

    warn "CachyOS defaults to Fish shell. Only proceed if you specifically want ZSH."
    if ask "Install ZSH with Powerlevel10k and oh-my-zsh?"; then
        paru -S --needed --noconfirm zsh zsh-completions zsh-syntax-highlighting \
            zsh-theme-powerlevel10k-git arcolinux-zsh-git oh-my-zsh-git \
            oh-my-zsh-powerline-theme-git

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
    fi
}

# -----------------------------------------------------------------------------
# 12. System Customization
# -----------------------------------------------------------------------------
section_customization() {
    header "System Customization"

    if ask "Install fonts (Mac, Adobe, Noto, JetBrains, Hack, etc.)?"; then
        paru -S --needed --noconfirm ttf-mac-fonts apple-fonts adobe-source-sans-fonts \
            noto-fonts ttf-droid ttf-font-awesome ttf-roboto awesome-terminal-fonts \
            ttf-anonymous-pro ttf-hack ttf-ibm-plex ttf-liberation ttf-dejavu \
            ttf-ubuntu-font-family

        if ask "Also install Microsoft Windows fonts (downloads from Microsoft CDN)?"; then
            paru -S --needed --noconfirm ttf-ms-win10-auto
        fi
    fi

    if ask "Install icon themes (Tela, Flat Remix, Fluent, Surfn)?"; then
        paru -S --needed --noconfirm tela-icon-theme-git flat-remix fluent-icon-theme-git surfn-icons-git
    fi

    if ask "Install cursor themes (Premium, WhiteSur, Vimix)?"; then
        paru -S --needed --noconfirm xcursor-premium whitesur-cursor-theme-git vimix-cursors
    fi

    if ask "Install GRUB Vimix theme? (Not used on CachyOS by default)"; then
        paru -S --needed --noconfirm arcolinux-grub-theme-vimix-git
        sudo sed -i 's|^#\?GRUB_THEME=.*|GRUB_THEME="/boot/grub/Vimix/theme.txt"|' /etc/default/grub
        sudo grub-mkconfig -o /boot/grub/grub.cfg
        success "GRUB Vimix theme applied."
    fi

    if ask "Install benchmarking tools (Geekbench, Phoronix, GPUTest, etc.)?"; then
        paru -S --needed --noconfirm hardinfo blender-benchmark geekbench gputest phoronix-test-suite
    fi

    success "Customization section complete."
}

# -----------------------------------------------------------------------------
# 13. Application Packages
# -----------------------------------------------------------------------------
section_apps() {
    header "Application Packages"

    if ask "Install office and productivity apps (LibreOffice, Zoom, Thunderbird, etc.)?"; then
        paru -S --needed --noconfirm atom-ng-bin sublime-text-4 calibre libreoffice-fresh \
            libreoffice-extension-languagetool zoom webex-bin notion filezilla evolution \
            qbittorrent transmission-gtk mailspring-bin thunderbird
    fi

    if ask "Install browsers (Firefox, Brave, Chrome, Edge, Zen)?"; then
        yay -S --needed --noconfirm firefox firefox-ublock-origin brave-bin google-chrome \
            microsoft-edge-stable-bin firefox-developer-edition zen-browser-bin
    fi

    if ask "Install development tools (Flameshot, Meld, IntelliJ, PyCharm, etc.)?"; then
        paru -S --needed --noconfirm flameshot meld the_platinum_searcher-bin \
            simplescreenrecorder scrot intellij-idea-community-edition kdevelop \
            leafpad openscad pycharm-community-edition dconf-editor
    fi

    if ask "Install multimedia and graphics apps (Inkscape, Blender, Kdenlive, OBS, Spotify, etc.)?"; then
        paru -S --needed --noconfirm inkscape blender pinta krita pitivi openshot shotcut \
            scribus kdenlive handbrake youtube-dl vlc spotify obs-studio lmms kazam \
            audacity digikam darktable synfigstudio gwenview kamoso

        if ask "Install DaVinci Resolve? (Requires correct AMD/Nvidia setup)"; then
            paru -S --needed --noconfirm davinci-resolve
        fi
    fi

    if ask "Install KDE meta packages (multimedia, system, utilities, PIM, network, SDK)?"; then
        paru -S --needed --noconfirm kde-multimedia-meta kde-system-meta kde-utilities-meta \
            kde-pim-meta kde-network-meta kde-sdk-meta
    fi

    if ask "Install language and spell-check tools (aspell, hunspell, LanguageTool, Java)?"; then
        paru -S --needed --noconfirm aspell-en libmythes mythes-en languagetool enchant \
            hunspell-en_US pkgstats gst-plugins-good icedtea-web gst-libav jre8-openjdk
    fi

    success "Application packages section complete."
}

# -----------------------------------------------------------------------------
# 14. Gaming Setup
# -----------------------------------------------------------------------------
section_gaming() {
    header "Gaming Setup"

    info "Installing full gaming stack (Steam, Lutris, Wine, MangoHud, Gamemode, etc.)..."
    paru -S --needed --noconfirm steam-native-runtime minigalaxy itch-bin \
        heroic-games-launcher lutris gamehub playonlinux playitslowly bottles \
        boxtron dxvk-mingw-git displaycal droidcam goverlay fastgame-git \
        mangohud gamemode rare replay-sorcery

    success "Gaming stack installed."
}

# -----------------------------------------------------------------------------
# 15. Additional Utilities
# -----------------------------------------------------------------------------
section_utilities() {
    header "Additional Utilities"

    if ask "Install file management and system tools (Dolphin plugins, KDEConnect, Inxi, etc.)?"; then
        paru -S --needed --noconfirm thunar thunar-archive-plugin thunar-volman \
            os-prober smbclient traceroute dnsutils nmap speedtest-cli wavemon \
            net-tools dsniff ark cryfs dolphin-plugins ffmpegthumbs gwenview \
            imagemagick kde-gtk-config kdeconnect ocs-url okular partitionmanager \
            w3m hardcode-fixer-git dosfstools fuse2 fuse3 cifs-utils git yajl \
            curl jq appstream peek downgrade inxi gitahead
    fi

    if ask "Install compression, codec, and system monitoring tools (Stacer, Ventoy, Wireshark, etc.)?"; then
        paru -S --needed --noconfirm bleachbit cpufetch-git htop lm_sensors lshw \
            redshift s-tui rsync cpu-x bitwarden unace unrar zip unzip \
            uudeview ark cabextract file-roller p7zip lzop variety evince \
            arch-audit fuse-exfat a52dec faad2 faac flac jasper lame libdca libdv \
            gst-libav libmad libmpeg2 libxv wavpack x264 x265 xvidcore \
            kdegraphics-thumbnailers kimageformats qt5-imageformats kdesdk-thumbnailers \
            ffmpegthumbs taglib ntfs-3g piper gnome-keyring stacer-bin \
            ventoy-bin auto-cpufreq wireshark-qt
    fi

    if ask "Install additional AUR tools (DupeGuru, FluentReader, 4K Video Downloader, GitHub Desktop)?"; then
        paru -S --needed --noconfirm dupeguru bpytop fluent-reader p7zip-gui \
            flac wavpack radeontop-git 4kvideodownloader github-desktop-bin
    fi

    success "Utilities section complete."
}

# -----------------------------------------------------------------------------
# 16. Face ID Login (Howdy)
# -----------------------------------------------------------------------------
section_howdy() {
    header "Face ID Login with Howdy"

    warn "Howdy modifies PAM configuration files. This section includes manual steps."
    info "Installing Howdy..."
    yay -S --needed --noconfirm howdy

    info "Available video devices:"
    ls /dev/video* 2>/dev/null || warn "No video devices found."
    echo ""
    prompt "Enter your webcam device path (e.g. /dev/video0 or /dev/video2): "
    read -r VIDEO_DEVICE

    if [[ -z "$VIDEO_DEVICE" ]]; then
        warn "No device entered — skipping Howdy configuration."
        return
    fi

    info "Opening Howdy config. Set 'device_path = $VIDEO_DEVICE' in the config..."
    sleep 2
    sudo howdy config

    if ask "Enroll your face now?"; then
        sudo howdy add
    fi

    warn "PAM configuration changes are MANUAL. Add the following lines to the top"
    warn "of the 'auth' section in /etc/pam.d/sudo and /etc/pam.d/sddm:"
    echo ""
    echo -e "${DIM}  auth    sufficient    pam_python.so /lib/security/howdy/pam.py"
    echo -e "  auth    sufficient    pam_unix.so try_first_pass likeauth nullok${RESET}"
    echo ""
    warn "Automating PAM edits is risky — they are left for manual review."
    prompt "Press Enter when you're ready to continue..."
    read -r

    success "Howdy installed. Complete PAM setup manually as noted above."
}

# -----------------------------------------------------------------------------
# 17. iPhone Mounting
# -----------------------------------------------------------------------------
section_iphone() {
    header "iPhone Mounting"

    info "Installing iPhone mount packages..."
    paru -S --needed --noconfirm ifuse usbmuxd libplist libimobiledevice shotwell

    info "Creating ~/iPhone mount point..."
    mkdir -p "$HOME/iPhone"

    info "To mount your iPhone:"
    echo "  1. Connect it via USB and unlock it"
    echo "  2. Tap 'Trust' on your iPhone when prompted"
    echo "  3. Run: ifuse ~/iPhone"
    echo "  4. To unmount: fusermount -u ~/iPhone"

    success "iPhone mount packages installed."
}

# -----------------------------------------------------------------------------
# 18. KDE Service Menu Extensions
# -----------------------------------------------------------------------------
section_kde_menus() {
    header "KDE Service Menu Extensions"

    info "Installing KDE right-click context menu extensions..."
    paru -S --needed --noconfirm kf5-servicemenus-clamtkscan kf6-servicemenus-pdftools \
        kf6-servicemenus-rootactions

    if ask "Install JamesDSP (audio DSP) and KDE Material You Colors?"; then
        yay -S --needed --noconfirm jamesdsp-git kde-material-you-colors
    fi

    success "KDE service menus section complete."
}

# -----------------------------------------------------------------------------
# 19. NVIDIA Primary GPU (Laptop)
# -----------------------------------------------------------------------------
section_nvidia_primary() {
    header "NVIDIA Primary GPU (Laptop)"

    warn "This configures Wayland to use NVIDIA as the primary GPU on hybrid laptops."
    info "Creating ~/.config/environment.d/90-nvidia.conf..."

    mkdir -p "$HOME/.config/environment.d/"
    NVIDIA_CONF="$HOME/.config/environment.d/90-nvidia.conf"

    cat > "$NVIDIA_CONF" <<'EOF'
__NV_PRIME_RENDER_OFFLOAD=1
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_only
EOF

    success "NVIDIA config written to $NVIDIA_CONF"
    info "Reboot for changes to take effect."
}

# -----------------------------------------------------------------------------
# 20. Fastfetch Configuration
# -----------------------------------------------------------------------------
section_fastfetch() {
    header "Fastfetch Configuration"

    info "Writing fastfetch config to ~/.config/fastfetch/config.jsonc..."
    mkdir -p "$HOME/.config/fastfetch"

    cat > "$HOME/.config/fastfetch/config.jsonc" <<'EOF'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "type": "builtin",
        "height": 15,
        "width": 30,
        "padding": {
            "top": 5,
            "left": 3
        }
    },
    "modules": [
        "break",
        {
            "type": "custom",
            "format": "\u001b[90m┌──────────────────────Hardware──────────────────────┐"
        },
        { "type": "host",   "key": " PC",   "keyColor": "green" },
        { "type": "cpu",    "key": "│ ├",   "keyColor": "green" },
        { "type": "gpu",    "key": "│ ├󰍛", "keyColor": "green" },
        { "type": "memory", "key": "│ ├󰍛", "keyColor": "green" },
        { "type": "disk",   "key": "└ └",   "keyColor": "green" },
        {
            "type": "custom",
            "format": "\u001b[90m└────────────────────────────────────────────────────┘"
        },
        "break",
        {
            "type": "custom",
            "format": "\u001b[90m┌──────────────────────Software──────────────────────┐"
        },
        { "type": "os",       "key": " OS",  "keyColor": "yellow" },
        { "type": "kernel",   "key": "│ ├",  "keyColor": "yellow" },
        { "type": "bios",     "key": "│ ├",  "keyColor": "yellow" },
        { "type": "packages", "key": "│ ├󰏖", "keyColor": "yellow" },
        { "type": "shell",    "key": "└ └",  "keyColor": "yellow" },
        "break",
        { "type": "de",      "key": " DE",  "keyColor": "blue" },
        { "type": "lm",      "key": "│ ├",  "keyColor": "blue" },
        { "type": "wm",      "key": "│ ├",  "keyColor": "blue" },
        { "type": "wmtheme", "key": "│ ├󰉼", "keyColor": "blue" },
        { "type": "terminal","key": "└ └",  "keyColor": "blue" },
        {
            "type": "custom",
            "format": "\u001b[90m└────────────────────────────────────────────────────┘"
        },
        "break",
        {
            "type": "custom",
            "format": "\u001b[90m┌────────────────────Uptime / Age / DT────────────────────┐"
        },
        {
            "type": "command",
            "key": "  OS Age ",
            "keyColor": "magenta",
            "text": "birth_install=$(stat -c %W /); current=$(date +%s); time_progression=$((current - birth_install)); days_difference=$((time_progression / 86400)); echo $days_difference days"
        },
        { "type": "uptime",   "key": "  Uptime ",   "keyColor": "magenta" },
        { "type": "datetime", "key": "  DateTime ", "keyColor": "magenta" },
        {
            "type": "custom",
            "format": "\u001b[90m└─────────────────────────────────────────────────────────┘"
        },
        "break"
    ]
}
EOF

    success "Fastfetch config written. Run 'fastfetch' to test it."
}

# -----------------------------------------------------------------------------
# 21. System Maintenance Commands
# -----------------------------------------------------------------------------
section_maintenance() {
    header "System Maintenance"

    if ask "Remove orphaned packages now?"; then
        ORPHANS=$(paru -Qtdq 2>/dev/null || true)
        if [[ -n "$ORPHANS" ]]; then
            echo "$ORPHANS" | paru -Rns --noconfirm -
            success "Orphaned packages removed."
        else
            info "No orphaned packages found."
        fi
    fi

    info "Checking for failed systemd services..."
    sudo systemctl --failed || true

    info "Recent system errors (last boot):"
    sudo journalctl -p 3 -xb --no-pager | tail -30 || true

    success "Maintenance check complete."
}

# -----------------------------------------------------------------------------
# 22. System Audit with Lynis
# -----------------------------------------------------------------------------
section_lynis() {
    header "System Audit with Lynis"

    if [[ ! -d /opt/lynis ]]; then
        info "Cloning Lynis into /opt/lynis..."
        sudo git clone https://github.com/CISOfy/lynis.git /opt/lynis
    else
        info "Lynis already present at /opt/lynis. Pulling latest..."
        sudo git -C /opt/lynis pull
    fi

    info "Running Lynis audit..."
    cd /opt/lynis && sudo ./lynis audit system
    cd "$OLDPWD"

    success "Lynis audit complete. Review output above for recommendations."
}

# =============================================================================
# MAIN MENU
# =============================================================================

SECTIONS=(
    "1:AMD GPU Drivers"
    "2:Networking and Security"
    "3:Antivirus (ClamAV)"
    "4:Firewall (UFW)"
    "5:AppArmor"
    "6:Virtual Machines (VirtualBox / VMware)"
    "7:Kernel Firmware Warnings Fix"
    "8:Storage and Drive Utilities"
    "9:User Group Permissions"
    "10:Bluetooth, Printing, and Audio"
    "11:Shell Configuration (ZSH)"
    "12:System Customization (fonts, icons, cursors)"
    "13:Application Packages"
    "14:Gaming Setup"
    "15:Additional Utilities"
    "16:Face ID Login (Howdy)"
    "17:iPhone Mounting"
    "18:KDE Service Menu Extensions"
    "19:NVIDIA Primary GPU (Laptop)"
    "20:Fastfetch Configuration"
    "21:System Maintenance"
    "22:System Audit (Lynis)"
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
    echo -e "${BOLD}  Post-Install Setup Script${RESET}  ${DIM}User: $CURRENT_USER${RESET}"
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
    echo -e "${DIM}  You can enter multiple numbers separated by spaces (e.g: 1 3 5 8)${RESET}"
    echo ""
}

run_section() {
    case "$1" in
        1)  section_amd_gpu ;;
        2)  section_networking ;;
        3)  section_antivirus ;;
        4)  section_firewall ;;
        5)  section_apparmor ;;
        6)  section_vms ;;
        7)  section_firmware ;;
        8)  section_storage ;;
        9)  section_groups ;;
        10) section_bluetooth_printing_audio ;;
        11) section_zsh ;;
        12) section_customization ;;
        13) section_apps ;;
        14) section_gaming ;;
        15) section_utilities ;;
        16) section_howdy ;;
        17) section_iphone ;;
        18) section_kde_menus ;;
        19) section_nvidia_primary ;;
        20) section_fastfetch ;;
        21) section_maintenance ;;
        22) section_lynis ;;
        *)  warn "Unknown section: $1" ;;
    esac
}

main() {
    while true; do
        print_menu
        prompt "Enter your selection: "
        read -r -a CHOICES

        if [[ ${#CHOICES[@]} -eq 0 ]]; then
            continue
        fi

        # Handle quit
        if [[ "${CHOICES[0],,}" == "q" ]]; then
            echo ""
            info "Exiting. Log saved to $LOG_FILE"
            break
        fi

        # Handle run all
        if [[ "${CHOICES[0],,}" == "a" ]]; then
            for entry in "${SECTIONS[@]}"; do
                num="${entry%%:*}"
                run_section "$num"
            done
            echo ""
            success "All sections complete. A reboot is recommended."
            prompt "Press Enter to return to the menu..."
            read -r
            continue
        fi

        # Handle individual/multiple selections
        for choice in "${CHOICES[@]}"; do
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= 22 )); then
                run_section "$choice"
            else
                warn "Invalid selection: $choice — skipping."
            fi
        done

        echo ""
        prompt "Press Enter to return to the menu..."
        read -r
    done
}

main
