# shellcheck shell=bash
# Packages for Perihelion Bar on Arch. Sourced by install.sh.
#
# Official packages go through pacman in one `pacman -Syu --needed`
# transaction: the system is brought up to date together with the new
# packages, as Arch expects (installing from a stale package list fails on
# mirrors that have moved on, and `-Sy` alone is a partial upgrade). AUR
# packages are installed only through an AUR helper you already have.

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
    blueman wev imv fastfetch
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

install_packages() {
    local wanted=("${BUILD_PACKAGES[@]}" "${RUNTIME_PACKAGES[@]}")
    (( WANT_MANGO )) && wanted+=("${MANGO_PACKAGES[@]}")
    (( WANT_HYPR )) && wanted+=("${HYPRLAND_PACKAGES[@]}")
    local pm other=""
    for pm in "${POWER_MANAGERS[@]}"; do check_package "${pm}" && other=${pm}; done
    if [[ -n ${other} ]]; then
        note "${POWER_PROFILES} skipped: ${other} manages power here (the power-profile row stays dim)"
    else
        wanted+=("${POWER_PROFILES}")
    fi

    local missing=()
    mapfile -t missing < <(missing_packages "${wanted[@]}")
    if (( ${#missing[@]} == 0 )); then
        ok "All ${#wanted[@]} packages already installed"
    else
        say "  Missing: ${missing[*]}"
        ask_yes "Update the system and install these ${#missing[@]} packages with pacman?" y ||
            die "these packages are needed: ${missing[*]}"
        need_sudo
        run "pacman: system update + ${#missing[@]} packages" \
            sudo pacman -Syu --needed --noconfirm "${missing[@]}"
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

# The Control Center's rows talk to these services. An existing system may
# manage its network another way, so they are never switched on here; the
# report says which are off and how to turn them on.
check_services() {
    local unit
    for unit in NetworkManager.service bluetooth.service power-profiles-daemon.service; do
        systemctl list-unit-files "${unit}" >/dev/null 2>&1 || continue
        systemctl is-enabled "${unit}" >/dev/null 2>&1 && continue
        warn "${unit} is not enabled (Control Center row stays dim). To use it: sudo systemctl enable --now ${unit}"
    done
}
