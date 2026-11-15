#!/usr/bin/env bash
# Pictures of Perihelion Settings and the dock, taken on a headless
# compositor (sway, no screen needed): every Mango page, the Network page
# against a canned NetworkManager, Theme mode Dark over a light window
# style, and the dock's ends with and without its border, enlarged.
#
# For looking at, not asserting on: CI uploads them as an artifact. The one
# check is that Settings is still running when each picture is taken (a
# page that crashes it fails the run).
#
# Usage: dbus-run-session -- tests/screenshots.sh <bin dir> <out dir>
set -u
bin=$(readlink -f "${1:?usage: screenshots.sh <bin dir> <out dir>}")
out=$(readlink -f "${2:?usage: screenshots.sh <bin dir> <out dir>}")
repo=$(readlink -f "$(dirname "$0")/..")
mkdir -p "${out}"

work=$(mktemp -d)
export HOME="${work}/home" XDG_RUNTIME_DIR="${work}/run"
export XDG_CONFIG_HOME="${HOME}/.config" XDG_CACHE_HOME="${HOME}/.cache" XDG_STATE_HOME="${HOME}/.local/state"
mkdir -p "${HOME}/.config/simpbar" "${HOME}/.config/mango/cfg" "${XDG_RUNTIME_DIR}" "${work}/fake"
chmod 700 "${XDG_RUNTIME_DIR}"
unset WAYLAND_DISPLAY DISPLAY SIMPBAR_DOCK
export PATH="${work}/fake:${bin}:${PATH}"
# Software drawing; no portal or accessibility bus to wait for.
export GSK_RENDERER=cairo GDK_BACKEND=wayland GTK_A11Y=none ADW_DISABLE_PORTAL=1 NO_AT_BRIDGE=1

fails=0
cleanup() {
    pkill -x perihelion-settings 2>/dev/null
    pkill -x perihelion-bar 2>/dev/null
    [[ -n ${sway_pid:-} ]] && kill "${sway_pid}" 2>/dev/null
    if (( fails > 0 )); then
        echo "--- settings.log"; tail -n 40 "${work}/settings.log" 2>/dev/null
        echo "--- sway.log"; tail -n 20 "${work}/sway.log" 2>/dev/null
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

# A canned NetworkManager: Wi-Fi up, one WireGuard tunnel connected (on the
# loopback interface, so its traffic counters exist), one OpenVPN saved.
cat > "${work}/fake/nmcli" <<'NM'
#!/bin/sh
wg=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
up=${FAKE_VPN:-up}
case "$*" in
*"device status"*)
    echo "wlp3s0:wifi:connected:Perihelion 5G"
    echo "enp2s0:ethernet:unavailable:"
    [ "$up" = up ] && echo "lo:wireguard:connected:Home (WireGuard)" ;;
*"wifi list"*)
    echo " :48:WPA2:130 Mbit/s:Neighbours"
    echo "*:72:WPA2 WPA3:270 Mbit/s:Perihelion 5G" ;;
*"--active"*)
    echo "11111111-2222-3333-4444-555555555555:802-11-wireless"
    [ "$up" = up ] && echo "$wg:wireguard" ;;
*"show uuid"*)
    echo "GENERAL.NAME:Home (WireGuard)"
    echo "GENERAL.DEVICES:lo"
    echo "GENERAL.IP-IFACE:lo"
    echo "GENERAL.STATE:activated"
    echo "IP4.ADDRESS[1]:10.2.0.2/32"
    echo "IP4.GATEWAY:"
    echo "IP4.DNS[1]:10.2.0.1"
    echo "SINCE:$(( $(date +%s) - 8040 ))" ;;
*"connection show"*)
    echo "11111111-2222-3333-4444-555555555555:802-11-wireless:yes:wlp3s0:yes:Perihelion 5G"
    if [ "$up" = up ]; then echo "$wg:wireguard:yes:lo:no:Home (WireGuard)"
    else echo "$wg:wireguard:no::no:Home (WireGuard)"; fi
    echo "99999999-8888-7777-6666-555555555555:vpn:no::yes:Work & Office (OpenVPN)" ;;
esac
NM
chmod +x "${work}/fake/nmcli"

font=$(fc-match -f '%{file}' monospace)
write_bar_config() {  # $1 = dock border true|false
    cat > "${HOME}/.config/simpbar/config.json" <<JSON
{"appearance":{"font_path":"${font}","position":"top","bg_opacity_percent":55},
 "dock":{"enabled":true,"border":$1,"shrink":true,"trash":true,"app_drawer":true,"media":true}}
JSON
}
write_bar_config true

cat > "${work}/sway.conf" <<'CONF'
output HEADLESS-1 resolution 1500x1000
default_border none
CONF

echo "Starting a headless compositor"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    "${SWAY:-sway}" -c "${work}/sway.conf" >"${work}/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 1 100); do
    sock=$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -n 1)
    [[ -n ${sock} ]] && break
    sleep 0.1
done
[[ -n ${sock:-} ]] || { echo "FAIL no compositor came up"; fails=1; exit 1; }
export WAYLAND_DISPLAY=${sock##*/}
export SWAYSOCK=$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'sway-ipc.*' | head -n 1)
background() { swaymsg -q "output * bg $1 solid_color" 2>/dev/null; sleep 0.5; }
background '#7fa3c7'

shot() {  # $1 = file name, rest = grim options
    local name=$1; shift
    grim "$@" "${out}/${name}.png" && echo "  saved ${name}.png" || { echo "  FAIL ${name}"; fails=$((fails + 1)); }
}
slug() { echo "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/-$//'; }

settings_shot() {  # $1 = sidebar page, $2 = file name
    perihelion-settings --page "$1" >>"${work}/settings.log" 2>&1 &
    local pid=$!
    sleep "${SHOT_WAIT:-3}"
    if kill -0 "${pid}" 2>/dev/null; then
        shot "$2"
    else
        echo "  FAIL Settings exited on the $1 page"; fails=$((fails + 1))
    fi
    kill "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null
}

echo "Mango pages"
i=0
for page in General Decoration Keyboards "Mouse & Touchpad" Binds Layouts Animations Misc Render Cursor \
            Group XWayland OpenGL Quirks Monitors "Window Rules" "Layer Rules" Autostart Environment; do
    i=$((i + 1))
    settings_shot "${page}" "$(printf 'mango-%02d-%s' "${i}" "$(slug "${page}")")"
done

echo "Network"
settings_shot Network network-vpn-connected
FAKE_VPN=down settings_shot Network network-vpn-disconnected

echo "Theme mode"
theme() { PERIHELION_GLASS_FORCE=1 python3 -I "${repo}/perihelion-theme" --color '#d9a441' --force "$@" >/dev/null 2>&1; }
# Auto mode with a light palette: light window glass (the look in the report).
printf 'mode=auto\npalette=catppuccin-latte\n' > "${HOME}/.config/simpbar/theme"
theme --palette catppuccin-latte --mode auto
settings_shot Appearance theme-1-auto-light-palette
# Dark picked in Settings, light glass still on disk: Settings must be dark at once.
printf 'mode=dark\npalette=catppuccin-latte\n' > "${HOME}/.config/simpbar/theme"
settings_shot Appearance theme-2-dark-over-stale-light-glass
# After perihelion-theme has rewritten the glass for Dark.
theme --palette catppuccin-latte --mode dark
settings_shot Appearance theme-3-dark
settings_shot XWayland theme-4-dark-mango-page
rm -rf "${HOME}/.config/gtk-4.0" "${HOME}/.config/gtk-3.0" "${HOME}/.config/simpbar/theme"

echo "Dock"
dock_shots() {  # $1 = label
    SIMPBAR_DOCK=1 setsid -f perihelion-bar >>"${work}/bar.log" 2>&1
    sleep 2
    shot "dock-$1" -g "450,930 600x70"
    # the pointer over the launcher, at the left end
    swaymsg -q "seat seat0 cursor set 560 972" 2>/dev/null; sleep 1
    shot "dock-$1-hover" -g "450,930 600x70"
    swaymsg -q "seat seat0 cursor set 100 100" 2>/dev/null
    pkill -x perihelion-bar; sleep 0.7
}
write_bar_config true;  dock_shots border-light
write_bar_config false; dock_shots noborder-light
background '#20242c'
write_bar_config true;  dock_shots border-dark
write_bar_config false; dock_shots noborder-dark
# Enlarged, pixel for pixel, to judge the corners.
for f in "${out}"/dock-*.png; do
    magick "${f}" -filter point -resize 300% "${f%.png}-3x.png" 2>/dev/null || true
done

echo
if (( fails > 0 )); then echo "${fails} picture(s) failed"; exit 1; fi
echo "All pictures taken: $(ls "${out}" | wc -l) files in ${out}"
