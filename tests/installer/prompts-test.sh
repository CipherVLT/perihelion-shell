#!/usr/bin/env bash
# The MangoWM config path with real answers typed at the keyboard: the
# installer runs under `script`, so /dev/tty is a pseudo-terminal fed from
# here. Three Mango files of yours differ; the answers are 3 (write beside),
# 2 (take the new one, backed up) and 1 (keep mine). A second run must ask
# nothing; editing the taken file must make it ask again.
#   tests/installer/prompts-test.sh
# shellcheck disable=SC1091,SC2016,SC2034,SC2329  # helpers run through check(); the driver is generated
set -Eeuo pipefail

command -v script >/dev/null || { echo "prompts-test: needs script(1) from util-linux"; exit 1; }
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
H="${work}/home" C="${work}/home/.config/mango"
mkdir -p "${C}/cfg" "${work}/root" "${work}/fonts"
touch "${work}/fonts/JetBrainsMonoNerdFont-Regular.ttf"
printf 'my config.conf\n' > "${C}/config.conf"
printf 'exec_once=my-bar\n' > "${C}/cfg/autostart.conf"
printf 'bind=SUPER,t,spawn,foot\n' > "${C}/cfg/keybinds.conf"

# The driver runs inside the pseudo-terminal: the real config code, with
# /etc and fonts redirected to the temp folder.
cat > "${work}/driver.sh" <<EOF
set -Eeuo pipefail
export HOME="${H}"
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
source "${repo}/install.sh"
source "${repo}/scripts/build.sh"
source "${repo}/scripts/configs.sh"
put_system() { install -Dm"\$1" "\$2" "${work}/root\$3"; }
record() { :; }
place_system_config() { put_system 644 "\$1" "\$2"; }
font_path() { printf '%s' "${work}/fonts/JetBrainsMonoNerdFont-Regular.ttf"; }
check_command() { false; }
SRC_DIR="${repo}" COMMIT=abc1234 OPT_YES=0 OPT_EXISTING="" WANT_MANGO=1 WANT_HYPR=0
BACKUP_DIR="\${STATE_DIR}/backup-\${1}"
mkdir -p "\${STATE_DIR}"
WARNINGS=() CONFIGS_WRITTEN=() CONFIGS_BESIDE=()
install_configs
EOF

drive() { # NAME ANSWERS: run the driver with these keystrokes, output to NAME.out
    printf '%b' "$2" | script -qec "bash ${work}/driver.sh $1" /dev/null > "${work}/$1.out" 2>&1 || {
        echo "driver failed:"; cat "${work}/$1.out"; return 1; }
}
fails=0
check() { if "$@"; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }
prompts() { grep -c 'What should happen to it?' "${work}/$1.out" || true; }
S="${H}/.local/state/perihelionbar"

echo "== first run: beside, take new, keep (in the order the files are asked about)"
drive first '3\n2\n1\n'
check test "$(prompts first)" -eq 3
check grep -qx 'my config.conf' "${C}/config.conf"
check cmp -s "${repo}/desktop/mango/config.conf" "${C}/config.conf.perihelion-new"
check cmp -s "${repo}/desktop/mango/cfg/autostart.conf" "${C}/cfg/autostart.conf"
check grep -qx 'exec_once=my-bar' "${S}/backup-first/.config/mango/cfg/autostart.conf"
check grep -qx 'bind=SUPER,t,spawn,foot' "${C}/cfg/keybinds.conf"
check test ! -e "${C}/cfg/keybinds.conf.perihelion-new"
check grep -qx 'file:~/.config/mango/config.conf=beside' "${S}/installer-answers"
check grep -qE '^file:~/.config/mango/cfg/autostart.conf=new:[0-9a-f]{64}$' "${S}/installer-answers"
check grep -qx 'file:~/.config/mango/cfg/keybinds.conf=keep' "${S}/installer-answers"
check cmp -s "${repo}/desktop/mango/cfg/appearance.conf" "${C}/cfg/appearance.conf"
check grep -qx 'bind=SUPER,i,spawn,perihelion-shell glance toggle' "${repo}/desktop/mango/cfg/keybinds.conf"

echo "== second run: every answer remembered, nothing asked, nothing backed up"
drive second ''
check test "$(prompts second)" -eq 0
check test ! -e "${S}/backup-second"

echo "== you edit the file you took: asked again (1 = keep your edit)"
printf 'exec_once=edited\n' > "${C}/cfg/autostart.conf"
drive third '1\n'
check test "$(prompts third)" -eq 1
check grep -qx 'exec_once=edited' "${C}/cfg/autostart.conf"
check grep -qx 'file:~/.config/mango/cfg/autostart.conf=keep' "${S}/installer-answers"

echo "== an answer that is not a number is asked again, not taken as a choice"
printf 'bind=SUPER,y,spawn,foot\n' > "${H}/.config/mango/cfg/rules.conf"
drive fourth 'brave\n9\n2\n'
check grep -q 'Pick a number from 1 to 3' "${work}/fourth.out"
check cmp -s "${repo}/desktop/mango/cfg/rules.conf" "${C}/cfg/rules.conf"
check grep -qx 'bind=SUPER,y,spawn,foot' "${S}/backup-fourth/.config/mango/cfg/rules.conf"

if command -v mango >/dev/null; then
    echo "== the shipped Mango config parses with this mango"
    check mango -p -c "${repo}/desktop/mango/config.conf"
fi
if (( fails )); then echo "prompts-test: FAILED"; else echo "prompts-test: all passed"; fi
exit "${fails}"
