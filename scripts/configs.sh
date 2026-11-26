# shellcheck shell=bash
# Your configs for Perihelion Bar. Sourced by install.sh.
#
# A file that is missing is written. A file that already matches is left
# alone. A file of yours that differs is never replaced silently: you pick
# keep mine / take the new one (yours is backed up first) / write the new one
# beside yours as <file>.perihelion-new. The answer is remembered in
# ~/.local/state/perihelionbar/installer-answers; "take the new one" is only
# reused while the file is still exactly what the installer wrote last time,
# so later edits of yours are asked about again.

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# The answers file keys a file by its path ($HOME shown as ~).
answer_key() { printf 'file:%s' "${1/#"$HOME"/\~}"; }

remember_choice() { # DEST keep|new|beside [SRC]
    local value=$2
    [[ $2 == new ]] && value="new:$(sha_of "$1")"
    answer_set "$(answer_key "$1")" "${value}"
}

backup_file() { # DEST: copy into this run's backup folder, same path below it
    local dest=$1 rel
    rel=${dest/#"$HOME"\//}
    [[ ${rel} == /* ]] && rel="root${rel}"
    mkdir -p "$(dirname "${BACKUP_DIR}/${rel}")"
    cp -a "${dest}" "${BACKUP_DIR}/${rel}"
    log "backed up ${dest} -> ${BACKUP_DIR}/${rel}"
}

# config_choice VAR DEST SRC: keep, new or beside for a file that differs.
config_choice() {
    local var=$1 dest=$2 src=$3 saved shown
    saved=$(answer_get "$(answer_key "${dest}")")
    shown=${dest/#"$HOME"/\~}
    case "${saved}" in
        keep | beside)
            printf -v "${var}" '%s' "${saved}"
            note "${shown}: ${saved} (your answer from last time)"
            return
            ;;
        new:*)
            if [[ ${saved#new:} == "$(sha_of "${dest}")" ]]; then
                printf -v "${var}" new
                note "${shown}: unchanged since the last install; taking the new one"
                return
            fi
            ;;
    esac
    if (( OPT_YES )); then
        printf -v "${var}" '%s' "${OPT_EXISTING:-beside}"
        note "${shown} differs from Perihelion's: ${!var} (--yes)"
        return
    fi
    have_tty || die "${shown} differs and there is no terminal to ask on; run with --yes"
    printf '\n  %s%s%s differs from Perihelion'"'"'s.\n' "${B}" "${shown}" "${RST}" > /dev/tty
    diff -u "${dest}" "${src}" 2>/dev/null | sed -n '3,14p' | sed 's/^/      /' > /dev/tty || true
    ask_choice "${var}" beside "What should happen to it?" \
        "keep:Keep mine" "new:Take the new one (mine is backed up)" "beside:Write the new one beside mine (.perihelion-new)"
}

# place_config SRC DEST: a file in your home.
place_config() {
    local src=$1 dest=$2 shown choice
    shown=${dest/#"$HOME"/\~}
    if [[ ! -e ${dest} ]]; then
        install -Dm644 "${src}" "${dest}"
        remember_choice "${dest}" new
        CONFIGS_WRITTEN+=("${shown}")
        return
    fi
    cmp -s "${src}" "${dest}" && return 0
    config_choice choice "${dest}" "${src}"
    case "${choice}" in
        keep)
            remember_choice "${dest}" keep
            ;;
        new)
            backup_file "${dest}"
            install -m644 "${src}" "${dest}"
            remember_choice "${dest}" new
            CONFIGS_WRITTEN+=("${shown}")
            ;;
        beside)
            remember_choice "${dest}" beside
            if ! cmp -s "${src}" "${dest}.perihelion-new" 2>/dev/null; then
                install -m644 "${src}" "${dest}.perihelion-new"
                CONFIGS_BESIDE+=("${shown}.perihelion-new")
            fi
            ;;
    esac
}

# place_system_config SRC DEST: the same choice for a file under /etc.
place_system_config() {
    local src=$1 dest=$2 choice
    record "${dest}"
    if [[ ! -e ${dest} ]]; then
        put_system 644 "${src}" "${dest}"
        return
    fi
    cmp -s "${src}" "${dest}" && return 0
    config_choice choice "${dest}" "${src}"
    case "${choice}" in
        keep)
            remember_choice "${dest}" keep
            warn "Kept your ${dest}; Perihelion's is in ${src}"
            ;;
        new)
            backup_file "${dest}"
            put_system 644 "${src}" "${dest}"
            remember_choice "${dest}" new
            ;;
        beside)
            remember_choice "${dest}" beside
            if ! cmp -s "${src}" "${dest}.perihelion-new" 2>/dev/null; then
                put_system 644 "${src}" "${dest}.perihelion-new"
                CONFIGS_BESIDE+=("${dest}.perihelion-new")
            fi
            ;;
    esac
}

# seed_config SRC DEST: files Perihelion's own programs rewrite (colours
# follow the wallpaper, Settings toggles cards): written only when missing.
seed_config() {
    local src=$1 dest=$2
    [[ -e ${dest} ]] && return 0
    install -Dm644 "${src}" "${dest}"
    CONFIGS_WRITTEN+=("${dest/#"$HOME"/\~}")
}

font_path() {
    local f
    # /usr/local/share/fonts: where the PikaOS path puts the Nerd Fonts download.
    f=$(find /usr/share/fonts /usr/local/share/fonts -name 'JetBrainsMonoNerdFont-Regular.ttf' -print -quit 2>/dev/null)
    [[ -n ${f} ]] || die "JetBrainsMono Nerd Font not found (Arch: ttf-jetbrains-mono-nerd; Fedora: jetbrainsmono-nerd-fonts from Terra)"
    printf '%s' "${f}"
}

install_configs() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}" d="${SRC_DIR}/desktop" f tmp font
    local before=${#CONFIGS_WRITTEN[@]} before_beside=${#CONFIGS_BESIDE[@]}
    tmp=$(mktemp -d)
    font=$(font_path)

    # Perihelion Bar, the dock and the shell. The font path is this system's.
    sed "s|@FONT_PATH@|${font}|" "${d}/config/perihelionbar/config.json" > "${tmp}/config.json"
    sed "s|@FONT_PATH@|${font}|" "${d}/config/perihelionbar/shell.json" > "${tmp}/shell.json"
    place_config "${tmp}/config.json" "${cfg}/perihelionbar/config.json"
    place_config "${tmp}/shell.json" "${cfg}/perihelionbar/shell.json"
    for f in matugen.json cava.conf wallpaper-dirs widgets-disabled; do
        seed_config "${d}/config/perihelionbar/${f}" "${cfg}/perihelionbar/${f}"
    done
    mkdir -p "$HOME/Pictures/Wallpapers"

    # The programs around it, as on Perihelion Linux.
    place_config "${d}/config/kitty/kitty.conf" "${cfg}/kitty/kitty.conf"
    place_system_config "${d}/config/kitty/kitty-system.conf" /etc/xdg/kitty/kitty.conf
    place_config "${d}/config/btop/btop.conf" "${cfg}/btop/btop.conf"
    place_config "${d}/config/gtk/settings.ini" "${cfg}/gtk-3.0/settings.ini"
    place_config "${d}/config/gtk/settings.ini" "${cfg}/gtk-4.0/settings.ini"
    place_config "${d}/config/qt6ct/qt6ct.conf" "${cfg}/qt6ct/qt6ct.conf"
    seed_config "${d}/config/fuzzel/fuzzel.ini" "${cfg}/fuzzel/fuzzel.ini"
    seed_config "${d}/config/fastfetch/config.jsonc" "${cfg}/fastfetch/config.jsonc"
    seed_config "${d}/config/cava/config" "${cfg}/cava/config"

    (( WANT_MANGO )) && install_mango_config "${cfg}"
    (( WANT_HYPR )) && install_hyprland_config "${cfg}"
    rm -rf "${tmp}"

    local n=$(( ${#CONFIGS_WRITTEN[@]} - before )) nb=$(( ${#CONFIGS_BESIDE[@]} - before_beside ))
    if (( n == 0 && nb == 0 )); then ok "Configs already in place"; else ok "Configs: ${n} written, ${nb} beside yours"; fi
    return 0
}

# MangoWM: ~/.config/mango/config.conf pulls in cfg/*.conf (Perihelion
# Settings' Mango pages edit those): keys, autostart, look, input, rules.
install_mango_config() {
    local cfg=$1 f
    place_config "${SRC_DIR}/desktop/mango/config.conf" "${cfg}/mango/config.conf"
    for f in "${SRC_DIR}"/desktop/mango/cfg/*.conf; do
        place_config "${f}" "${cfg}/mango/cfg/$(basename "${f}")"
    done
    if check_command mango && ! mango -p -c "${cfg}/mango/config.conf" >> "${LOG_FILE}" 2>&1; then
        warn "mango -p does not accept ~/.config/mango/config.conf (details in the log)"
    fi
    check_mango_radius "${cfg}/mango/cfg/appearance.conf"
}

# SceneFX 0.5 draws rounded window borders badly on NVIDIA's proprietary
# driver (dots along the focused border, wlrfx/scenefx#233). Perihelion
# ships border_radius=0; a kept appearance.conf may still round. Note only:
# the user's file is not changed here.
NVIDIA_DRIVER_FILE=${NVIDIA_DRIVER_FILE:-/proc/driver/nvidia/version}
check_mango_radius() { # APPEARANCE_CONF
    local r
    [[ -r ${NVIDIA_DRIVER_FILE} && -r $1 ]] || return 0
    r=$(sed -n 's/^[[:space:]]*border_radius[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" | tail -n 1)
    (( ${r:-0} > 0 )) || return 0
    # shellcheck disable=SC2088  # text for you to read
    warn "NVIDIA driver and rounded window corners (border_radius=${r}): if you see dots along window borders, set it lower in Settings > Mango > Decoration or in ~/.config/mango/cfg/appearance.conf (0 = square)"
}

# shellcheck disable=SC2088  # "~/..." below is text for you to read, not a path
# Hyprland: everything in one perihelion file, switched on by one line in
# your main config; the rest of that file is never touched.
#   hyprland.lua exists, or no hyprland.conf to keep  -> perihelion.lua + require("perihelion")
#   only hyprland.conf, on a Hyprland that still reads it (before 0.57)
#                                                     -> perihelion.conf + source = ...
# (Hyprland reads Lua from 0.55 and dropped hyprland.conf in 0.57; on 0.55
# and 0.56 a new hyprland.lua would replace your hyprland.conf.)
hyprland_version() {
    Hyprland --version 2>/dev/null | sed -n 's/^Hyprland \([0-9][0-9.]*\).*/\1/p' | head -n 1
}

version_lt() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]; }

hyprland_flavour() { # CONFIG_DIR -> lua | conf
    local dir=$1 v
    if [[ -e ${dir}/hyprland.lua ]]; then echo lua; return; fi
    if [[ -e ${dir}/hyprland.conf ]]; then
        v=$(hyprland_version)
        if [[ -n ${v} ]] && version_lt "${v}" 0.57; then echo conf; return; fi
    fi
    echo lua
}

# add_include FILE LINE COMMENT: one line at the end of FILE, backed up first,
# never twice.
add_include() {
    local file=$1 line=$2 shown=${1/#"$HOME"/\~}
    if grep -qxF "${line}" "${file}"; then
        return 0
    fi
    if ask_yes "Add  ${line}  at the end of ${shown} (the rest stays as it is)?" y; then
        backup_file "${file}"
        printf '\n# Perihelion Bar (delete this line to switch it off)\n%s\n' "${line}" | {
            if [[ ${file} == *.lua ]]; then sed 's/^#/--/'; else cat; fi
        } >> "${file}"
        CONFIGS_WRITTEN+=("${shown} (one line added)")
    else
        warn "Hyprland: add  ${line}  to ${shown} to switch Perihelion Bar on"
    fi
}

# shellcheck disable=SC2088
install_hyprland_config() {
    local cfg=$1 dir="$1/hypr"
    mkdir -p "${dir}"
    case "$(hyprland_flavour "${dir}")" in
        conf)
            place_config "${SRC_DIR}/desktop/hypr/perihelion.conf" "${dir}/perihelion.conf"
            add_include "${dir}/hyprland.conf" 'source = ~/.config/hypr/perihelion.conf'
            ;;
        lua)
            place_config "${SRC_DIR}/desktop/hypr/perihelion.lua" "${dir}/perihelion.lua"
            if [[ ! -e ${dir}/hyprland.lua ]]; then
                if [[ -e ${dir}/hyprland.conf ]]; then
                    warn "~/.config/hypr/hyprland.conf is not read by Hyprland 0.57+ (Lua configs); started a new hyprland.lua beside it"
                fi
                printf '%s\n' '-- Hyprland config (Lua). Your own settings go here.' \
                    'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })' \
                    '' '-- Perihelion Bar (delete this line to switch it off)' 'require("perihelion")' > "${dir}/hyprland.lua"
                CONFIGS_WRITTEN+=("~/.config/hypr/hyprland.lua")
                return
            fi
            if grep -qE '^[[:space:]]*require[[:space:]]*\(?[[:space:]]*["'"'"']perihelion["'"'"']' "${dir}/hyprland.lua"; then
                return 0
            fi
            add_include "${dir}/hyprland.lua" 'require("perihelion")'
            ;;
    esac
}
