# shellcheck shell=bash
# Packages for Perihelion Bar on Arch and Arch-based distros (CachyOS with
# its v3/v4 repos, EndeavourOS, Garuda, ...). Sourced by install.sh.
#
# Official packages go through pacman in one `pacman -Syu --needed`
# transaction: the package database is refreshed and the system brought up
# to date together with the new packages, as Arch expects (installing from a
# stale database asks mirrors for versions they no longer have: 404; `-Sy`
# alone is a partial upgrade). If a download still fails, the installer says
# why in plain words and offers one `pacman -Syyu` (a forced refresh) and a
# retry. Only what Perihelion Bar uses is installed; the extras need
# --extras. AUR packages only through an AUR helper you already have.

# What the build needs (the -devel headers on Arch come with the libraries).
BUILD_PACKAGES=(
    base-devel git curl tar xz minisign pkgconf
    wayland wayland-protocols libxkbcommon freetype2 gdk-pixbuf2
    gtk4 libadwaita glib2 cairo pango pam
)

# What Perihelion Bar uses while running, on any window manager.
RUNTIME_PACKAGES=(
    quickshell                                  # the app drawer
    python python-gobject                       # theming, wallpaper picker, dock pins
    jq libnotify zenity                         # weather, notifications, dialogs
    fuzzel kitty mako btop cmatrix              # launcher, terminal, notifications, extras
    swaybg swayidle wlsunset wlr-randr          # wallpaper, idle lock, night light, displays
    mate-polkit                                 # password prompts for apps
    grim slurp wl-clipboard                     # screenshots
    playerctl brightnessctl                     # media and brightness keys
    pipewire wireplumber pipewire-pulse libpulse cava pavucontrol
    fastfetch
    matugen                                     # Material You colors from the wallpaper
    ttf-jetbrains-mono-nerd ttf-dejavu inter-font noto-fonts noto-fonts-emoji
    librsvg adwaita-icon-theme qt6ct
    xdg-desktop-portal-gtk xdg-user-dirs dbus
    # What the Control Center and the session lean on, as on Perihelion Linux
    networkmanager bluez bluez-utils upower     # Wi-Fi, Bluetooth, battery rows
    xorg-xwayland xdg-desktop-portal xdg-utils  # X11 apps, portals, xdg-open
    polkit gnome-keyring gvfs                   # password prompts, keyring, Trash
    ttf-nerd-fonts-symbols-mono
)

# Not needed by Perihelion Bar; only with --extras.
EXTRA_PACKAGES=(imv blueman wev)               # image viewer, Bluetooth manager, input viewer

# The power-profile row. Not with another power manager: they conflict, and
# replacing yours is not the installer's call.
POWER_PROFILES=power-profiles-daemon
POWER_MANAGERS=(tlp auto-cpufreq tuned)

MANGO_PACKAGES=(mangowm xdg-desktop-portal-wlr)
HYPRLAND_PACKAGES=(hyprland xdg-desktop-portal-hyprland)

# Not in Arch's repositories: Strata (the file manager on Super+E) and the
# Bibata cursor that Perihelion Linux uses.
AUR_PACKAGES=(strata-bin bibata-cursor-theme-bin)

check_package() { pacman -Qq "$1" >/dev/null 2>&1; }
check_command() { command -v "$1" >/dev/null 2>&1; }

# Packages (or anything that provides them, like quickshell-git for
# quickshell) not installed yet. `pacman -T` answers with the missing ones.
missing_packages() {
    pacman -T "$@" 2>/dev/null || true
}

aur_helper() {
    local h
    for h in paru yay; do
        if check_command "${h}"; then
            printf '%s' "${h}"
            return 0
        fi
    done
    return 1
}

# CachyOS (its own ID, or its repos in pacman.conf).
is_cachyos() {
    [[ ${DISTRO_ID:-} == cachyos ]] || grep -qsE '^\[cachyos' /etc/pacman.conf
}

# What to do about an out-of-date mirror list on this distro.
mirror_hint() {
    if is_cachyos; then
        printf 'sudo cachyos-rate-mirrors   (CachyOS: picks fresh mirrors for every CachyOS repo)'
    elif check_command eos-rankmirrors; then
        printf 'eos-rankmirrors   (EndeavourOS)'
    elif check_command rate-mirrors; then
        printf 'rate-mirrors   (or your distro'"'"'s mirror tool)'
    elif check_command reflector; then
        printf 'sudo reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist'
    else
        printf 'edit /etc/pacman.d/mirrorlist and put a current mirror first'
    fi
}

PACMAN_OUT=""
# pacman_tx FLAGS PKGS...: one pacman transaction, its output in the log and
# in PACMAN_OUT (for the failure check below).
pacman_tx() {
    local flags=$1
    shift
    PACMAN_OUT=$(mktemp)
    log "\$ sudo pacman ${flags} --needed --noconfirm $*"
    # shellcheck disable=SC2024  # the output file is ours, not root's
    sudo pacman "${flags}" --needed --noconfirm "$@" > "${PACMAN_OUT}" 2>&1
    local rc=$?
    cat "${PACMAN_OUT}" >> "${LOG_FILE}" 2>/dev/null || true
    return "${rc}"
}

# Did the last transaction fail because files could not be downloaded
# (a 404 from the mirrors: database or mirror list out of date)?
pacman_download_failed() {
    grep -qiE '404|failed retrieving file|failed to retrieve some files|could not resolve host|error: failed to synchronize' "${PACMAN_OUT}" 2>/dev/null
}

# pacman_install PKGS...: refresh + upgrade + install; on a download failure
# explain it and offer one forced refresh and a retry. Never fails silently.
pacman_install() {
    need_sudo
    if pacman_tx -Syu "$@"; then ok "pacman: system update + $# packages"; return 0; fi
    if ! pacman_download_failed; then
        tail -n 8 "${PACMAN_OUT}" | sed 's/^/      /'
        die "pacman could not install the packages (the lines above and the log say why)"
    fi
    printf '\n  %s%s pacman could not download some packages.%s\n' "${YLW}${B}" "${G_WARN}" "${RST}"
    grep -iE '404|failed retrieving|failed to retrieve|could not resolve' "${PACMAN_OUT}" | head -n 4 | sed 's/^/      /'
    printf '  Your mirror list or package database is out of date: the mirrors no longer\n'
    printf '  have the versions your database lists. A forced refresh (pacman -Syyu)\n'
    printf '  usually fixes it. If it does not, refresh the mirror list:\n      %s\n' "$(mirror_hint)"
    log "download failure; mirror hint: $(mirror_hint)"
    if ask_yes "Run pacman -Syyu (force-refresh the database) and try once more?" y; then
        if pacman_tx -Syyu "$@"; then ok "pacman: database refreshed, system update + $# packages"; return 0; fi
        if pacman_download_failed; then
            die "the mirrors still return errors after a forced refresh. Refresh the mirror list ($(mirror_hint)), then run the installer again"
        fi
        die "pacman could not install the packages after the refresh (see the log)"
    fi
    die "packages not installed. Refresh the database and mirrors ($(mirror_hint)), then run the installer again"
}

install_packages() {
    local wanted=("${BUILD_PACKAGES[@]}" "${RUNTIME_PACKAGES[@]}")
    (( WANT_MANGO )) && wanted+=("${MANGO_PACKAGES[@]}")
    (( WANT_HYPR )) && wanted+=("${HYPRLAND_PACKAGES[@]}")
    (( OPT_EXTRAS )) && wanted+=("${EXTRA_PACKAGES[@]}")
    local pm other=""
    for pm in "${POWER_MANAGERS[@]}"; do check_package "${pm}" && other=${pm}; done
    if [[ -n ${other} ]]; then
        note "${POWER_PROFILES} skipped: ${other} manages power here (the power-profile row stays dim)"
    else
        wanted+=("${POWER_PROFILES}")
    fi
    is_cachyos && note "CachyOS: packages come from your CachyOS repos (v3/v4 where you have them)"

    local missing=()
    mapfile -t missing < <(missing_packages "${wanted[@]}")
    if (( ${#missing[@]} == 0 )); then
        ok "All ${#wanted[@]} packages already installed"
    else
        say "  Missing: ${missing[*]}"
        ask_yes "Refresh the package database, update the system and install these ${#missing[@]} packages?" y ||
            die "these packages are needed: ${missing[*]}"
        pacman_install "${missing[@]}"
        PKGS_INSTALLED+=("${missing[@]}")
        local still=()
        mapfile -t still < <(missing_packages "${wanted[@]}")
        (( ${#still[@]} == 0 )) || die "still missing after pacman: ${still[*]}"
    fi

    local aur_missing=() p
    for p in "${AUR_PACKAGES[@]}"; do
        check_package "${p}" || check_package "${p%-bin}" || aur_missing+=("${p}")
    done
    (( ${#aur_missing[@]} )) || { ok "AUR packages already installed"; return 0; }
    local helper
    if helper=$(aur_helper); then
        if ask_yes "Install ${aur_missing[*]} from the AUR with ${helper}?" y; then
            # The helper runs as you and asks sudo itself; its prompts go to the terminal.
            if "${helper}" -S --needed --noconfirm "${aur_missing[@]}" >> "${LOG_FILE}" 2>&1 < /dev/null; then
                ok "AUR: ${aur_missing[*]}"
                PKGS_INSTALLED+=("${aur_missing[@]}")
            else
                warn "AUR install failed (see the log); later: ${helper} -S ${aur_missing[*]}"
            fi
        fi
    else
        warn "Not installed (AUR, no AUR helper found): ${aur_missing[*]}. Install paru or yay, then: paru -S ${aur_missing[*]}"
    fi
}
