#!/usr/bin/env bash
# =============================================================================
# Krohnkite — Hyprland-style dynamic tiling for KDE Plasma 6
# Installs the Krohnkite KWin script and turns it on or off.
#
# Run directly:   bash kde/krohnkite.sh [enable|disable]
# Or source it:   source kde/krohnkite.sh && krohnkite_enable
# =============================================================================

KROHNKITE_AUR_PKG="kwin-scripts-krohnkite-git"

_kk_info()    { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_kk_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
_kk_warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

krohnkite_installed() {
    [[ -d /usr/share/kwin/scripts/krohnkite ]] || \
    [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/kwin/scripts/krohnkite" ]]
}

_krohnkite_reload_kwin() {
    if dbus-send --session --type=method_call --dest=org.kde.KWin \
        /KWin org.kde.KWin.reconfigure 2>/dev/null; then
        _kk_success "KWin reloaded."
    else
        _kk_warn "Could not reach KWin over D-Bus. The change applies at next login."
    fi
}

krohnkite_install() {
    krohnkite_installed && return 0

    local helper=""
    if command -v paru >/dev/null 2>&1; then helper="paru"
    elif command -v yay >/dev/null 2>&1; then helper="yay"
    fi

    if [[ -n "$helper" ]]; then
        _kk_info "Installing $KROHNKITE_AUR_PKG with $helper..."
        "$helper" -S --needed --noconfirm "$KROHNKITE_AUR_PKG" || _kk_warn "AUR install failed."
    else
        _kk_warn "No AUR helper (paru or yay) found."
    fi

    if ! krohnkite_installed; then
        _kk_warn "Krohnkite is not installed. Install it by hand:"
        _kk_warn "  System Settings → Window Management → KWin Scripts → Get New… → 'Krohnkite'"
        _kk_warn "then run: bash kde/krohnkite.sh enable"
        return 1
    fi
}

krohnkite_enable() {
    if ! command -v kwriteconfig6 >/dev/null 2>&1; then
        _kk_warn "kwriteconfig6 not found. Krohnkite needs Plasma 6."
        return 1
    fi

    krohnkite_install || return 1

    kwriteconfig6 --file kwinrc --group Plugins --key krohnkiteEnabled true
    _krohnkite_reload_kwin
    _kk_success "Krohnkite enabled. New windows now tile automatically."
    _kk_info "Shortcuts: System Settings → Keyboard → Shortcuts → KWin (search 'Krohnkite')."
    _kk_info "Turn it off again: bash kde/krohnkite.sh disable"
}

krohnkite_disable() {
    kwriteconfig6 --file kwinrc --group Plugins --key krohnkiteEnabled false
    _krohnkite_reload_kwin
    _kk_success "Krohnkite disabled. Windows float normally again."
}

# Run only when executed, not when sourced by another script
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail

    if [[ $EUID -eq 0 ]]; then
        echo "Do not run as root. KWin settings live in your user's ~/.config." >&2
        exit 1
    fi

    case "${1:-enable}" in
        enable)  krohnkite_enable ;;
        disable) krohnkite_disable ;;
        *) echo "Usage: $0 [enable|disable]" >&2; exit 1 ;;
    esac
fi
