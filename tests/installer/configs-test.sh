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
check grep -qx 'exec_once=swayidle -w timeout 600 perihelion-lock before-sleep perihelion-lock' "${C}/mango/cfg/autostart.conf"
check grep -q '^exec_once=dbus-update-activation-environment' "${C}/mango/cfg/autostart.conf"
check grep -qx 'exec_once=perihelion-bar-start' "${C}/mango/cfg/autostart.conf"
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

(( fails )) && echo "configs-test: FAILED" || echo "configs-test: all passed"
exit "${fails}"
