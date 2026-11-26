# shellcheck shell=bash
# Images older installers left behind. Sourced by install.sh.
#
# Looks in the places those installers wrote to: ~/.local/share/perihelionbar
# (all of it: the Welcome logo, the copied icons) and the system icon names
# perihelionbar-config / perihelionbar-welcome. A file goes only when its
# SHA-256 is listed in scripts/old-images.sha256.

# old_image_sums FILE: the 64-hex sums from FILE, one per line.
old_image_sums() {
    sed -n -E 's/^([0-9a-f]{64})[[:space:]].*/\1/p' "$1"
}

# old_image_candidates HOME_DIR: every file worth checking, one per line.
# PERIHELION_SYSROOT (tests only) is put in front of the /usr paths.
old_image_candidates() {
    local home=$1 root=${PERIHELION_SYSROOT:-} d
    d="${home}/.local/share/perihelionbar"
    if [[ -d ${d} ]]; then
        find "${d}" -xdev -type f \( -name '*.png' -o -name '*.svg' -o -name '*.jpg' \) -size -8M 2>/dev/null
    fi
    for d in "${root}"/usr/share/icons/hicolor/*/apps; do
        [[ -d ${d} ]] || continue
        find "${d}" -maxdepth 1 -type f \( -name 'perihelionbar-config.*' -o -name 'perihelionbar-welcome.*' \) 2>/dev/null
    done
    find "${root}/usr/share/pixmaps" -maxdepth 1 -type f -name 'perihelionbar*' 2>/dev/null || true
}

# remove_old_images [HOME_DIR] [SUMS_FILE]
remove_old_images() {
    local home=${1:-$HOME} list=${2:-${SRC_DIR}/scripts/old-images.sha256}
    local sums f sum n=0 icons=0
    [[ -r ${list} ]] || { warn "old-images.sha256 missing; skipped removing old images"; return 0; }
    sums=$(old_image_sums "${list}")
    while IFS= read -r f; do
        [[ -n ${f} && -f ${f} && ! -L ${f} ]] || continue
        sum=$(sha256sum "${f}" | cut -d' ' -f1)
        if ! grep -qxF "${sum}" <<< "${sums}"; then
            log "kept ${f} (not one of the old images)"
            continue
        fi
        if [[ ${f} == "${home}"/* ]]; then
            rm -f -- "${f}"
        else
            need_sudo
            sudo rm -f -- "${f}"
            [[ ${f} == "${PERIHELION_SYSROOT:-}"/usr/share/icons/* ]] && icons=1
        fi
        log "removed old image ${f} (${sum})"
        n=$((n + 1))
    done < <(old_image_candidates "${home}")
    # Folders that only held those images.
    rmdir "${home}/.local/share/perihelionbar/assets/icons" "${home}/.local/share/perihelionbar/assets" 2>/dev/null || true
    if (( icons )) && [[ -z ${PERIHELION_SYSROOT:-} ]] && command -v gtk-update-icon-cache >/dev/null; then
        sudo gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
    fi
    if (( n )); then ok "Removed ${n} old image(s) earlier versions left behind"; fi
    return 0
}
