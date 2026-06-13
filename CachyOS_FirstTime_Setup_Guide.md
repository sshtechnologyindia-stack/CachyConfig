# CachyOS First-Time Setup Guide

You just installed CachyOS. The system already handles a lot of things that other distros make you do manually — AMD/Intel GPU drivers, PipeWire audio, ZRam swap, and the `paru` AUR helper are all ready to go. This guide covers what's left: security hardening, useful system tweaks, snapshot backups, gaming setup, and getting the tools a new user actually needs.

Work through these sections in order. Everything here is genuinely useful for a first install — nothing is personal preference lifted from someone's dotfile collection.

> **Note:** This guide assumes you installed CachyOS with KDE Plasma and Btrfs, which are the defaults. Some sections (Btrfs snapshots, KDE-specific notes) may not apply if you chose a different setup.

---

## Table of Contents

1. [First Thing: Update Your System](#1-first-thing-update-your-system)
2. [Enable the Firewall](#2-enable-the-firewall)
3. [Set Up Automatic Package Cache Cleanup](#3-set-up-automatic-package-cache-cleanup)
4. [Enable SSD TRIM](#4-enable-ssd-trim)
5. [Configure Btrfs Snapshots](#5-configure-btrfs-snapshots)
6. [Install Antivirus (ClamAV)](#6-install-antivirus-clamav)
7. [AppArmor — Mandatory Access Control](#7-apparmor--mandatory-access-control)
8. [Add Your User to the Right Groups](#8-add-your-user-to-the-right-groups)
9. [Firmware Updates](#9-firmware-updates)
10. [Fix Missing Kernel Firmware Warnings](#10-fix-missing-kernel-firmware-warnings)
11. [AMD GPU — Vulkan and OpenCL](#11-amd-gpu--vulkan-and-opencl)
12. [Install Essential Codecs and Archive Tools](#12-install-essential-codecs-and-archive-tools)
13. [Enable Flatpak and Flathub](#13-enable-flatpak-and-flathub)
14. [AppImage Support](#14-appimage-support)
15. [Set Your Wi-Fi Region](#15-set-your-wi-fi-region)
16. [Harden Firefox](#16-harden-firefox)
17. [Gaming Setup](#17-gaming-setup)
18. [Understanding the AUR](#18-understanding-the-aur)
19. [Basic Security Audit with Lynis](#19-basic-security-audit-with-lynis)
20. [Ongoing Maintenance](#20-ongoing-maintenance)
21. [What You Don't Need to Do](#21-what-you-dont-need-to-do)
22. [Quick Reference Table](#22-quick-reference-table)

---

## 1. First Thing: Update Your System

Before doing anything else, get the system fully up to date. The ISO you installed from may be weeks or months old, and some of the steps below depend on having current packages.

```bash
sudo pacman -Syu
```

Reboot after this completes, especially if the kernel was updated:

```bash
reboot
```

---

## 2. Enable the Firewall

CachyOS ships with UFW (Uncomplicated Firewall) already installed, but it is **not enabled by default**. Turn it on:

```bash
sudo ufw enable
```

Verify it's running:

```bash
sudo ufw status
```

You can also manage the firewall graphically through **System Settings → Firewall** in KDE Plasma.

> **What UFW does by default:** blocks all incoming connections, allows all outgoing. This is the right default — your system can reach the internet normally, but nothing from outside can connect to it uninvited.

### Allow KDE Connect (if you sync your phone)

KDE Connect uses ports 1714–1764. Without these rules, device discovery and sync will silently fail:

```bash
sudo ufw allow 1714:1764/udp
sudo ufw allow 1714:1764/tcp
sudo ufw reload
```

---

## 3. Set Up Automatic Package Cache Cleanup

Every time you update packages, pacman keeps old versions sitting on disk. Over months this quietly fills several gigabytes. Enable the automatic cleanup timer:

```bash
sudo systemctl enable paccache.timer
sudo systemctl start paccache.timer
```

This runs weekly and keeps only the last 3 versions of each package — enough to roll back a bad update, without wasting space. Run it manually any time:

```bash
sudo paccache -r
```

---

## 4. Enable SSD TRIM

If you're running on an SSD, enable periodic TRIM. It tells the drive which blocks are free, helping maintain write performance and lifespan over time:

```bash
sudo systemctl enable fstrim.timer
sudo systemctl start fstrim.timer
```

It runs automatically once a week. Nothing else to configure.

---

## 5. Configure Btrfs Snapshots

This is one of the most valuable things you can do on CachyOS and one that first-time users almost always skip until after something breaks.

CachyOS uses Btrfs as the default filesystem and ships with Snapper and `snap-pac` pre-installed. **Snapper automatically takes a snapshot before and after every pacman operation** — so every update, install, or package removal is reversible. If an update breaks your system, you can boot from a previous snapshot directly from the GRUB menu and restore to it in a few clicks. No reinstall needed.

The catch: the default Snapper configuration keeps snapshots indefinitely, so they pile up and eventually consume significant disk space. You need to configure automatic cleanup.

### Configure Cleanup with Btrfs Assistant

Open **Btrfs Assistant** from your app launcher (or run `btrfs-assistant-launcher` in a terminal).

Go to the **Snapper** tab and make these changes:

- Set **Hourly**, **Daily**, **Weekly**, **Monthly**, and **Yearly** to `0`
- Uncheck **Enable timeline snapshots** (you want package snapshots, not time-based ones)
- Set **Number** to `10`
- Check **Snapper cleanup enabled**
- Click **Save**, then **Apply systemd changes**

This keeps a rolling maximum of 10 snapshots and automatically removes the oldest ones.

### Verify the Configuration Took Effect

```bash
sudo snapper -c root get-config | grep NUMBER
```

You should see `NUMBER_LIMIT = 10` and `NUMBER_LIMIT_IMPORTANT = 10`.

### Enable GRUB Snapshot Boot Menu

If you installed with GRUB (the default), make sure your snapshots actually appear in the GRUB boot menu:

```bash
sudo pacman -S --needed grub-btrfs-support
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

From now on, if the system doesn't boot after an update, restart, pick a snapshot from the GRUB menu, boot into it, open Btrfs Assistant, and restore it.

### Useful Snapshot Commands

```bash
# List all current snapshots
sudo snapper list

# Create a manual snapshot before doing something risky
sudo snapper create --description "Before experimenting with X"

# Delete a specific snapshot (replace N with the number from snapper list)
sudo snapper delete N
```

---

## 6. Install Antivirus (ClamAV)

ClamAV is the standard open-source antivirus for Linux. On a personal desktop it matters less than on Windows, but it's useful if you share files with Windows users, receive a lot of email attachments, or just want an extra layer of protection.

```bash
sudo pacman -S --needed clamav clamtk
```

Update the virus definitions before first use:

```bash
sudo freshclam
```

Enable the services so the database stays current automatically:

```bash
sudo systemctl enable clamav-freshclam.service
sudo systemctl start clamav-freshclam.service

sudo systemctl enable clamav-daemon.service
sudo systemctl start clamav-daemon.service
```

`clamtk` is the GUI frontend — find it in your app launcher to scan files and folders without touching the terminal.

---

## 7. AppArmor — Mandatory Access Control

AppArmor is a kernel security module that restricts what individual programs can access on your system. Even if a program gets compromised, AppArmor limits the damage by confining it to only what it legitimately needs.

```bash
sudo paru -S apparmor apparmor.d-git
sudo systemctl enable --now apparmor.service
```

> **Before you proceed:** `apparmor.d-git` is a community-maintained profile set. A poorly configured profile can prevent legitimate apps from working. If something stops working after enabling AppArmor, run `sudo aa-status` to see what's being enforced, and check logs with `sudo journalctl -xe | grep apparmor`. You can put a specific profile in complain mode (logs violations but doesn't block) while troubleshooting: `sudo aa-complain /etc/apparmor.d/profile-name`.

---

## 8. Add Your User to the Right Groups

This gives your account proper hardware and system access that some tools require. Replace `yourusername` with your actual login name:

```bash
sudo usermod -aG audio,video,storage,network,optical,power,sys,rfkill,wheel,users,realtime yourusername
```

Log out and back in — or reboot — for the changes to take effect.

**What these groups unlock:**

| Group | What it does |
|-------|-------------|
| `audio` / `video` | Direct hardware access for sound and display |
| `storage` | Removable drives and USB mass storage |
| `network` | Network configuration tools |
| `optical` | CD/DVD drives |
| `power` | Suspend, hibernate, and shutdown controls |
| `rfkill` | Enable/disable Wi-Fi and Bluetooth hardware switches |
| `wheel` | sudo access (the installer likely already added you) |
| `realtime` | Real-time scheduling — needed for audio production and low-latency work |

---

## 9. Firmware Updates

`fwupd` is pre-installed on CachyOS KDE. It lets you update firmware for supported hardware (laptops, NVMe drives, docks, peripherals) directly from the Linux Vendor Firmware Service:

```bash
# Refresh the firmware database
sudo fwupdmgr refresh

# Check for available updates
sudo fwupdmgr get-updates

# Apply them
sudo fwupdmgr update
```

Not every device is supported, but many modern laptops and NVMe drives are. Worth running once right after a fresh install.

---

## 10. Fix Missing Kernel Firmware Warnings

If you see warnings like `WARNING: Possibly missing firmware for module...` during kernel updates, install these packages to silence them:

```bash
paru -S aic94xx-firmware wd719x-firmware upd72020x-fw
```

These are firmware blobs for older storage controllers and USB chips. Even if your hardware doesn't need them, having them installed keeps build output clean.

---

## 11. AMD GPU — Vulkan and OpenCL

CachyOS auto-installs Mesa (OpenGL) and the basic AMD driver during setup. For full Vulkan support and GPU compute (used by Blender, DaVinci Resolve, AI tools, and most modern games), you need a few extra packages.

### Vulkan Drivers

```bash
# Open-source Mesa Vulkan — recommended for most people
sudo pacman -S --needed vulkan-radeon lib32-vulkan-radeon

# AMD's official Vulkan driver — optional, some software prefers it
sudo pacman -S --needed amdvlk lib32-amdvlk
```

### Hardware Video Decode Acceleration

Needed for smooth hardware-accelerated playback in browsers and media players:

```bash
sudo pacman -S --needed libva-mesa-driver mesa-vdpau
```

### OpenCL / ROCm Compute

For GPU-accelerated rendering and AI inference:

```bash
paru -S rocm-opencl-runtime
```

### Verify Vulkan Is Working

```bash
sudo pacman -S --needed vulkan-tools
vulkaninfo | grep "GPU id"
```

If this prints your GPU name without errors, Vulkan is working.

---

## 12. Install Essential Codecs and Archive Tools

CachyOS doesn't ship every codec or archive handler by default. These are the ones you'll run into almost immediately.

### Archive Formats

Without these, Ark (KDE's archive manager) can't open `.rar` and some `.7z` files:

```bash
sudo pacman -S --needed unrar unzip zip p7zip lzop
```

### Media Codecs

Covers the vast majority of audio and video formats:

```bash
sudo pacman -S --needed ffmpeg gst-libav gst-plugins-good \
  a52dec faac faad2 flac jasper lame libmad libmpeg2 \
  wavpack x264 x265 xvidcore
```

### NTFS Support

Needed to read and write Windows NTFS drives:

```bash
sudo pacman -S --needed ntfs-3g
```

### ExFAT Support

Common on USB drives and SD cards formatted on Windows or by cameras:

```bash
sudo pacman -S --needed exfatprogs
```

---

## 13. Enable Flatpak and Flathub

Flatpak is a universal packaging format that runs apps in sandboxed containers, independent of your system libraries. Flathub is its main repository and has a huge selection of apps that aren't in the Arch or CachyOS repos — Spotify, Discord, Obsidian, Zoom, Signal Desktop, and many others are on Flathub.

Install Flatpak and add the Flathub repository:

```bash
sudo pacman -S --needed flatpak
flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
```

Reboot once so KDE picks up the Flatpak app entries in the app launcher.

After that, install apps through **Discover** (KDE's software center) with a GUI, or via terminal:

```bash
# Example: install Obsidian
flatpak install flathub md.obsidian.Obsidian
```

**AUR vs Flatpak — when to use which:**

- **AUR first** for developer tools, system utilities, and anything where native performance matters. AUR packages integrate tightly with your system.
- **Flatpak** for sandboxed GUI apps, proprietary software, or when the AUR version is outdated or broken.
- Avoid having both an AUR version and a Flatpak version of the same app installed at the same time — pick one.

---

## 14. AppImage Support

AppImages are self-contained application bundles — download, mark as executable, run. They need FUSE to function, and the version they require (`fuse2`) isn't installed by default on CachyOS:

```bash
sudo pacman -S --needed fuse2
```

After this, running AppImages works as expected:

```bash
chmod +x SomeApp.AppImage
./SomeApp.AppImage
```

---

## 15. Set Your Wi-Fi Region

Almost every Linux setup guide skips this step, but it genuinely matters. Linux uses a regulatory database that controls which Wi-Fi channels and power levels are permitted in each country. The default generic region profile is deliberately conservative and may prevent you from connecting to 5GHz or 6GHz channels.

```bash
sudo nano /etc/conf.d/wireless-regdom
```

Find the line for your country and uncomment it. For example, for India:

```
WIRELESS_REGDOM="IN"
```

Common country codes: `US` (United States), `GB` (United Kingdom), `DE` (Germany), `IN` (India), `AU` (Australia), `CA` (Canada), `JP` (Japan), `FR` (France), `SG` (Singapore), `BR` (Brazil).

Save the file and reboot. Verify it applied:

```bash
iw reg get
```

---

## 16. Harden Firefox

CachyOS ships Firefox as the default browser. There's an official CachyOS-maintained settings package that applies privacy improvements and CPU-specific performance optimizations on top of the standard Firefox install.

```bash
sudo pacman -S --needed cachyos-firefox-settings
```

Restart Firefox. The changes apply automatically — no manual configuration needed.

If you'd rather have a fully pre-compiled optimized Firefox binary instead:

```bash
sudo pacman -S --needed firefox-pure
```

`firefox-pure` is a separately compiled package with the CachyOS settings baked in. Either works. Use `cachyos-firefox-settings` if you already have Firefox set up the way you like it; use `firefox-pure` for a clean install or if you want the fully optimized binary.

---

## 17. Gaming Setup

CachyOS is a strong gaming platform, but the gaming stack isn't installed by default. The CachyOS team maintains an official meta-package that installs everything in one command.

### Install the Gaming Meta-Package

```bash
sudo pacman -S --needed cachyos-gaming-meta
```

This pulls in Steam, Proton, Wine, DXVK, MangoHud, GameMode, and all the libraries they depend on.

### Enable Steam Play for All Games

By default Steam only enables Proton for games officially marked as Linux-compatible. Enable it for everything:

1. Open Steam → **Settings** → **Compatibility**
2. Enable **Enable Steam Play for all other titles**
3. Leave the global default set to the latest stable **Valve Proton** release

### Use Proton-CachyOS for Specific Games

Proton-CachyOS (included in `cachyos-gaming-meta`) is a custom Proton build with extra patches for compatibility and performance. The recommendation is to use it per-game rather than as the global default.

To set it for a specific game:

1. Right-click the game → **Properties** → **Compatibility**
2. Check **Force the use of a specific Steam Play compatibility tool**
3. Select **Proton-CachyOS** from the list

### MangoHud — In-Game Overlay

MangoHud is installed by `cachyos-gaming-meta`. To enable it for a Steam game, add this to its launch options (right-click → Properties → Launch Options):

```
MANGOHUD=1 %command%
```

It shows FPS, frametime, CPU/GPU load, and temperatures while you play.

### Check Game Compatibility Before Buying

- **[ProtonDB](https://www.protondb.com)** — community reports for Steam games running on Linux
- **[Are We Anti-Cheat Yet?](https://areweanticheatyet.com)** — shows whether a game's anti-cheat system blocks Linux

### Non-Steam Games

For Epic Games, GOG, and Amazon Prime games, use Heroic:

```bash
paru -S --needed heroic-games-launcher
```

For older games, emulators, or anything that needs Wine configuration:

```bash
sudo pacman -S --needed lutris
```

---

## 18. Understanding the AUR

Coming from Ubuntu, Fedora, or any non-Arch distro, the AUR (Arch User Repository) is likely new to you. It's a community-maintained repository of build scripts — essentially instructions for compiling and installing software that isn't in the official Arch or CachyOS repos.

**The AUR is powerful but needs some awareness:**

- **Anyone can submit an AUR package.** Unlike the official repos, AUR packages aren't reviewed before publication. The community does audit popular packages, but it's not a curated store.
- **Check the PKGBUILD before installing anything unfamiliar.** The PKGBUILD is the build script that `paru` will execute on your machine. You can review it by running `paru -G packagename` before installing.
- **Stick to well-maintained packages.** On the AUR page for any package, check the vote count, out-of-date flags, and last-updated date. A package with thousands of votes updated recently is vastly safer than one with 5 votes last touched 3 years ago.
- **`paru` shows you the PKGBUILD and asks for confirmation by default**, which is the right behavior. Don't skip past it blindly.

For popular, well-known packages (VS Code, Chrome, Discord, JetBrains IDEs, etc.), the AUR packages are generally trustworthy and maintained by active contributors. For obscure packages from unknown authors, take an extra minute to read what you're running.

---

## 19. Basic Security Audit with Lynis

Lynis scans your system and produces a hardening score with specific, actionable recommendations. It makes no changes — it just shows you what to look at. Good to run once after finishing the rest of this guide.

```bash
cd /opt
sudo git clone https://github.com/CISOfy/lynis.git
cd lynis
sudo ./lynis audit system
```

Scroll to the **Warnings** and **Suggestions** sections at the bottom. Don't try to address everything at once — focus on what makes sense for your use case and hardware.

---

## 20. Ongoing Maintenance

Run these periodically. Once a month is a reasonable cadence for most people.

### Full System Update (repos + AUR in one command)

```bash
paru -Syu
```

This updates both official packages and AUR packages. No need to run `sudo pacman -Syu` separately — paru handles both.

### Remove Orphaned Packages

Packages that were installed as dependencies but are no longer needed by anything:

```bash
paru -Rns $(paru -Qtdq)
```

### Check for Failed Services

```bash
sudo systemctl --failed
```

### Check for Recent System Errors

```bash
sudo journalctl -p 3 -xb
```

`-p 3` shows `err` level and above. `-b` limits output to the current boot. Quick way to spot driver issues or misbehaving services.

### Clear Old Logs

```bash
sudo journalctl --vacuum-time=4weeks
```

### Read Arch News Before Major Updates

CachyOS is a rolling release. Occasionally a major update needs a manual step before running it. Check [https://archlinux.org/news/](https://archlinux.org/news/) if you haven't updated in a while. The CachyOS system tray update notifier also does this check automatically.

---

## 21. What You Don't Need to Do

Things that commonly appear in Arch/CachyOS guides but are already handled:

- **PipeWire setup** — fully configured and running out of the box
- **AMD Mesa/OpenGL drivers** — auto-detected and installed during setup
- **Installing `paru`** — already included
- **ZSH or Fish shell setup** — Fish is the default with a solid config. Switch only if you have a specific reason
- **Swap configuration** — CachyOS uses ZRam with sensible defaults already in place
- **GRUB theming** — CachyOS configures its own GRUB. Don't modify it unless you know exactly what you're doing
- **Installing Snapper** — already installed, just needs the cleanup config from Section 5
- **KDE theme setup** — pre-configured. Customize through System Settings whenever you feel like it

---

## 22. Quick Reference Table

| Task | Fresh install status | Action needed |
|------|---------------------|---------------|
| AMD GPU (Mesa / OpenGL) | ✅ Done | None |
| PipeWire audio | ✅ Done | None |
| ZRam swap | ✅ Done | None |
| `paru` AUR helper | ✅ Done | None |
| Fish shell | ✅ Done | None |
| Snapper installed | ✅ Done | Configure cleanup (Section 5) |
| Firewall (UFW) | ⚠️ Installed, not active | Enable it (Section 2) |
| Package cache cleanup | ⚠️ Not scheduled | Enable timer (Section 3) |
| SSD TRIM | ⚠️ Not scheduled | Enable timer (Section 4) |
| Vulkan drivers (AMD) | ⚠️ Partial | Install extras (Section 11) |
| Firmware updates | ⚠️ Tool present | Run manually (Section 9) |
| Flatpak / Flathub | ❌ Not set up | Install and add repo (Section 13) |
| AppImage support | ❌ Missing `fuse2` | Install it (Section 14) |
| Codecs and archive tools | ❌ Partial | Install extras (Section 12) |
| CachyOS Firefox settings | ❌ Not installed | Optional (Section 16) |
| Gaming stack | ❌ Not installed | `cachyos-gaming-meta` (Section 17) |
| ClamAV antivirus | ❌ Not installed | Optional, recommended (Section 6) |
| AppArmor | ❌ Not installed | Optional, advanced (Section 7) |
| Wi-Fi region | ❌ Set to generic | Set your country code (Section 15) |

---

*This guide is accurate as of CachyOS releases in 2025. CachyOS is a rolling release — details change, so cross-check with the [official CachyOS wiki](https://wiki.cachyos.org) if something doesn't match what you see on your system.*
