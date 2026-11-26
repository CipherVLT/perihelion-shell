#!/usr/bin/env bash
# Perihelion Bar installer for Arch Linux and Arch-based distros (CachyOS,
# EndeavourOS, Garuda, ...) and Fedora 45 or later. On Perihelion Linux the
# shell is already part of the system; this says so and changes nothing.
#
#   curl -fsSL https://raw.githubusercontent.com/CipherVLT/perihelion-shell/main/install.sh | bash
#   or, from a checkout:  ./install.sh [--yes] [--wm=mango|hyprland|both]
#
# Installs Perihelion Bar: the bar and dock, desktop cards, Glance, the
# window overview, Settings (with Updates), the lock screen, the app drawer,
# wallpaper theming and the wallpaper picker, wired into MangoWM and/or
# Hyprland. Run it again any time: it changes only what is missing or out of
# date, and never replaces one of your files without asking.
#
# Everything lives in functions and the last line calls main, so a download
# cut off halfway runs nothing at all.

set -Eeuo pipefail

PERIHELION_REPO_URL=${PERIHELION_REPO_URL:-https://github.com/CipherVLT/perihelion-shell.git}
PERIHELION_BRANCH=${PERIHELION_BRANCH:-main}
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/perihelionbar"
LOG_FILE="${STATE_DIR}/install.log"
ANSWERS_FILE="${STATE_DIR}/installer-answers"
MANIFEST_FILE="${STATE_DIR}/installed-files"
RUN_STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${STATE_DIR}/backup-${RUN_STAMP}"

OPT_YES=0
OPT_WM=""
OPT_EXISTING=""
OPT_REBUILD=0
OPT_EXTRAS=0

# --- output -----------------------------------------------------------------------

# What this terminal can show. Colours: on a terminal, not with NO_COLOR or
# TERM=dumb. Unicode (✓, the block-letter title): a UTF-8 locale, and not the
# Linux console (TERM=linux), whose fonts lack most of it. Emoji: the same,
# plus PERIHELION_NO_EMOJI unset. PERIHELION_TTY=1 treats stdout as a
# terminal (tests).
ui_setup() {
    local tty=0 utf8=0 term=${TERM:-dumb} colors=0
    [[ -t 1 || ${PERIHELION_TTY:-} == 1 ]] && tty=1
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) utf8=1 ;; esac
    UI_COLOR=0 UI_UNICODE=0 UI_EMOJI=0 UI_256=0
    if (( tty )) && [[ -z ${NO_COLOR:-} && ${term} != dumb ]]; then
        UI_COLOR=1
        colors=$(tput colors 2>/dev/null || echo 8)
        [[ ${colors} =~ ^[0-9]+$ ]] || colors=8
        if (( colors >= 256 )) || [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit || ${term} == *256color* ]]; then UI_256=1; fi
    fi
    if (( utf8 )) && [[ ${term} != linux && ${term} != dumb ]]; then UI_UNICODE=1; fi
    if (( tty && UI_UNICODE )) && [[ ${PERIHELION_NO_EMOJI:-} != 1 ]]; then UI_EMOJI=1; fi
    if (( UI_COLOR )); then
        B=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GRN=$'\e[32m' YLW=$'\e[33m' BLU=$'\e[34m' RST=$'\e[0m'
    else
        B='' DIM='' RED='' GRN='' YLW='' BLU='' RST=''
    fi
    if (( UI_UNICODE )); then
        G_OK='✓' G_NOTE='·' G_WARN='!' G_FAIL='✗'
    else
        G_OK='+' G_NOTE='-' G_WARN='!' G_FAIL='x'
    fi
}
ui_setup

# emoji GLYPH [PLAIN]: the glyph and a space where emoji show, else PLAIN
# (and a space) or nothing.
emoji() {
    if (( UI_EMOJI )); then printf '%s ' "$1"; elif [[ -n ${2:-} ]]; then printf '%s ' "$2"; fi
}

# The title: PERIHELION in block letters (# on terminals without Unicode),
# shaded from gold to red on 256-colour terminals; one plain line on narrow
# terminals.
TITLE_ROWS=(
    '████   █████  ████   ███  █   █  █████  █      ███  ▄███▄  █   █'
    '█   █  █      █   █   █   █   █  █      █       █   █   █  ██  █'
    '████   ████   ████    █   █████  ████   █       █   █   █  █ █ █'
    '█      █      █  █    █   █   █  █      █       █   █   █  █  ██'
    '█      █████  █   █  ███  █   █  █████  █████  ███  ▀███▀  █   █'
)
TITLE_SHADES=(220 214 208 202 196)

banner() { # VERSION COMMIT
    local cols=${COLUMNS:-} i line color
    [[ ${cols} =~ ^[0-9]+$ ]] || cols=$(tput cols 2>/dev/null || echo 80)
    [[ ${cols} =~ ^[0-9]+$ ]] || cols=80
    printf '\n'
    if (( cols < 68 )); then
        printf '  %sP E R I H E L I O N%s\n' "${B}${YLW}" "${RST}"
    else
        for i in "${!TITLE_ROWS[@]}"; do
            line=${TITLE_ROWS[i]}
            if (( ! UI_UNICODE )); then
                line=${line//█/#}
                line=${line//▄/ }
                line=${line//▀/ }
            fi
            color=""
            if (( UI_256 )); then color=$'\e[1;38;5;'"${TITLE_SHADES[i]}m"; elif (( UI_COLOR )); then color="${B}${YLW}"; fi
            printf '  %s%s%s\n' "${color}" "${line}" "${RST}"
        done
    fi
    printf '\n  %s%sPerihelion Bar installer%s  %s%s (%s)%s\n' \
        "$(emoji '🚀' '>>')" "${B}" "${RST}" "${DIM}" "$1" "$2" "${RST}"
}

log() { if [[ -d ${STATE_DIR} ]]; then printf '%s %s\n' "$(date +%T)" "$*" >> "${LOG_FILE}" || true; fi; }
say() { printf '%s\n' "$*"; log "$*"; }
ok() { printf '  %s%s%s %s\n' "${GRN}" "${G_OK}" "${RST}" "$*"; log "ok: $*"; }
note() { printf '  %s%s%s %s\n' "${BLU}" "${G_NOTE}" "${RST}" "$*"; log "note: $*"; }
warn() { printf '  %s%s%s %s\n' "${YLW}" "${G_WARN}" "${RST}" "$*"; log "warning: $*"; WARNINGS+=("$*"); }
CURRENT_STEP=""
STEP_NO=0
STEP_TOTAL=0
# step "Title" [EMOJI]: "[2/5] 📦 Packages" (the emoji only where it shows).
step() {
    CURRENT_STEP=$1
    STEP_NO=$((STEP_NO + 1))
    local count=""
    (( STEP_TOTAL )) && count="[${STEP_NO}/${STEP_TOTAL}] "
    printf '\n%s%s%s%s%s%s\n' "${BLU}${B}" "${count}" "${RST}" "$(emoji "${2:-}")" "${B}$1" "${RST}"
    log "=== ${count}$1"
}

die() {
    printf '\n%s%s %s failed:%s %s\n' "${RED}${B}" "${G_FAIL}" "${CURRENT_STEP:-Install}" "${RST}" "$*" >&2
    log "FAILED (${CURRENT_STEP}): $*"
    if [[ -f ${LOG_FILE} ]]; then
        printf '%sLast lines of %s:%s\n' "${DIM}" "${LOG_FILE}" "${RST}" >&2
        tail -n 25 "${LOG_FILE}" | sed 's/^/    /' >&2
    fi
    printf '\nNothing after this step ran. Fix the cause above, then run the installer again.\n' >&2
    exit 1
}

# run DESCRIPTION COMMAND...: the command's output goes to the log only; a
# failure stops the installer with the log's tail.
run() {
    local what=$1
    shift
    log "\$ $*"
    if "$@" >> "${LOG_FILE}" 2>&1; then
        ok "${what}"
    else
        die "${what} (exit $?)"
    fi
}

on_error() { die "unexpected error at line $1: $2"; }

# --- prompts (always the keyboard, never the piped script) --------------------------

have_tty() { { : < /dev/tty; } 2>/dev/null; }

# ask_choice VAR DEFAULT "Question" "key:Label" ... : sets VAR to a key.
ask_choice() {
    local var=$1 default=$2 question=$3
    shift 3
    local i=1 opt keys=() reply
    if (( OPT_YES )); then
        printf -v "${var}" '%s' "${default}"
        note "${question} ${default} (--yes)"
        return
    fi
    have_tty || die "a question needs a terminal (${question}); run with --yes to take the defaults"
    printf '\n  %s%s%s\n' "${YLW}" "${question}" "${RST}" > /dev/tty
    for opt in "$@"; do
        keys+=("${opt%%:*}")
        printf '    %d) %s%s\n' "${i}" "${opt#*:}" "$([[ ${opt%%:*} == "${default}" ]] && echo ' (default)')" > /dev/tty
        i=$((i + 1))
    done
    while true; do
        printf '  Choice: ' > /dev/tty
        IFS= read -r reply < /dev/tty || reply=""
        reply=${reply//[[:space:]]/}
        if [[ -z ${reply} ]]; then
            printf -v "${var}" '%s' "${default}"
            break
        elif [[ ${reply} =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#keys[@]} )); then
            printf -v "${var}" '%s' "${keys[reply - 1]}"
            break
        fi
        printf '  Pick a number from 1 to %d.\n' "${#keys[@]}" > /dev/tty
    done
    log "asked: ${question} -> ${!var}"
}

# ask_yes "Question" [default y|n]: returns 0 for yes.
ask_yes() {
    local question=$1 default=${2:-y} reply
    if (( OPT_YES )); then
        log "asked: ${question} -> ${default} (--yes)"
        [[ ${default} == y ]]
        return
    fi
    have_tty || die "a question needs a terminal (${question}); run with --yes to take the defaults"
    printf '  %s %s ' "${question}" "$([[ ${default} == y ]] && echo '[Y/n]' || echo '[y/N]')" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""
    reply=${reply//[[:space:]]/}
    log "asked: ${question} -> ${reply:-${default}}"
    case "${reply:-${default}}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- remembered answers (key=value) --------------------------------------------------

answer_get() {
    if [[ -f ${ANSWERS_FILE} ]]; then
        { grep -m1 "^$1=" "${ANSWERS_FILE}" || true; } | cut -d= -f2-
    fi
}

answer_set() {
    local key=$1 value=$2 tmp
    [[ $(answer_get "${key}") == "${value}" ]] && return 0
    tmp=$(mktemp "${ANSWERS_FILE}.XXXXXX")
    {
        if [[ -f ${ANSWERS_FILE} ]]; then grep -v "^${key}=" "${ANSWERS_FILE}" || true; fi
        printf '%s=%s\n' "${key}" "${value}"
    } | sort > "${tmp}"
    mv -f "${tmp}" "${ANSWERS_FILE}"
}

# --- arguments ---------------------------------------------------------------------

usage() {
    cat <<'EOF'
Perihelion Bar installer (Arch Linux and Arch-based distros, Fedora 45+)

  ./install.sh [options]
  curl -fsSL https://raw.githubusercontent.com/CipherVLT/perihelion-shell/main/install.sh | bash -s -- [options]

  --yes               take the default for every question (no prompts)
  --wm=mango|hyprland|both
                      which window manager(s) to set up (default: the ones
                      installed; MangoWM when neither is)
  --existing=keep|new|beside
                      what --yes does with a config file of yours that
                      differs from Perihelion's (default: beside, which writes
                      Perihelion's next to yours as <file>.perihelion-new)
  --rebuild           build again even when the installed programs already
                      match this commit
  --extras            also install the optional extras (an image viewer,
                      Blueman, wev); Perihelion Bar doesn't need them
  -h, --help          this text

Log: ~/.local/state/perihelionbar/install.log
EOF
}

parse_args() {
    local a
    for a in "$@"; do
        case "${a}" in
            --yes | -y) OPT_YES=1 ;;
            --wm=*) OPT_WM=${a#--wm=} ;;
            --existing=*) OPT_EXISTING=${a#--existing=} ;;
            --rebuild) OPT_REBUILD=1 ;;
            --extras) OPT_EXTRAS=1 ;;
            -h | --help) usage; exit 0 ;;
            *) printf 'Unknown option: %s\n\n' "${a}" >&2; usage >&2; exit 2 ;;
        esac
    done
    case "${OPT_WM}" in "" | mango | hyprland | both) ;; *) printf -- '--wm must be mango, hyprland or both\n' >&2; exit 2 ;; esac
    case "${OPT_EXISTING}" in "" | keep | new | beside) ;; *) printf -- '--existing must be keep, new or beside\n' >&2; exit 2 ;; esac
}

# --- where the installer's files are ------------------------------------------------

# A checkout has scripts/ next to install.sh. Piped from curl there is no
# file at all: clone the repository into a temporary folder and run the
# installer from there, with the keyboard as its input.
locate_source() {
    local self=${BASH_SOURCE[0]:-}
    if [[ -n ${self} && -f ${self} ]]; then
        SRC_DIR=$(cd "$(dirname "${self}")" && pwd)
        [[ -f ${SRC_DIR}/scripts/build.sh ]] && return 0
    fi
    command -v git >/dev/null || {
        printf 'The installer needs git to fetch Perihelion Bar. Install it first:\n  sudo pacman -S git      (Arch and Arch-based)\n  sudo dnf install git    (Fedora)\n' >&2
        exit 1
    }
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/perihelionbar-install.XXXXXX")
    printf 'Fetching Perihelion Bar (%s)...\n' "${PERIHELION_BRANCH}"
    git clone --quiet --depth 1 --branch "${PERIHELION_BRANCH}" "${PERIHELION_REPO_URL}" "${tmp}/src" ||
        { printf 'Could not clone %s\n' "${PERIHELION_REPO_URL}" >&2; exit 1; }
    export PERIHELION_TEMP_CLONE="${tmp}"
    if have_tty; then
        exec bash "${tmp}/src/install.sh" "$@" < /dev/tty
    fi
    exec bash "${tmp}/src/install.sh" "$@" < /dev/null
}

# --- checks ------------------------------------------------------------------------

# Which family this system belongs to: DISTRO_FAMILY=arch|fedora (empty for
# anything else), with its ID, name and Fedora release.
detect_distro() {
    local osr=${PERIHELION_OS_RELEASE:-/etc/os-release}
    DISTRO_ID="" DISTRO_LIKE="" DISTRO_NAME="" DISTRO_VERSION="" DISTRO_FAMILY=""
    if [[ -r ${osr} ]]; then
        # shellcheck disable=SC1090
        DISTRO_ID=$(. "${osr}" && printf '%s' "${ID:-}")
        # shellcheck disable=SC1090
        DISTRO_LIKE=$(. "${osr}" && printf '%s' "${ID_LIKE:-}")
        # shellcheck disable=SC1090
        DISTRO_NAME=$(. "${osr}" && printf '%s' "${PRETTY_NAME:-${NAME:-}}")
        # shellcheck disable=SC1090
        DISTRO_VERSION=$(. "${osr}" && printf '%s' "${VERSION_ID:-}")
    fi
    if [[ ${DISTRO_ID} == arch || " ${DISTRO_LIKE} " == *" arch "* ]]; then
        DISTRO_FAMILY=arch
    elif [[ ${DISTRO_ID} == fedora || " ${DISTRO_LIKE} " == *" fedora "* ]]; then
        DISTRO_FAMILY=fedora
    fi
}

# Perihelion Linux ships the shell in its image (the same marker Settings >
# Updates uses); installing over it would fight the image's own copy.
on_perihelion_linux() { [[ -e ${PERIHELION_ISO_REF:-/usr/share/perihelion/perihelionbar.ref} ]]; }

check_system() {
    if on_perihelion_linux; then
        printf '\n  %sThis is Perihelion Linux: Perihelion Bar is already installed.%s\n' "${GRN}${B}" "${RST}"
        printf '  Updates come with the system: Perihelion Settings > Updates.\n  Nothing was changed.\n'
        exit 0
    fi
    if (( EUID == 0 )); then
        printf 'Run the installer as your normal user, not root: it asks for sudo only\nfor the steps that need it.\n' >&2
        exit 1
    fi
    detect_distro
    case "${DISTRO_FAMILY}" in
        arch)
            command -v pacman >/dev/null || { printf 'This looks Arch-based but has no pacman.\n' >&2; exit 1; }
            ;;
        fedora)
            command -v dnf >/dev/null || { printf 'This looks like Fedora but has no dnf.\n' >&2; exit 1; }
            if [[ -e /run/ostree-booted ]]; then
                printf '%s is an image-based (rpm-ostree) system: installing into /usr is not possible here.\nUse Perihelion Linux, or a regular Fedora install.\n' "${DISTRO_NAME:-This system}" >&2
                exit 1
            fi
            local rel
            rel=$(rpm -E %fedora 2>/dev/null || true)
            [[ ${rel} =~ ^[0-9]+$ ]] || rel=${DISTRO_VERSION%%.*}
            if ! [[ ${rel} =~ ^[0-9]+$ ]] || (( rel < 45 )); then
                printf 'Perihelion Bar needs Fedora 45 or later (this is %s).\n' "${DISTRO_NAME:-Fedora ${rel}}" >&2
                exit 1
            fi
            ;;
        *)
            printf 'Perihelion Bar'"'"'s installer supports Arch Linux, Arch-based distros and Fedora 45+\n(this system is "%s"). Perihelion Linux ships it ready to use.\n' "${DISTRO_ID:-unknown}" >&2
            exit 1
            ;;
    esac
    [[ $(uname -m) == x86_64 ]] || { printf 'Only x86_64 is supported for now (this is %s).\n' "$(uname -m)" >&2; exit 1; }
    command -v sudo >/dev/null || { printf 'sudo is needed (install it as root first).\n' >&2; exit 1; }
}

SUDO_KEEPALIVE=""
need_sudo() {
    [[ -n ${SUDO_KEEPALIVE} ]] && return 0
    if ! sudo -n true 2>/dev/null; then
        have_tty || die "sudo needs a password and there is no terminal to ask on"
        printf '  Some steps need administrator rights (packages, /usr/bin, /etc/pam.d).\n' > /dev/tty
        # shellcheck disable=SC2024  # sudo reads the password from the keyboard
        sudo -v < /dev/tty || die "sudo did not accept the password"
    fi
    ( while sleep 50; do sudo -n true 2>/dev/null || exit; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE=$!
}

cleanup() {
    trap - ERR
    if [[ -n ${SUDO_KEEPALIVE} ]]; then kill "${SUDO_KEEPALIVE}" 2>/dev/null || true; fi
    if [[ -n ${PERIHELION_TEMP_CLONE:-} && -d ${PERIHELION_TEMP_CLONE} ]]; then rm -rf "${PERIHELION_TEMP_CLONE}"; fi
}

# --- which window managers ------------------------------------------------------------

pick_wms() {
    local have_mango=0 have_hypr=0 saved default
    check_package mangowm && have_mango=1
    check_package hyprland && have_hypr=1
    note "Installed: MangoWM $( ((have_mango)) && echo yes || echo no), Hyprland $( ((have_hypr)) && echo yes || echo no)"
    saved=$(answer_get wm)
    if [[ -n ${OPT_WM} ]]; then
        WMS=${OPT_WM}
    elif [[ -n ${saved} ]]; then
        WMS=${saved}
        note "Window manager: ${WMS} (your answer from last time; --wm= changes it)"
    else
        default=mango
        (( have_hypr && !have_mango )) && default=hyprland
        (( have_hypr && have_mango )) && default=both
        ask_choice WMS "${default}" "Set Perihelion Bar up for which window manager?" \
            "mango:MangoWM" "hyprland:Hyprland" "both:Both"
    fi
    answer_set wm "${WMS}"
    WANT_MANGO=0 WANT_HYPR=0
    [[ ${WMS} == mango || ${WMS} == both ]] && WANT_MANGO=1
    [[ ${WMS} == hyprland || ${WMS} == both ]] && WANT_HYPR=1
    ok "Setting up: ${WMS}"
}

# --- report ---------------------------------------------------------------------------

report() {
    printf '\n%s%sPerihelion Bar is installed%s (commit %s).\n' "$(emoji '✨')" "${GRN}${B}" "${RST}" "${COMMIT}"
    printf '\n%sInstalled%s\n' "${B}" "${RST}"
    printf '  Programs in /usr/bin: perihelion-bar, perihelion-shell, perihelion-settings,\n'
    printf '    perihelion-lockscreen, perihelion-lock, appdrawer, perihelion-theme and helpers\n'
    printf '    (full list: %s)\n' "${MANIFEST_FILE}"
    (( ${#PKGS_INSTALLED[@]} )) && printf '  Packages: %s\n' "${PKGS_INSTALLED[*]}"
    printf '  Configs: %s\n' "${CONFIGS_WRITTEN[*]:-none changed}"
    if (( ${#CONFIGS_BESIDE[@]} )); then
        printf '\n%sWritten beside yours%s (compare and merge what you like):\n' "${B}" "${RST}"
        printf '  %s\n' "${CONFIGS_BESIDE[@]}"
    fi
    if [[ -d ${BACKUP_DIR} ]]; then
        printf '\n%sBacked up%s before replacing: %s\n' "${B}" "${RST}" "${BACKUP_DIR}"
    fi
    if (( ${#WARNINGS[@]} )); then
        printf '\n%sNeeds a look%s\n' "${YLW}${B}" "${RST}"
        printf '  %s\n' "${WARNINGS[@]}"
    fi
    local session=Hyprland
    if (( WANT_MANGO && WANT_HYPR )); then session="MangoWM or Hyprland"; elif (( WANT_MANGO )); then session=MangoWM; fi
    printf '\n%sKeys to try%s (log in to %s first)\n' "${B}" "${RST}" "${session}"
    printf '  Super+Return terminal    Super+D launcher     Super+A app drawer\n'
    printf '  Super+I Glance           Alt+W overview       Super+L lock\n'
    printf '  Super+Shift+W wallpapers Super+H every key    Super+Shift+Q power menu\n'
    printf '  Settings: perihelion-settings (or from the app drawer)\n'
    printf '\n%sUndo%s\n' "${B}" "${RST}"
    printf '  Programs:  xargs -a %s sudo rm -f\n' "${MANIFEST_FILE}"
    (( WANT_HYPR )) && printf '  Hyprland:  delete the Perihelion Bar line at the end of ~/.config/hypr/hyprland.lua (or hyprland.conf)\n'
    [[ -d ${BACKUP_DIR} ]] && printf '  Your old configs:  cp -a %s/. ~/\n' "${BACKUP_DIR}"
    printf '  Log: %s\n' "${LOG_FILE}"
}

# --- main ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    locate_source "$@"
    trap cleanup EXIT
    check_system
    mkdir -p "${STATE_DIR}"
    trap 'on_error ${LINENO} "${BASH_COMMAND}"' ERR
    printf '\n%s=== installer run %s (%s) ===\n' "" "${RUN_STAMP}" "$*" >> "${LOG_FILE}"

    WARNINGS=() PKGS_INSTALLED=() CONFIGS_WRITTEN=() CONFIGS_BESIDE=()
    COMMIT=$(git -C "${SRC_DIR}" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
    VERSION=$(sed -n 's/^const DEFAULT_VERSION = "\(.*\)";/\1/p' "${SRC_DIR}/perihelionbar/build.zig")
    [[ -n ${VERSION} ]] || VERSION=0.1.0-dev

    banner "${VERSION}" "${COMMIT}"
    printf '  %sLog: %s%s\n' "${DIM}" "${LOG_FILE}" "${RST}"

    # shellcheck source=scripts/packages-arch.sh
    source "${SRC_DIR}/scripts/packages-${DISTRO_FAMILY}.sh"
    # shellcheck source=scripts/build.sh
    source "${SRC_DIR}/scripts/build.sh"
    # shellcheck source=scripts/configs.sh
    source "${SRC_DIR}/scripts/configs.sh"
    # shellcheck source=scripts/autostart.sh
    source "${SRC_DIR}/scripts/autostart.sh"
    # shellcheck source=scripts/leftovers.sh
    source "${SRC_DIR}/scripts/leftovers.sh"

    STEP_TOTAL=5
    step "Checking this system" "🔎"
    ok "${DISTRO_NAME:-${DISTRO_ID}}, user ${USER:-$(id -un)}"
    pick_wms

    step "Packages" "📦";                 install_packages
    step "Building Perihelion Bar" "🔧";  build_and_install
    step "Your configs" "📁";             install_configs; remove_old_images
    step "Starting with the session" "🚀"; install_autostart

    report
}

# Run when executed or piped into bash; tests source this file instead.
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
