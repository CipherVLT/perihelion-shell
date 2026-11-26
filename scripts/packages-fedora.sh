# shellcheck shell=bash
# Packages for Perihelion Bar on Fedora 45 and later (a regular install, not
# Perihelion Linux and not an image-based system). Sourced by install.sh.
#
# dnf installs what is missing in one transaction, with --refresh so the
# package metadata is current (stale metadata asks mirrors for files they no
# longer have). A few packages are not in Fedora's own repositories: MangoWM,
# matugen, the JetBrainsMono Nerd Font, the Nerd Font symbols and the Bibata
# cursor come from Terra (repos.fyralabs.com), the repository Perihelion
# Linux uses too. (Quickshell is in Fedora itself.)
# Terra is added only if one of those is missing and you say yes.

# What the build needs.
BUILD_PACKAGES=(
    git-core curl tar xz minisign pkgconf-pkg-config
    wayland-devel wayland-protocols-devel libxkbcommon-devel freetype-devel gdk-pixbuf2-devel
    gtk4-devel libadwaita-devel glib2-devel cairo-devel pango-devel pam-devel
)

# What Perihelion Bar uses while running (as on Perihelion Linux).
RUNTIME_PACKAGES=(
    quickshell                                  # the app drawer
    python3 python3-gobject                     # theming, wallpaper picker, dock pins
    jq libnotify zenity                         # weather, notifications, dialogs
    fuzzel kitty mako btop cmatrix              # launcher, terminal, notifications, extras the bar opens
    swaybg swayidle wlsunset wlr-randr          # wallpaper, idle lock, night light, displays
    mate-polkit                                 # password prompts for apps
    grim slurp wl-clipboard                     # screenshots
    playerctl brightnessctl                     # media and brightness keys
    pipewire wireplumber pipewire-pulseaudio pulseaudio-utils cava pavucontrol
    fastfetch
    matugen                                     # Material You colors from the wallpaper (Terra)
    jetbrainsmono-nerd-fonts nerdfontssymbolsonly-nerd-fonts   # (Terra)
    dejavu-sans-mono-fonts rsms-inter-vf-fonts google-noto-sans-fonts google-noto-color-emoji-fonts
    librsvg2 adwaita-icon-theme bibata-cursor-theme qt6ct
    xdg-desktop-portal-gtk xdg-user-dirs dbus-tools   # dbus-tools: dbus-update-activation-environment
    NetworkManager bluez upower                 # Wi-Fi, Bluetooth, battery rows
    xorg-x11-server-Xwayland xdg-desktop-portal xdg-utils
    polkit gnome-keyring gvfs
    util-linux procps-ng                        # flock, setsid, pgrep (the session starter)
)

# The power-profile row. Fedora ships tuned (with tuned-ppd, which offers the
# same profiles); power-profiles-daemon only where nothing manages power.
POWER_PROFILES=power-profiles-daemon
POWER_MANAGERS=(tuned tuned-ppd tlp auto-cpufreq)

MANGO_PACKAGES=(mangowm xdg-desktop-portal-wlr)   # mangowm: Terra
HYPRLAND_PACKAGES=(hyprland xdg-desktop-portal-hyprland)

# Not needed by Perihelion Bar; only with --extras.
EXTRA_PACKAGES=(imv blueman wev)

# From Terra when Fedora's repositories don't have them.
TERRA_PACKAGES=(mangowm matugen jetbrainsmono-nerd-fonts nerdfontssymbolsonly-nerd-fonts bibata-cursor-theme)
# shellcheck disable=SC2016  # $releasever is dnf's, not the shell's
TERRA_URL='https://repos.fyralabs.com/terra$releasever'

check_package() { rpm -q --whatprovides "$1" >/dev/null 2>&1; }
check_command() { command -v "$1" >/dev/null 2>&1; }

missing_packages() {
    local p
    for p in "$@"; do check_package "${p}" || printf '%s\n' "${p}"; done
}

terra_enabled() {
    check_package terra-release || dnf repolist --enabled 2>/dev/null | grep -qiE '^terra[[:space:]]'
}

DNF_OUT=""
# dnf_tx ARGS...: one dnf transaction, output to the log and DNF_OUT.
dnf_tx() {
    DNF_OUT=$(mktemp)
    log "\$ sudo dnf $*"
    # shellcheck disable=SC2024  # the output file is ours, not root's
    sudo dnf "$@" > "${DNF_OUT}" 2>&1
    local rc=$?
    cat "${DNF_OUT}" >> "${LOG_FILE}" 2>/dev/null || true
    return "${rc}"
}

dnf_download_failed() {
    grep -qiE '404|curl error|cannot download|failed to download|status code: 4|could not resolve host|librepo' "${DNF_OUT}" 2>/dev/null
}

# Terra, the way its documentation adds it: the terra-release package from
# the repository itself (it brings the repo file and the signing keys).
add_terra() {
    need_sudo
    if dnf_tx install -y --nogpgcheck --repofrompath "terra,${TERRA_URL}" terra-release; then
        ok "Terra repository added (terra-release)"
    else
        tail -n 6 "${DNF_OUT}" | sed 's/^/      /'
        die "could not add the Terra repository (see the log)"
    fi
}

# dnf_install PKGS...: refreshed metadata + install; on a download failure
# explain it and offer one clean metadata refresh and a retry.
dnf_install() {
    need_sudo
    local args=(install -y --refresh --setopt=install_weak_deps=False)
    if dnf_tx "${args[@]}" "$@"; then ok "dnf: $# packages"; return 0; fi
    if ! dnf_download_failed; then
        tail -n 8 "${DNF_OUT}" | sed 's/^/      /'
        die "dnf could not install the packages (the lines above and the log say why)"
    fi
    printf '\n  %s%s dnf could not download some packages.%s\n' "${YLW}${B}" "${G_WARN}" "${RST}"
    grep -iE '404|curl error|cannot download|failed to download' "${DNF_OUT}" | head -n 4 | sed 's/^/      /'
    printf '  The package metadata or a mirror is out of date. Clearing the cached\n'
    printf '  metadata (dnf clean metadata) and downloading it again usually fixes it.\n'
    if ask_yes "Run dnf clean metadata and try once more?" y; then
        dnf_tx clean metadata || true
        if dnf_tx "${args[@]}" "$@"; then ok "dnf: metadata refreshed, $# packages"; return 0; fi
        die "dnf still could not download the packages after a metadata refresh; try again later or another mirror (see the log)"
    fi
    die "packages not installed. Run sudo dnf clean metadata, then the installer again"
}

install_packages() {
    local wanted=("${BUILD_PACKAGES[@]}" "${RUNTIME_PACKAGES[@]}")
    (( WANT_MANGO )) && wanted+=("${MANGO_PACKAGES[@]}")
    (( WANT_HYPR )) && wanted+=("${HYPRLAND_PACKAGES[@]}")
    (( OPT_EXTRAS )) && wanted+=("${EXTRA_PACKAGES[@]}")
    local pm other=""
    for pm in "${POWER_MANAGERS[@]}"; do check_package "${pm}" && other=${pm}; done
    if [[ -n ${other} ]]; then
        note "${POWER_PROFILES} skipped: ${other} manages power here"
    else
        wanted+=("${POWER_PROFILES}")
    fi

    local missing=()
    mapfile -t missing < <(missing_packages "${wanted[@]}")
    if (( ${#missing[@]} == 0 )); then
        ok "All ${#wanted[@]} packages already installed"
        return 0
    fi

    # Terra first, if something only it has is missing.
    local from_terra=() p t
    for p in "${missing[@]}"; do
        for t in "${TERRA_PACKAGES[@]}"; do [[ ${p} == "${t}" ]] && from_terra+=("${p}"); done
    done
    if (( ${#from_terra[@]} )) && ! terra_enabled; then
        say "  Not in Fedora's repositories: ${from_terra[*]}"
        if ask_yes "Add the Terra repository (repos.fyralabs.com, also used by Perihelion Linux) for them?" y; then
            add_terra
        else
            die "these come from Terra and are needed: ${from_terra[*]}"
        fi
    fi

    say "  Missing: ${missing[*]}"
    ask_yes "Install these ${#missing[@]} packages with dnf?" y || die "these packages are needed: ${missing[*]}"
    dnf_install "${missing[@]}"
    PKGS_INSTALLED+=("${missing[@]}")
    local still=()
    mapfile -t still < <(missing_packages "${wanted[@]}")
    (( ${#still[@]} == 0 )) || die "still missing after dnf: ${still[*]}"
    # Strata (Super+E) has no Fedora package; Perihelion Linux builds it itself.
    check_command strata || note "Strata (the file manager on Super+E) has no Fedora package; Super+E opens nothing until you install one and bind it"
}
