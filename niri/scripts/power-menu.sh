#!/usr/bin/env bash
#
# power-menu.sh — Rofi-based power menu for Niri (Wayland) on Fedora
#
# ─────────────────────────────────────────────────────────────────────────
# INSTALLATION
# ─────────────────────────────────────────────────────────────────────────
#   1. Install dependencies (Fedora):
#        sudo dnf install rofi-wayland systemd
#
#   2. Place this script in your dotfiles, e.g.:
#        ~/.config/niri/scripts/power-menu.sh
#
#   3. Make it executable:
#        chmod +x ~/.config/niri/scripts/power-menu.sh
#
#   4. Add a keybind in your Niri config (~/.config/niri/config.kdl):
#
#        binds {
#            Mod+Shift+E { spawn "bash" "~/.config/niri/scripts/power-menu.sh"; }
#        }
#
#      (Niri requires absolute paths or shell expansion to work reliably;
#       prefer the full path, e.g. "/home/USER/.config/niri/scripts/power-menu.sh")
#
#   5. Run it manually to test:
#        ./power-menu.sh
#
# ─────────────────────────────────────────────────────────────────────────

# Exit immediately on error, treat unset variables as errors, fail on
# pipeline errors. This is a key part of robust Bash scripting.
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────
# CONFIGURABLE VARIABLES
# ─────────────────────────────────────────────────────────────────────────

# Command used to lock the session. `loginctl lock-session` is tried first
# (see lock_session()); this variable is the fallback / override if you
# prefer a different locker (e.g. swaylock, hyprlock-style tools, etc.)
LOCK_CMD="${LOCK_CMD:-loginctl lock-session}"

# Command used to log out of the current Niri session cleanly.
# Default: ask systemd-logind to terminate the current session, which
# tells Niri (and everything else in the session) to exit.
LOGOUT_CMD="${LOGOUT_CMD:-loginctl terminate-session \"\${XDG_SESSION_ID:-}\"}"

# Rofi theme / appearance options. Tweak to match your dotfiles' style.
ROFI_FONT="${ROFI_FONT:-monospace 11}"
ROFI_WIDTH="${ROFI_WIDTH:-320px}"

# Icons (Unicode). Change freely to taste / icon font availability.
ICON_LOCK="🔒"
ICON_LOGOUT="🚪"
ICON_SUSPEND="🌙"
ICON_REBOOT="⟳"
ICON_SHUTDOWN="⏻"
ICON_YES="✔"
ICON_NO="✘"

# ─────────────────────────────────────────────────────────────────────────
# INTERNAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────

readonly SCRIPT_NAME="$(basename "$0")"

# Shared rofi flags for a clean, minimal, dmenu-style appearance.
ROFI_BASE_ARGS=(
    -dmenu
    -i
    -p "Power"
    -theme-str "window {width: ${ROFI_WIDTH};}"
    -theme-str "entry {font: \"${ROFI_FONT}\";}"
    -theme-str "listview {lines: 5;}"
)

# ─────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────

# Print an error to stderr and, if rofi is available, show it as a popup.
die_with_rofi_error() {
    local message="$1"
    echo "${SCRIPT_NAME}: ${message}" >&2
    if command -v rofi >/dev/null 2>&1; then
        rofi -e "${message}" -theme-str "window {width: ${ROFI_WIDTH};}" || true
    fi
    exit 1
}

# Ensure a required command exists, or bail out with a clear error.
require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die_with_rofi_error "Required command '${cmd}' not found. Please install it."
    fi
}

# Detect whether we are running under a Wayland session.
# Niri is Wayland-only, so this also effectively confirms a Niri context.
is_wayland() {
    [[ -n "${WAYLAND_DISPLAY:-}" ]]
}

# Show a Yes/No confirmation dialog in rofi for a given action.
# Returns 0 if the user confirms "Yes", non-zero otherwise.
confirm_action() {
    local action_name="$1"
    local choice

    choice="$(
        printf '%s\n%s\n' "${ICON_YES}  Yes" "${ICON_NO}  No" \
            | rofi -dmenu -i -p "Confirm: ${action_name}" \
                   -theme-str "window {width: ${ROFI_WIDTH};}" \
                   -theme-str "entry {font: \"${ROFI_FONT}\";}" \
                   -theme-str "listview {lines: 2;}"
    )" || return 1   # Non-zero exit from rofi = cancelled (Esc, etc.)

    [[ "${choice}" == "${ICON_YES}  Yes" ]]
}

# ─────────────────────────────────────────────────────────────────────────
# ACTION FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────

lock_session() {
    # Prefer loginctl's native lock-session mechanism, which works
    # regardless of which screen locker is bound to it via logind/PAM.
    if command -v loginctl >/dev/null 2>&1 \
        && loginctl lock-session >/dev/null 2>&1; then
        return 0
    fi

    # Fall back to the configurable LOCK_CMD if loginctl lock-session
    # is unavailable or fails (e.g. no active session registered).
    eval "${LOCK_CMD}"
}

logout_session() {
    if ! confirm_action "Logout"; then
        exit 0
    fi
    eval "${LOGOUT_CMD}"
}

suspend_system() {
    if ! confirm_action "Suspend"; then
        exit 0
    fi
    systemctl suspend
}

reboot_system() {
    if ! confirm_action "Reboot"; then
        exit 0
    fi
    systemctl reboot
}

shutdown_system() {
    if ! confirm_action "Shutdown"; then
        exit 0
    fi
    systemctl poweroff
}

# ─────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────

main() {
    # Bonus requirement: refuse to run outside Wayland.
    if ! is_wayland; then
        die_with_rofi_error "Not running under Wayland. This menu requires a Wayland session (Niri)."
    fi

    require_command rofi
    require_command systemctl
    require_command loginctl

    # Build the menu, with icons aligned via two-space padding after each icon.
    local menu_entries
    menu_entries="$(printf '%s\n%s\n%s\n%s\n%s\n' \
        "${ICON_LOCK}  Lock" \
        "${ICON_LOGOUT}  Logout" \
        "${ICON_SUSPEND}  Suspend" \
        "${ICON_REBOOT}  Reboot" \
        "${ICON_SHUTDOWN}  Shutdown")"

    local selection
    # If rofi is cancelled (Esc or no selection), it exits non-zero;
    # exit the script gracefully in that case.
    if ! selection="$(printf '%s' "${menu_entries}" | rofi "${ROFI_BASE_ARGS[@]}")"; then
        exit 0
    fi

    # Guard against an empty selection (can happen with some rofi configs).
    if [[ -z "${selection}" ]]; then
        exit 0
    fi

    case "${selection}" in
        "${ICON_LOCK}  Lock")
            lock_session
            ;;
        "${ICON_LOGOUT}  Logout")
            logout_session
            ;;
        "${ICON_SUSPEND}  Suspend")
            suspend_system
            ;;
        "${ICON_REBOOT}  Reboot")
            reboot_system
            ;;
        "${ICON_SHUTDOWN}  Shutdown")
            shutdown_system
            ;;
        *)
            # Unknown/unmatched selection — exit gracefully without action.
            exit 0
            ;;
    esac
}

main "$@"