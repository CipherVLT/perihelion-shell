#!/usr/bin/env bash
# Check what install.sh left on an Arch system, as the user it ran for.
#   tests/installer/arch-check.sh <mango|hyprland> <commit>
# shellcheck disable=SC1091,SC2012,SC2034,SC2329  # helpers run through check(); variables are read by the sourced installer
set -uo pipefail

wm=$1 commit=$2
fails=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }
C="${HOME}/.config"
S="${HOME}/.local/state/perihelionbar"

echo "== programs"
for p in perihelion-bar perihelion-settings perihelionbar-welcome perihelion-shell perihelion-lockscreen; do
    check test -x "/usr/bin/${p}"
    version_ok() { [[ $("/usr/bin/$1" --version) == "$1 "*" ($2)" ]]; }
    check version_ok "${p}" "${commit}"
    no_missing_libs() { ! ldd "/usr/bin/$1" | grep -q 'not found'; }
    check no_missing_libs "${p}"
done
for p in perihelion-bar-start perihelion-lock perihelion-theme perihelion-trash perihelion-dock-pin appdrawer \
    perihelionbar-wallpaper perihelionbar-matugen perihelion-launcher perihelion-wallpaper perihelion-wallpaper-picker \
    perihelion-power-menu perihelion-keys perihelion-screenshot perihelion-nightlight; do
    check test -x "/usr/bin/${p}"
done
check test -L /usr/bin/perihelionbar
check cmp -s pam/perihelion-lock /etc/pam.d/perihelion-lock
check test -d /usr/share/perihelion/palettes
check test -f /usr/share/applications/perihelion-settings.desktop
check test -f /usr/share/icons/hicolor/48x48/apps/perihelion-settings.png
check test -f "${HOME}/.local/share/perihelionbar/appdrawer/shell.qml"
check test -f "${HOME}/.local/share/perihelionbar/appdrawer/favourites.json"
check test -x "${HOME}/.local/share/perihelionbar/zig-0.17.1/zig"

echo "== Settings > Updates"
check grep -qx "install.sh ${commit}" "${S}/install-method"
check grep -qx 'ExecStart=/usr/bin/perihelion-settings --check-updates --if-due' "${C}/systemd/user/perihelion-update-check.service"
check test -L "${C}/systemd/user/timers.target.wants/perihelion-update-check.timer"

echo "== configs (${wm})"
check test -f "${C}/perihelionbar/config.json"
font_ok() { local f; f=$(sed -n 's/.*"font_path": "\(.*\)".*/\1/p' "${C}/perihelionbar/config.json" | head -1); [[ -f ${f} ]]; }
check font_ok
check test -f "${C}/kitty/kitty.conf"
check test -f "${C}/fuzzel/fuzzel.ini"
case "${wm}" in
    mango)
        check test -f "${C}/mango/config.conf"
        check grep -qx 'bind=SUPER,i,spawn,perihelion-shell glance toggle' "${C}/mango/cfg/keybinds.conf"
        check grep -qx 'bind=SUPER,l,spawn,perihelion-lock' "${C}/mango/cfg/keybinds.conf"
        check grep -qx 'exec_once=perihelion-bar-start' "${C}/mango/cfg/autostart.conf"
        check grep -q '^exec_once=swayidle ' "${C}/mango/cfg/autostart.conf"
        check grep -q '^exec_once=dbus-update-activation-environment' "${C}/mango/cfg/autostart.conf"
        check mango -p -c "${C}/mango/config.conf"
        # Every program the Mango config starts or binds is installed.
        programs_ok() {
            local p missing=0
            while read -r p; do
                [[ -z ${p} ]] && continue
                command -v "${p}" >/dev/null || [[ -x ${p} ]] || { echo "      not installed: ${p}"; missing=1; }
            done < <(sed -n -E 's/^(bind[a-z]*)=[^,]*,[^,]*,spawn,([^ ,]+).*/\2/p; s/^exec_once=([^ ]+).*/\1/p' "${C}"/mango/cfg/*.conf | sort -u | grep -v -x -e strata -e firefox)
            return "${missing}"
        }
        check programs_ok
        ;;
    hyprland)
        check test -f "${C}/hypr/perihelion.lua"
        check grep -qx 'require("perihelion")' "${C}/hypr/hyprland.lua"
        hypr_ok() { XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-$(mktemp -d)} timeout 30 Hyprland --verify-config -c "${C}/hypr/hyprland.lua" 2>&1 | tee /tmp/hypr-verify.txt | grep -qx 'config ok'; }
        check hypr_ok || cat /tmp/hypr-verify.txt
        ;;
esac
exit "${fails}"
