#!/usr/bin/env bash

set -euo pipefail

CACHE_DIR="$HOME/.cache/clipboard-manager"
THUMB_DIR="$CACHE_DIR/thumbs"

mkdir -p "$THUMB_DIR"

ROFI="rofi"

KB_DELETE="Ctrl+Delete"
KB_CLEAR="Control+Shift+Delete"

declare -a ENTRY_IDS
declare -a ENTRY_TYPES

build_menu() {
    ENTRY_IDS=()
    ENTRY_TYPES=()

    local output=""
    local line id preview hash thumb tmp mime

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        id="${line%%$'\t'*}"
        preview="${line#*$'\t'}"

        ENTRY_IDS+=("$id")

        if [[ "$preview" == \[\[\ binary\ data* ]]; then

            ENTRY_TYPES+=("image")

            hash=$(printf '%s' "$id" | sha256sum | cut -d' ' -f1)
            thumb="$THUMB_DIR/$hash.png"

            if [[ ! -f "$thumb" ]]; then
                tmp=$(mktemp)

                if cliphist decode <<<"$line" >"$tmp" 2>/dev/null; then

                    mime=$(file -b --mime-type "$tmp" 2>/dev/null || true)

                    if [[ "$mime" == image/* ]]; then
                        magick "$tmp" \
                            -auto-orient \
                            -thumbnail 96x96 \
                            "$thumb" 2>/dev/null || true
                    fi
                fi

                rm -f "$tmp"
            fi

            output+="🖼 Image"$'\0'"icon"$'\x1f'"$thumb"$'\n'

        else

            ENTRY_TYPES+=("text")

            preview="${preview//$'\n'/⏎ }"

            if (( ${#preview} > 120 )); then
                preview="${preview:0:120}…"
            fi

            output+="$preview"$'\n'
        fi

    done < <(cliphist list)

    printf '%s' "$output"
}

copy_entry() {
    local index="$1"

    local line

    line=$(cliphist list | sed -n "$((index+1))p")

    [[ -z "$line" ]] && exit 0

    cliphist decode <<<"$line" | wl-copy
}

delete_entry() {
    local index="$1"

    local line

    line=$(cliphist list | sed -n "$((index+1))p")

    [[ -z "$line" ]] && return

    printf '%s\n' "$line" | cliphist delete
}

clear_history() {

    local confirm

    confirm=$(
        printf "No\nYes\n" |
        rofi -dmenu \
            -p "Clear clipboard history?"
    )

    [[ "$confirm" == "Yes" ]] || return

    cliphist wipe
}

while true; do

    MENU=$(build_menu)

    [[ -z "$MENU" ]] && exit 0

    set +e

    SELECTED=$(
        printf '%s' "$MENU" |
        "$ROFI" \
            -dmenu \
            -format i \
            -show-icons \
            -p "Clipboard" \
            -kb-custom-1 "$KB_DELETE" \
            -kb-custom-2 "$KB_CLEAR"
    )

    EXIT_CODE=$?

    set -e

    case "$EXIT_CODE" in

        0)
            copy_entry "$SELECTED"
            exit 0
            ;;

        10)
            delete_entry "$SELECTED"
            ;;

        11)
            clear_history
            ;;

        *)
            exit 0
            ;;
    esac

done