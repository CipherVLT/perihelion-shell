#!/usr/bin/env bash
# Unit test for the installer's config handling (scripts/configs.sh): fresh
# home, unchanged re-run, a file of yours that differs (keep / new / beside),
# remembered answers, backups, the Hyprland require line, and that a second
# run changes nothing. No root, no packages: system files go to a fake root.
#   tests/installer/configs-test.sh
# shellcheck disable=SC1091,SC2012,SC2034,SC2329  # helpers run through check(); variables are read by the sourced installer
set -Eeuo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
export HOME="${work}/home" XDG_CONFIG_HOME="" XDG_STATE_HOME="" XDG_DATA_HOME=""
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
mkdir -p "${HOME}" "${work}/root" "${work}/fonts"
touch "${work}/fonts/JetBrainsMonoNerdFont-Regular.ttf"

# shellcheck source=../../install.sh
source "${repo}/install.sh"
# shellcheck source=../../scripts/build.sh
source "${repo}/scripts/build.sh"
# shellcheck source=../../scripts/configs.sh
source "${repo}/scripts/configs.sh"
# shellcheck source=../../scripts/autostart.sh
source "${repo}/scripts/autostart.sh"

# Test doubles: /etc and /usr live under a fake root, fonts in a temp folder.
put_system() { install -Dm"$1" "$2" "${work}/root$3"; CHANGED_SYSTEM=$((CHANGED_SYSTEM + 1)); }
record() { :; }
check_services() { :; }
check_quickshell_qt() { :; }  # host-dependent; tests/installer/qt-mismatch-test.sh covers it
NVIDIA_DRIVER_FILE=${work}/no-nvidia  # the host's driver must not decide; the radius note is tested below
font_path() { printf '%s' "${work}/fonts/JetBrainsMonoNerdFont-Regular.ttf"; }
check_command() { [[ $1 != mango ]] && command -v "$1" >/dev/null 2>&1; }
place_system_config() { put_system 644 "$1" "$2"; }

SRC_DIR=${repo} COMMIT=abc1234 OPT_YES=1 CHANGED_SYSTEM=0
mkdir -p "${STATE_DIR}"
fails=0
check() { if "$@"; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }
reset_lists() { WARNINGS=() CONFIGS_WRITTEN=() CONFIGS_BESIDE=(); }
snapshot() { (cd "${HOME}" && find . -path ./.local/state/perihelionbar/install.log -prune -o -type f -print0 | sort -z | xargs -0 sha256sum; find . -type l -printf '%p -> %l\n' | sort); }
C="${HOME}/.config"

echo "== fresh home, both window managers"
WANT_MANGO=1 WANT_HYPR=1; reset_lists
install_configs >/dev/null
install_autostart >/dev/null
check test -f "${C}/mango/config.conf"
check test -f "${C}/mango/cfg/keybinds.conf"
check grep -qx 'bind=SUPER,i,spawn,perihelion-shell glance toggle' "${C}/mango/cfg/keybinds.conf"
check grep -qx 'bind=SUPER,l,spawn,perihelion-lock' "${C}/mango/cfg/keybinds.conf"
check grep -qx 'exec_once=perihelion-session-start' "${C}/mango/cfg/autostart.conf"
check test -f "${C}/hypr/perihelion.lua"
check grep -qx 'require("perihelion")' "${C}/hypr/hyprland.lua"
check grep -q "\"font_path\": \"${work}/fonts/JetBrainsMonoNerdFont-Regular.ttf\"" "${C}/perihelionbar/config.json"
check test -f "${C}/perihelionbar/matugen.json"
check grep -qx 'install.sh abc1234' "${HOME}/.local/state/perihelionbar/install-method"
check test -L "${C}/systemd/user/timers.target.wants/perihelion-update-check.timer"
check grep -qx 'ExecStart=/usr/bin/perihelion-settings --check-updates --if-due' "${C}/systemd/user/perihelion-update-check.service"
check test ! -e "${BACKUP_DIR}"
check test "${#WARNINGS[@]}" -eq 0

echo "== second run changes nothing"
before=$(snapshot); reset_lists
install_configs >/dev/null; install_autostart >/dev/null
same_as_before() { [[ "$(snapshot)" == "${before}" ]] || { diff <(printf '%s\n' "${before}") <(snapshot) | sed 's/^/        /'; return 1; }; }
check same_as_before
check test "${#CONFIGS_WRITTEN[@]}" -eq 0

echo "== your edits: --yes writes Perihelion's beside yours, never over them"
printf 'my own mango\n' > "${C}/mango/config.conf"
printf -- '-- my hyprland\nhl.env("A","1")\n' > "${C}/hypr/hyprland.lua"
reset_lists
install_configs >/dev/null
check grep -qx 'my own mango' "${C}/mango/config.conf"
check cmp -s "${repo}/desktop/mango/config.conf" "${C}/mango/config.conf.perihelion-new"
check grep -qx 'hl.env("A","1")' "${C}/hypr/hyprland.lua"
check grep -qx 'require("perihelion")' "${C}/hypr/hyprland.lua"
check test -f "${BACKUP_DIR}/.config/hypr/hyprland.lua"
check grep -q 'file:~/.config/mango/config.conf=beside' "${ANSWERS_FILE}"

echo "== the remembered answer is reused; nothing new is written"
before=$(snapshot); reset_lists
install_configs >/dev/null
check same_as_before

echo "== --existing=new: replaced, old one backed up (a fresh run's backup folder)"
answer_set "file:~/.config/mango/config.conf" ""
BACKUP_DIR="${STATE_DIR}/backup-test-new" OPT_EXISTING=new; reset_lists
install_configs >/dev/null
check cmp -s "${repo}/desktop/mango/config.conf" "${C}/mango/config.conf"
check grep -qx 'my own mango' "${BACKUP_DIR}/.config/mango/config.conf"
check grep -qE '^file:~/.config/mango/config.conf=new:[0-9a-f]{64}$' "${ANSWERS_FILE}"

echo "== a remembered 'take new' is not reused once you have edited the file"
printf 'edited again\n' > "${C}/mango/config.conf"
BACKUP_DIR="${STATE_DIR}/backup-test-edit" OPT_EXISTING=keep; reset_lists
install_configs >/dev/null
check grep -qx 'edited again' "${C}/mango/config.conf"
check grep -q 'file:~/.config/mango/config.conf=keep' "${ANSWERS_FILE}"

echo "== Hyprland without a hyprland.lua gets a minimal one; a hyprland.conf is left alone"
rm -f "${C}/hypr/hyprland.lua"; printf 'monitor=,preferred,auto,1\n' > "${C}/hypr/hyprland.conf"
WANT_MANGO=0 WANT_HYPR=1; reset_lists
install_configs >/dev/null
check grep -qx 'require("perihelion")' "${C}/hypr/hyprland.lua"
check grep -qx 'monitor=,preferred,auto,1' "${C}/hypr/hyprland.conf"
check test "${#WARNINGS[@]}" -eq 1

echo "== Hyprland 0.56 with only hyprland.conf: perihelion.conf + one source line, backed up, never twice"
H2="${C}/hypr"
rm -rf "${H2}"; mkdir -p "${H2}"
printf 'monitor=,preferred,auto,1\nbind = SUPER, Q, exec, foot\n' > "${H2}/hyprland.conf"
hyprland_version() { echo 0.56.1; }
BACKUP_DIR="${STATE_DIR}/backup-test-conf"; reset_lists
install_configs >/dev/null
check test -f "${H2}/perihelion.conf"
check test ! -e "${H2}/hyprland.lua"
check test "$(grep -cxF 'source = ~/.config/hypr/perihelion.conf' "${H2}/hyprland.conf")" -eq 1
check grep -qx 'bind = SUPER, Q, exec, foot' "${H2}/hyprland.conf"
check grep -qx 'monitor=,preferred,auto,1' "${BACKUP_DIR}/.config/hypr/hyprland.conf"
install_configs >/dev/null
check test "$(grep -cxF 'source = ~/.config/hypr/perihelion.conf' "${H2}/hyprland.conf")" -eq 1
check grep -qx 'unbind = SUPER, L' "${H2}/perihelion.conf"
check grep -qx 'bind = SUPER, I, exec, perihelion-shell glance toggle' "${H2}/perihelion.conf"
check grep -qx 'exec-once = perihelion-bar-start' "${H2}/perihelion.conf"

echo "== Hyprland 0.57 with only hyprland.conf: Lua (0.57 no longer reads hyprland.conf)"
rm -rf "${H2}"; mkdir -p "${H2}"; printf 'monitor=,preferred,auto,1\n' > "${H2}/hyprland.conf"
hyprland_version() { echo 0.57.2; }
reset_lists; install_configs >/dev/null
check grep -qx 'require("perihelion")' "${H2}/hyprland.lua"
check test ! -e "${H2}/perihelion.conf"
check grep -qx 'monitor=,preferred,auto,1' "${H2}/hyprland.conf"

echo "== an existing hyprland.lua always wins, even on an older version; the line is a Lua comment + require"
rm -rf "${H2}"; mkdir -p "${H2}"; printf -- '-- mine\n' > "${H2}/hyprland.lua"; printf 'x=1\n' > "${H2}/hyprland.conf"
hyprland_version() { echo 0.55.0; }
reset_lists; install_configs >/dev/null
check grep -qx -- '-- Perihelion Bar (delete this line to switch it off)' "${H2}/hyprland.lua"
check test "$(grep -cx 'require("perihelion")' "${H2}/hyprland.lua")" -eq 1
check test ! -e "${H2}/perihelion.conf"
check grep -qx 'x=1' "${H2}/hyprland.conf"

echo "== NVIDIA driver: a note when a kept appearance.conf still rounds corners, none at the shipped 0"
A="${work}/appearance.conf"
NVIDIA_DRIVER_FILE=${work}/nvidia-version; printf 'NVRM version: NVIDIA UNIX Open Kernel Module  620.73.04\n' > "${NVIDIA_DRIVER_FILE}"
reset_lists; check_mango_radius "${repo}/desktop/mango/cfg/appearance.conf"
check test "${#WARNINGS[@]}" -eq 0
printf '# border_radius=3\nborder_radius=12\n' > "${A}"
reset_lists; check_mango_radius "${A}" >/dev/null
check test "${#WARNINGS[@]}" -eq 1
check grep -q 'border_radius=12' <<< "${WARNINGS[*]:-}"
printf 'border_radius = 0\n' > "${A}"
reset_lists; check_mango_radius "${A}"
check test "${#WARNINGS[@]}" -eq 0
NVIDIA_DRIVER_FILE=${work}/no-nvidia; printf 'border_radius=12\n' > "${A}"
reset_lists; check_mango_radius "${A}"
check test "${#WARNINGS[@]}" -eq 0

(( fails )) && echo "configs-test: FAILED" || echo "configs-test: all passed"
exit "${fails}"
