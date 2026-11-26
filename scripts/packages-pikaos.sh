# shellcheck shell=bash
# Packages for Perihelion Bar on PikaOS 4 (Debian sid based, apt; pikman is
# its wrapper around apt). Sourced by install.sh.
#
# Everything comes from PikaOS's own repository (ppa.pika-os.com), MangoWM,
# Quickshell and matugen included. apt refreshes the package lists first,
# then installs what is missing in one `apt-get install` (no recommends). A
# failed download is explained, the lists are refreshed once more and the
# install retried. Not in PikaOS's repository: the JetBrainsMono Nerd Font
# (the bar's font), downloaded from the Nerd Fonts release after asking and
# checked against its SHA-256; and Strata (Super+E), which is skipped.

BUILD_PACKAGES=(
    build-essential git curl tar xz-utils minisign pkgconf
    libwayland-dev wayland-protocols libxkbcommon-dev libfreetype-dev libgdk-pixbuf-2.0-dev
    libgtk-4-dev libadwaita-1-dev libglib2.0-dev libcairo2-dev libpango1.0-dev libpam0g-dev
)

RUNTIME_PACKAGES=(
    quickshell                                  # the app drawer
    python3 python3-gi gir1.2-gtk-4.0           # theming, wallpaper picker, dock pins
    jq libnotify-bin zenity                     # weather, notifications, dialogs
    fuzzel kitty mako-notifier btop cmatrix     # launcher, terminal, notifications, extras the bar opens
    swaybg swayidle wlsunset wlr-randr          # wallpaper, idle lock, night light, displays
    mate-polkit                                 # password prompts for apps
    grim slurp wl-clipboard                     # screenshots
    playerctl brightnessctl                     # media and brightness keys
    pipewire wireplumber pipewire-pulse pulseaudio-utils cava pavucontrol
    fastfetch
    matugen                                     # Material You colors from the wallpaper
    fontconfig fonts-nerd-symbols fonts-dejavu-core fonts-inter fonts-noto-core fonts-noto-color-emoji
    librsvg2-common adwaita-icon-theme bibata-cursor-theme qt6ct
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-user-dirs xdg-utils
    dbus-bin dbus-user-session                  # dbus-update-activation-environment
    network-manager bluez upower                # Wi-Fi, Bluetooth, battery rows
    xwayland polkitd gnome-keyring gvfs
    util-linux procps systemd                   # flock, setsid, pgrep, busctl (the session starter)
)

POWER_PROFILES=power-profiles-daemon
POWER_MANAGERS=(tuned tlp auto-cpufreq)

MANGO_PACKAGES=(mangowm xdg-desktop-portal-wlr)
HYPRLAND_PACKAGES=(hyprland xdg-desktop-portal-hyprland)

# Not needed by Perihelion Bar; only with --extras.
EXTRA_PACKAGES=(imv blueman wev)

# The bar's font: Nerd Fonts' JetBrainsMono release archive, pinned.
NERD_FONT_VERSION=v3.5.1
NERD_FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONT_VERSION}/JetBrainsMono.tar.xz"
NERD_FONT_SHA256=04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf
NERD_FONT_DIR=/usr/local/share/fonts/JetBrainsMonoNerdFont

check_package() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
check_command() { command -v "$1" >/dev/null 2>&1; }

missing_packages() {
    local p
    for p in "$@"; do check_package "${p}" || printf '%s\n' "${p}"; done
}

APT_OUT=""
# apt_tx ARGS...: one apt-get run, output to the log and APT_OUT.
apt_tx() {
    APT_OUT=$(mktemp)
    log "\$ sudo apt-get $*"
    # shellcheck disable=SC2024  # the output file is ours, not root's
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@" > "${APT_OUT}" 2>&1
    local rc=$?
    cat "${APT_OUT}" >> "${LOG_FILE}" 2>/dev/null || true
    return "${rc}"
}

apt_download_failed() {
    grep -qiE '404 +not found|failed to fetch|unable to fetch some archives|hash sum mismatch|could not resolve|temporary failure resolving' "${APT_OUT}" 2>/dev/null
}

# apt_install PKGS...: refresh the lists, install; on a download failure
# explain it and offer one clean refresh and a retry.
apt_install() {
    need_sudo
    local args=(install -y --no-install-recommends)
    apt_tx update || true
    if apt_tx "${args[@]}" "$@"; then ok "apt: $# packages"; return 0; fi
    if ! apt_download_failed; then
        tail -n 8 "${APT_OUT}" | sed 's/^/      /'
        die "apt could not install the packages (the lines above and the log say why)"
    fi
    printf '\n  %s%s apt could not download some packages.%s\n' "${YLW}${B}" "${G_WARN}" "${RST}"
    grep -iE '404|failed to fetch|hash sum mismatch|could not resolve' "${APT_OUT}" | head -n 4 | sed 's/^/      /'
    printf '  The package lists are out of date: the repository has moved on to newer\n'
    printf '  versions. Refreshing them (apt-get update) and trying again usually fixes it.\n'
    printf '  If not, update the system first: pikman upgrade (or sudo apt full-upgrade).\n'
    if ask_yes "Clean the package cache, refresh the lists and try once more?" y; then
        apt_tx clean || true
        apt_tx update || true
        if apt_tx "${args[@]}" "$@"; then ok "apt: lists refreshed, $# packages"; return 0; fi
        die "apt still could not download the packages; update the system (pikman upgrade), then run the installer again"
    fi
    die "packages not installed. Run sudo apt-get update (or pikman upgrade), then the installer again"
}

nerd_font_installed() {
    [[ -n $(find /usr/share/fonts /usr/local/share/fonts -name 'JetBrainsMonoNerdFont-Regular.ttf' -print -quit 2>/dev/null) ]]
}

# The JetBrainsMono Nerd Font is not packaged for PikaOS. Download the Nerd
# Fonts release archive (SIL Open Font License), check its SHA-256 against
# the pinned value, and install its TTFs and licence under /usr/local.
install_nerd_font() {
    if nerd_font_installed; then ok "JetBrainsMono Nerd Font already installed"; return 0; fi
    say "  The JetBrainsMono Nerd Font (the bar's font) is not in PikaOS's repository."
    ask_yes "Download it from the Nerd Fonts ${NERD_FONT_VERSION} release (github.com/ryanoasis/nerd-fonts, checked against its SHA-256) into ${NERD_FONT_DIR}?" y ||
        die "Perihelion Bar needs the JetBrainsMono Nerd Font; install it, then run the installer again"
    local tmp f
    tmp=$(mktemp -d)
    log "\$ curl ${NERD_FONT_URL}"
    curl --fail --location --silent --show-error --retry 3 -o "${tmp}/font.tar.xz" "${NERD_FONT_URL}" >> "${LOG_FILE}" 2>&1 ||
        { rm -rf "${tmp}"; die "could not download ${NERD_FONT_URL}"; }
    if [[ $(sha256sum "${tmp}/font.tar.xz" | cut -d' ' -f1) != "${NERD_FONT_SHA256}" ]]; then
        rm -rf "${tmp}"
        die "the downloaded font archive does not match its SHA-256; nothing was installed"
    fi
    tar -xJf "${tmp}/font.tar.xz" -C "${tmp}" --wildcards 'JetBrainsMonoNerdFont-*.ttf' OFL.txt >> "${LOG_FILE}" 2>&1 ||
        { rm -rf "${tmp}"; die "could not unpack the font archive"; }
    for f in "${tmp}"/JetBrainsMonoNerdFont-*.ttf "${tmp}/OFL.txt"; do
        put_system 644 "${f}" "${NERD_FONT_DIR}/$(basename "${f}")"
    done
    rm -rf "${tmp}"
    # shellcheck disable=SC2024  # the log is ours
    sudo fc-cache -f "${NERD_FONT_DIR}" >> "${LOG_FILE}" 2>&1 || true
    ok "JetBrainsMono Nerd Font ${NERD_FONT_VERSION} in ${NERD_FONT_DIR}"
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
    else
        say "  Missing: ${missing[*]}"
        ask_yes "Refresh the package lists and install these ${#missing[@]} packages with apt?" y ||
            die "these packages are needed: ${missing[*]}"
        apt_install "${missing[@]}"
        PKGS_INSTALLED+=("${missing[@]}")
        local still=()
        mapfile -t still < <(missing_packages "${wanted[@]}")
        (( ${#still[@]} == 0 )) || die "still missing after apt: ${still[*]}"
    fi
    install_nerd_font
    check_command strata || note "Strata (the file manager on Super+E) has no PikaOS package; Super+E opens nothing until you install one and bind it"
}
