# shellcheck shell=bash
# Build Perihelion Bar with Zig 0.17.1 and install its programs. Sourced by
# install.sh (needs SRC_DIR, VERSION, COMMIT and its helpers).

ZIG_VERSION=0.17.1
# The Zig Software Foundation's release signing key (ziglang.org/download).
ZIG_PUBKEY='RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U'
ZIG_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/perihelionbar/zig-${ZIG_VERSION}"
BUILD_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/perihelionbar"

# Compiled programs, by the folder that builds them.
BAR_PROGRAMS=(perihelion-bar perihelion-settings perihelionbar-welcome)
SHELL_PROGRAMS=(perihelion-shell perihelion-lockscreen)
# Scripts from the repository root, installed as they are.
ROOT_SCRIPTS=(perihelion-bar-start perihelion-lock perihelion-theme perihelion-trash perihelion-dock-pin appdrawer perihelionbar-wallpaper)
# Names older installs and configs still call.
COMPAT_LINKS=("perihelionbar:perihelion-bar" "perihelionbar-config:perihelion-settings" "perihelionbar-shell:perihelion-shell")

# --- Zig ------------------------------------------------------------------------------

zig_ok() { [[ -x $1 ]] && [[ $("$1" version 2>/dev/null) == "${ZIG_VERSION}" ]]; }

ensure_zig() {
    if check_command zig && zig_ok "$(command -v zig)"; then
        ZIG=$(command -v zig)
        ok "Zig ${ZIG_VERSION} (system)"
        return
    fi
    if zig_ok "${ZIG_HOME}/zig"; then
        ZIG="${ZIG_HOME}/zig"
        ok "Zig ${ZIG_VERSION} (${ZIG_HOME})"
        return
    fi
    local tmp name url got=0
    tmp=$(mktemp -d)
    for name in "zig-x86_64-linux-${ZIG_VERSION}" "zig-linux-x86_64-${ZIG_VERSION}"; do
        url="https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz"
        log "fetching ${url}"
        if curl -fsSL --retry 3 -o "${tmp}/zig.tar.xz" "${url}" >> "${LOG_FILE}" 2>&1 &&
            curl -fsSL --retry 3 -o "${tmp}/zig.tar.xz.minisig" "${url}.minisig" >> "${LOG_FILE}" 2>&1; then
            got=1
            break
        fi
    done
    (( got )) || die "could not download Zig ${ZIG_VERSION} from ziglang.org"
    run "Zig ${ZIG_VERSION}: signature checked (minisign)" \
        minisign -V -q -P "${ZIG_PUBKEY}" -m "${tmp}/zig.tar.xz" -x "${tmp}/zig.tar.xz.minisig"
    rm -rf "${ZIG_HOME}"
    mkdir -p "${ZIG_HOME}"
    run "Zig ${ZIG_VERSION}: unpacked to ${ZIG_HOME}" tar -xJf "${tmp}/zig.tar.xz" -C "${ZIG_HOME}" --strip-components=1
    rm -rf "${tmp}"
    zig_ok "${ZIG_HOME}/zig" || die "the unpacked Zig does not report ${ZIG_VERSION}"
    ZIG="${ZIG_HOME}/zig"
}

# --- installing files (only when they changed) ------------------------------------------

record() { grep -qxF "$1" "${MANIFEST_FILE}" 2>/dev/null || printf '%s\n' "$1" >> "${MANIFEST_FILE}"; }

# put_system MODE SRC DEST: install as root, but only when DEST differs.
put_system() {
    local mode=$1 src=$2 dest=$3
    record "${dest}"
    if [[ -f ${dest} ]] && cmp -s "${src}" "${dest}" && [[ $(stat -c %a "${dest}") == "${mode}" ]]; then
        return 0
    fi
    # shellcheck disable=SC2024  # the log is yours: written by this shell, not by sudo
    sudo install -Dm"${mode}" "${src}" "${dest}" >> "${LOG_FILE}" 2>&1 || die "could not install ${dest}"
    CHANGED_SYSTEM=$((CHANGED_SYSTEM + 1))
}

put_link() {
    local name=$1 target=$2
    record "/usr/bin/${name}"
    [[ -L /usr/bin/${name} && $(readlink "/usr/bin/${name}") == "${target}" ]] && return 0
    # shellcheck disable=SC2024
    sudo ln -sfn "${target}" "/usr/bin/${name}" >> "${LOG_FILE}" 2>&1 || die "could not link /usr/bin/${name}"
    CHANGED_SYSTEM=$((CHANGED_SYSTEM + 1))
}

# --- building ---------------------------------------------------------------------------

installed_matches() {
    local p line
    for p in "${BAR_PROGRAMS[@]}" "${SHELL_PROGRAMS[@]}"; do
        line=$("/usr/bin/${p}" --version 2>/dev/null) || return 1
        [[ ${line} == "${p} ${VERSION} (${COMMIT})" ]] || return 1
    done
}

build_folder() {
    local folder=$1 out=$2
    (
        cd "${SRC_DIR}/${folder}" || exit 1
        "${ZIG}" build -Doptimize=fast "-Dversion=${VERSION}" "-Dcommit=${COMMIT}" \
            --prefix "${out}" --cache-dir "${BUILD_CACHE}/${folder}"
    ) >> "${LOG_FILE}" 2>&1
}

build_and_install() {
    CHANGED_SYSTEM=0
    mkdir -p "${BUILD_CACHE}"
    : >> "${MANIFEST_FILE}"
    local out="${BUILD_CACHE}/out"

    if (( !OPT_REBUILD )) && [[ ${COMMIT} != unknown ]] && installed_matches; then
        ok "Programs already built at ${COMMIT} (--rebuild builds again)"
    else
        ensure_zig
        export ZIG_GLOBAL_CACHE_DIR="${BUILD_CACHE}/zig-global"
        rm -rf "${out}"
        build_folder perihelionbar "${out}/bar" || die "zig build in perihelionbar/ failed"
        ok "Built the bar, the dock, Settings and Welcome"
        build_folder perihelionbar-shell "${out}/shell" || die "zig build in perihelionbar-shell/ failed"
        ok "Built the shell (cards, Glance, overview) and the lock screen"
        need_sudo
        local p
        for p in "${BAR_PROGRAMS[@]}"; do put_system 755 "${out}/bar/bin/${p}" "/usr/bin/${p}"; done
        for p in "${SHELL_PROGRAMS[@]}"; do put_system 755 "${out}/shell/bin/${p}" "/usr/bin/${p}"; done
        local bin
        for bin in "${BAR_PROGRAMS[@]}" "${SHELL_PROGRAMS[@]}"; do
            if ldd "/usr/bin/${bin}" 2>/dev/null | grep -q 'not found'; then
                die "/usr/bin/${bin} is missing shared libraries: $(ldd "/usr/bin/${bin}" | grep 'not found' | tr -s ' \n' ' ')"
            fi
        done
    fi

    need_sudo
    install_support_files
    if (( CHANGED_SYSTEM )); then
        ok "Installed ${CHANGED_SYSTEM} changed file(s) under /usr and /etc"
    else
        ok "Programs and system files already up to date"
    fi
    install_drawer_qml
}

install_support_files() {
    local s f link
    for s in "${ROOT_SCRIPTS[@]}"; do put_system 755 "${SRC_DIR}/${s}" "/usr/bin/${s}"; done
    for f in "${SRC_DIR}"/desktop/bin/*; do put_system 755 "${f}" "/usr/bin/$(basename "${f}")"; done
    # The bar calls this after a wallpaper change; Perihelion themes with its own engine.
    local wrapper
    wrapper=$(mktemp)
    printf '#!/bin/sh\n# Perihelion Bar calls this after a wallpaper change.\nexec perihelion-theme --force "$@"\n' > "${wrapper}"
    put_system 755 "${wrapper}" /usr/bin/perihelionbar-matugen
    rm -f "${wrapper}"
    for link in "${COMPAT_LINKS[@]}"; do put_link "${link%%:*}" "${link#*:}"; done

    # Lock screen: its PAM stack (password check as at login).
    place_system_config "${SRC_DIR}/pam/perihelion-lock" /etc/pam.d/perihelion-lock

    # Launchers and icons.
    put_system 644 "${SRC_DIR}/perihelion-settings.desktop" /usr/share/applications/perihelion-settings.desktop
    put_system 644 "${SRC_DIR}/perihelionbar-welcome.desktop" /usr/share/applications/perihelionbar-welcome.desktop
    put_system 644 "${SRC_DIR}/appdrawer.desktop" /usr/share/applications/appdrawer.desktop
    # The "Perihelion (MangoWM)" login session (perihelion-session seeds
    # ~/.config/mango when it is missing, then runs Mango). The stock Mango
    # session stays.
    put_system 644 "${SRC_DIR}/desktop/wayland-sessions/perihelion.desktop" /usr/share/wayland-sessions/perihelion.desktop
    local png size name
    for png in "${SRC_DIR}"/assets/icons/perihelion-settings/*.png; do
        size=$(basename "${png}" .png)
        for name in perihelion-settings io.github.ciphervlt.perihelion.Settings; do
            put_system 644 "${png}" "/usr/share/icons/hicolor/${size}x${size}/apps/${name}.png"
        done
    done
    for name in perihelion-trash perihelion-trash-full; do
        put_system 644 "${SRC_DIR}/assets/icons/${name}.svg" "/usr/share/icons/hicolor/scalable/apps/${name}.svg"
    done

    # Shared data the programs read from /usr/share/perihelion: colour
    # palettes, the pristine configs (Settings' "restore default", Super+H).
    while IFS= read -r -d '' f; do
        put_system 644 "${f}" "/usr/share/perihelion/palettes/${f#"${SRC_DIR}"/theme/palettes/}"
    done < <(find "${SRC_DIR}/theme/palettes" -type f -print0)
    put_system 644 "${SRC_DIR}/desktop/config/fastfetch/config.jsonc" /usr/share/perihelion/fastfetch/config.jsonc
    put_system 644 "${SRC_DIR}/desktop/config/fuzzel/fuzzel.ini" /usr/share/perihelion/fuzzel/fuzzel.ini
    put_system 644 "${SRC_DIR}/desktop/config/cava/config" /usr/share/perihelion/cava/config
    put_system 644 "${SRC_DIR}/desktop/config/gtk/settings.ini" /usr/share/perihelion/gtk/settings.ini
    put_system 644 "${SRC_DIR}/desktop/config/qt6ct/colors/Catppuccin-Macchiato.conf" /usr/share/qt6ct/colors/Catppuccin-Macchiato.conf
    for f in "${SRC_DIR}"/desktop/mango/config.conf "${SRC_DIR}"/desktop/mango/cfg/*.conf; do
        put_system 644 "${f}" "/usr/share/perihelion/mango/${f#"${SRC_DIR}"/desktop/mango/}"
    done
    put_system 644 "${SRC_DIR}/desktop/hypr/perihelion.lua" /usr/share/perihelion/hypr/perihelion.lua
    printf '%s\n' "$(git -C "${SRC_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)" > "${BUILD_CACHE}/commit"
}

# The app drawer's QML runs from ~/.local/share/perihelionbar/appdrawer
# (appdrawer prefers that copy). It is the installer's copy, not a config:
# it follows each update. Your pinned apps live in favourites.json and are kept.
install_drawer_qml() {
    local dest="${XDG_DATA_HOME:-$HOME/.local/share}/perihelionbar/appdrawer" f changed=0
    mkdir -p "${dest}"
    for f in "${SRC_DIR}"/quickshell/appdrawer/*.qml; do
        if ! cmp -s "${f}" "${dest}/$(basename "${f}")"; then
            install -m644 "${f}" "${dest}/"
            changed=1
        fi
    done
    [[ -f ${dest}/favourites.json ]] || { printf '{ "ids": [] }\n' > "${dest}/favourites.json"; changed=1; }
    if (( changed )); then ok "App drawer QML in ${dest}"; else ok "App drawer QML already up to date"; fi
}
