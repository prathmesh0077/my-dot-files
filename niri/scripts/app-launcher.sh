#!/usr/bin/env bash
#
# app-launcher.sh
# -----------------------------------------------------------------------------
# A fast, minimal application launcher for Fedora + Niri (Wayland) + rofi-wayland.
#
# FEATURES
#   - Lists installed applications from .desktop files (drun-style), with icons.
#   - Favorites pinned to the top, then recently launched apps, then the rest.
#   - Type-ahead fuzzy search, full keyboard navigation, instant launch.
#   - "> <command>" prefix executes an arbitrary shell command instead of
#     picking an application (e.g. "> firefox --private-window").
#   - Refuses to run outside a Wayland session (shows the error via rofi).
#   - Small on-disk cache of parsed .desktop files for fast startup.
#
# -----------------------------------------------------------------------------
# DEPENDENCIES
#   bash (>= 4), rofi (rofi-wayland build), coreutils, findutils, grep, sed, awk
#
#   sudo dnf install rofi-wayland
#
# -----------------------------------------------------------------------------
# INSTALLATION
#   1. Save this file, e.g.:
#        mkdir -p ~/.local/bin
#        cp app-launcher.sh ~/.local/bin/app-launcher.sh
#        chmod +x ~/.local/bin/app-launcher.sh
#   2. Make sure ~/.local/bin is on your PATH.
#   3. (Optional) Drop a custom rofi theme at:
#        ~/.config/rofi/launcher.rasi
#      and adjust THEME_FILE below if you use a different path.
#   4. Edit the CONFIGURATION block below: favorites, terminal, rows, etc.
#
# -----------------------------------------------------------------------------
# NIRI KEYBIND EXAMPLE
#   Add to ~/.config/niri/config.kdl:
#
#     binds {
#         Mod+Space { spawn "~/.local/bin/app-launcher.sh"; }
#     }
#
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

###############################################################################
# CONFIGURATION — edit this section to customize behavior.
###############################################################################

# Number of result rows visible in the rofi window.
ROWS=8

# Window width. Plain number = percentage of screen width (rofi default unit).
# Use a rofi theme (THEME_FILE) if you want a fixed pixel width instead.
WIDTH=40

# Path to a custom rofi theme (.rasi). If it doesn't exist, a built-in
# minimal inline theme is used instead so the launcher still looks clean.
THEME_FILE="${HOME}/.config/rofi/launcher.rasi"

# Show application icons (true/false). Disabling can marginally speed things
# up on very low-end hardware.
ICONS_ENABLED=true

# Terminal emulator used to wrap CLI/TUI commands launched via "> cmd".
TERMINAL_CMD="foot"

# Desktop-entry "Categories" that should be promoted above ordinary apps
# (but still below favorites/recents). Leave empty to disable boosting.
PREFERRED_CATEGORIES=("Utility" "Development" "System" "Internet")

# Favorites, by .desktop file id (filename without ".desktop"), most
# important first. Find ids with: ls /usr/share/applications/*.desktop
FAVORITES=("firefox" "org.gnome.Nautilus" "foot" "code")

# Known CLI/TUI programs that should be wrapped in $TERMINAL_CMD when run
# via the "> command" prefix (e.g. "> btop" opens a terminal running btop).
TUI_PROGRAMS=("btop" "htop" "top" "vim" "nvim" "less" "man" "ranger" "lf" "ncdu" "bash" "zsh")

# Prefix that triggers "run as shell command" mode.
COMMAND_PREFIX=">"

# History (recents) settings.
HISTORY_FILE="${HOME}/.cache/app-launcher/history"
HISTORY_LIMIT=10

# Desktop-entry cache (rebuilt automatically when applications change).
CACHE_DIR="${HOME}/.cache/app-launcher"
CACHE_FILE="${CACHE_DIR}/apps.cache"

# Directories scanned for .desktop files, in priority order.
APP_DIRS=(
    "${HOME}/.local/share/applications"
    "/usr/local/share/applications"
    "/usr/share/applications"
    "/var/lib/flatpak/exports/share/applications"
    "${HOME}/.local/share/flatpak/exports/share/applications"
)

ROFI_BIN="rofi"

###############################################################################
# INTERNAL — you generally shouldn't need to edit below this line.
###############################################################################

# Record/lookup tables populated by load_cache(). Declared globally so all
# functions can see them without passing huge structures around.
declare -A APP_NAME=()
declare -A APP_EXEC=()
declare -A APP_ICON=()
declare -A APP_TERMINAL=()
declare -A APP_CATEGORIES=()
declare -a APP_IDS=()

# Reverse lookup: a displayed label -> desktop id, built while rendering the
# menu so we can map the user's rofi selection back to a launchable entry.
declare -A LABEL_TO_ID=()

# ----------------------------------------------------------------------------
# error_via_rofi MESSAGE
#   Show a one-button error dialog through rofi itself, so failures are
#   visible even when launched from a keybind with no terminal attached.
# ----------------------------------------------------------------------------
error_via_rofi() {
    local message="$1"
    "$ROFI_BIN" -e "$message" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# require_wayland
#   Refuse to run outside a Wayland session, per requirement #3.
# ----------------------------------------------------------------------------
require_wayland() {
    if [[ "${XDG_SESSION_TYPE:-}" != "wayland" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        error_via_rofi "app-launcher.sh requires a Wayland session (Niri). Aborting."
        echo "Error: not running under Wayland (XDG_SESSION_TYPE/WAYLAND_DISPLAY unset)." >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# require_deps
#   Sanity-check that rofi is actually installed before we do anything else.
# ----------------------------------------------------------------------------
require_deps() {
    if ! command -v "$ROFI_BIN" >/dev/null 2>&1; then
        echo "Error: '$ROFI_BIN' not found. Install with: sudo dnf install rofi-wayland" >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# strip_field_codes EXEC
#   Remove .desktop "Exec=" field codes (%f %F %u %U %i %c %k ...) that rofi
#   would otherwise pass through literally to the shell.
# ----------------------------------------------------------------------------
strip_field_codes() {
    sed -E 's/%[fFuUickdDnNvm]//g; s/[[:space:]]+/ /g' <<<"$1" | sed -E 's/^ //; s/ $//'
}

# ----------------------------------------------------------------------------
# cache_is_stale
#   True if the cache is missing or any .desktop file is newer than it.
# ----------------------------------------------------------------------------
cache_is_stale() {
    [[ -f "$CACHE_FILE" ]] || return 0
    local dir
    for dir in "${APP_DIRS[@]}"; do
        [[ -d "$dir" ]] || continue
        if find "$dir" -name '*.desktop' -newer "$CACHE_FILE" -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

# ----------------------------------------------------------------------------
# build_cache
#   Scan all APP_DIRS for .desktop files and write a flat, pipe-delimited
#   cache: id|Name|Exec|Icon|Terminal|Categories
#   Hidden entries (Hidden=true / NoDisplay=true) are skipped entirely.
# ----------------------------------------------------------------------------
build_cache() {
    mkdir -p "$CACHE_DIR"
    local tmp
    tmp="$(mktemp "${CACHE_DIR}/.cache.XXXXXX")"

    local dir file id
    declare -A seen=()

    for dir in "${APP_DIRS[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' file; do
            id="$(basename "$file" .desktop)"
            # First match wins (APP_DIRS is priority-ordered; user dir first).
            [[ -n "${seen[$id]:-}" ]] && continue
            seen[$id]=1
            parse_desktop_file "$file" "$id" >>"$tmp" || true
        done < <(find "$dir" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
    done

    sort -t'|' -k2,2 -f "$tmp" -o "$tmp"
    mv "$tmp" "$CACHE_FILE"
}

# ----------------------------------------------------------------------------
# parse_desktop_file FILE ID
#   Extract the fields we care about from a single .desktop file's
#   [Desktop Entry] section and emit one cache line, or nothing if the
#   entry should be hidden/skipped.
# ----------------------------------------------------------------------------
parse_desktop_file() {
    local file="$1" id="$2"
    awk -v id="$id" '
        BEGIN { in_de = 0; hidden = 0; no_display = 0; is_app = 1 }
        /^\[Desktop Entry\]/ { in_de = 1; next }
        /^\[/ && !/^\[Desktop Entry\]/ { in_de = 0 }
        in_de && /^Type=/ {
            split($0, a, "="); if (a[2] != "Application") is_app = 0
        }
        in_de && /^Name=/ && name == "" {
            sub(/^Name=/, ""); name = $0
        }
        in_de && /^Exec=/ && exec_ == "" {
            sub(/^Exec=/, ""); exec_ = $0
        }
        in_de && /^Icon=/ && icon == "" {
            sub(/^Icon=/, ""); icon = $0
        }
        in_de && /^Terminal=true/ { term = "true" }
        in_de && /^Categories=/ {
            sub(/^Categories=/, ""); cats = $0
        }
        in_de && /^Hidden=true/ { hidden = 1 }
        in_de && /^NoDisplay=true/ { no_display = 1 }
        END {
            if (!is_app || hidden || no_display || name == "" || exec_ == "") exit 1
            gsub(/\|/, "", name); gsub(/\|/, "", exec_); gsub(/\|/, "", icon); gsub(/\|/, "", cats)
            printf "%s|%s|%s|%s|%s|%s\n", id, name, exec_, icon, (term == "true" ? "1" : "0"), cats
        }
    ' "$file"
}

# ----------------------------------------------------------------------------
# load_cache
#   Read the (freshly built or still-valid) cache file into the in-memory
#   associative arrays used to render the menu and resolve selections.
# ----------------------------------------------------------------------------
load_cache() {
    local line id name exec_ icon term cats
    while IFS='|' read -r id name exec_ icon term cats; do
        [[ -z "$id" ]] && continue
        APP_IDS+=("$id")
        APP_NAME["$id"]="$name"
        APP_EXEC["$id"]="$exec_"
        APP_ICON["$id"]="$icon"
        APP_TERMINAL["$id"]="$term"
        APP_CATEGORIES["$id"]="$cats"
    done <"$CACHE_FILE"
}

# ----------------------------------------------------------------------------
# read_history
#   Print recent desktop ids, most recent first, from HISTORY_FILE.
# ----------------------------------------------------------------------------
read_history() {
    [[ -f "$HISTORY_FILE" ]] || return 0
    cat "$HISTORY_FILE"
}

# ----------------------------------------------------------------------------
# record_history ID
#   Push ID to the front of the history file, deduplicated, trimmed to
#   HISTORY_LIMIT lines.
# ----------------------------------------------------------------------------
record_history() {
    local id="$1"
    mkdir -p "$(dirname "$HISTORY_FILE")"
    local existing=""
    [[ -f "$HISTORY_FILE" ]] && existing="$(cat "$HISTORY_FILE")"
    { printf '%s\n' "$id"; printf '%s\n' "$existing"; } \
        | awk '!seen[$0]++ && NF' \
        | head -n "$HISTORY_LIMIT" \
        > "${HISTORY_FILE}.tmp"
    mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

# ----------------------------------------------------------------------------
# emit_entry ID
#   Print one rofi-dmenu line for the given desktop id, including the icon
#   extension syntax when icons are enabled and an icon is available, and
#   record the label->id mapping for later lookup. Missing icons degrade
#   gracefully to a plain text row.
# ----------------------------------------------------------------------------
emit_entry() {
    local id="$1"
    local name="${APP_NAME[$id]}"
    LABEL_TO_ID["$name"]="$id"
    local icon="${APP_ICON[$id]:-}"
    if [[ "$ICONS_ENABLED" == true && -n "$icon" ]]; then
        printf '%s\0icon\x1f%s\n' "$name" "$icon"
    else
        printf '%s\n' "$name"
    fi
}

# ----------------------------------------------------------------------------
# category_matches ID
#   True if ID's Categories field intersects PREFERRED_CATEGORIES.
# ----------------------------------------------------------------------------
category_matches() {
    local id="$1"
    [[ "${#PREFERRED_CATEGORIES[@]}" -eq 0 ]] && return 1
    local cats="${APP_CATEGORIES[$id]:-}"
    [[ -z "$cats" ]] && return 1
    local cat
    for cat in "${PREFERRED_CATEGORIES[@]}"; do
        [[ "$cats" == *"$cat"* ]] && return 0
    done
    return 1
}

# ----------------------------------------------------------------------------
# build_menu
#   Produce the full, ordered list of rofi-dmenu lines:
#     favorites -> recents -> preferred categories -> everything else.
# ----------------------------------------------------------------------------
build_menu() {
    declare -A used=()
    local id

    for id in "${FAVORITES[@]}"; do
        [[ -n "${APP_NAME[$id]:-}" && -z "${used[$id]:-}" ]] || continue
        used["$id"]=1
        emit_entry "$id"
    done

    while IFS= read -r id; do
        [[ -n "$id" && -n "${APP_NAME[$id]:-}" && -z "${used[$id]:-}" ]] || continue
        used["$id"]=1
        emit_entry "$id"
    done < <(read_history)

    for id in "${APP_IDS[@]}"; do
        [[ -z "${used[$id]:-}" ]] || continue
        category_matches "$id" || continue
        used["$id"]=1
        emit_entry "$id"
    done

    for id in "${APP_IDS[@]}"; do
        [[ -z "${used[$id]:-}" ]] || continue
        used["$id"]=1
        emit_entry "$id"
    done
}

# ----------------------------------------------------------------------------
# launch_command CMD_LINE WRAP_IN_TERMINAL
#   Run an arbitrary shell command line, detached from this script, so the
#   launcher can exit immediately. WRAP_IN_TERMINAL=1 opens it inside
#   TERMINAL_CMD first (for CLI/TUI programs).
# ----------------------------------------------------------------------------
launch_command() {
    local cmd_line="$1" wrap="$2"
    if [[ "$wrap" == "1" ]]; then
        setsid -f "$TERMINAL_CMD" -e bash -c "$cmd_line" >/dev/null 2>&1 &
    else
        setsid -f bash -c "$cmd_line" >/dev/null 2>&1 &
    fi
    disown -a 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# first_word STR -> the first whitespace-separated token of STR.
# ----------------------------------------------------------------------------
first_word() {
    read -r -a parts <<<"$1"
    printf '%s' "${parts[0]:-}"
}

# ----------------------------------------------------------------------------
# is_tui_program NAME -> 0 if NAME is in TUI_PROGRAMS.
# ----------------------------------------------------------------------------
is_tui_program() {
    local name="$1" prog
    for prog in "${TUI_PROGRAMS[@]}"; do
        [[ "$name" == "$prog" ]] && return 0
    done
    return 1
}

# ----------------------------------------------------------------------------
# handle_selection RAW
#   Dispatch the string rofi returned: either a "> command", a known
#   application label, or unrecognised text (ignored, per "exit cleanly").
# ----------------------------------------------------------------------------
handle_selection() {
    local raw="$1"

    # "> command" mode: run the remainder as a shell command.
    if [[ "$raw" == "${COMMAND_PREFIX}"* ]]; then
        local cmd_line="${raw#"${COMMAND_PREFIX}"}"
        cmd_line="${cmd_line# }"
        [[ -z "$cmd_line" ]] && exit 0
        local wrap=0
        is_tui_program "$(first_word "$cmd_line")" && wrap=1
        launch_command "$cmd_line" "$wrap"
        exit 0
    fi

    local id="${LABEL_TO_ID[$raw]:-}"
    if [[ -z "$id" ]]; then
        # Unknown/custom text that wasn't a "> command" — nothing to launch.
        exit 0
    fi

    local exec_clean
    exec_clean="$(strip_field_codes "${APP_EXEC[$id]}")"
    launch_command "$exec_clean" "${APP_TERMINAL[$id]:-0}"
    record_history "$id"
}

# ----------------------------------------------------------------------------
# rofi_theme_args
#   Use the user's THEME_FILE if present, otherwise fall back to a small
#   inline theme so the launcher still looks modern and minimal by default.
# ----------------------------------------------------------------------------
rofi_theme_args() {
    if [[ -f "$THEME_FILE" ]]; then
        printf '%s\n' "-theme" "$THEME_FILE"
        return
    fi
    local inline
    inline='window {width: '"${WIDTH}"'%; border-radius: 10px;} '
    inline+='inputbar {children: [prompt,entry]; padding: 8px;} '
    inline+='listview {lines: '"${ROWS}"'; spacing: 2px; cycle: true;} '
    inline+='element {padding: 6px 8px; border-radius: 6px;} '
    inline+='element-icon {size: 1.2em;} '
    inline+='entry {placeholder: "Search apps or type \"> command\"";}'
    printf '%s\n' "-theme-str" "$inline"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
    require_deps
    require_wayland

    if cache_is_stale; then
        build_cache
    fi
    load_cache

    local -a rofi_opts=(
        -dmenu
        -i                       # case-insensitive matching
        -matching fuzzy
        -cycle
        -p "Run"
        -lines "$ROWS"
        -width "$WIDTH"
        -no-show-match
    )
    [[ "$ICONS_ENABLED" == true ]] && rofi_opts+=(-show-icons)

    local -a theme_opts=()
    while IFS= read -r line; do
        theme_opts+=("$line")
    done < <(rofi_theme_args)
    rofi_opts+=("${theme_opts[@]}")

    local selection
    if ! selection="$(build_menu | "$ROFI_BIN" "${rofi_opts[@]}")"; then
        # Escape / cancel: exit cleanly with no error noise.
        exit 0
    fi

    [[ -z "$selection" ]] && exit 0
    handle_selection "$selection"
}

main "$@"