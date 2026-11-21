#!/usr/bin/env bash
# Live test: the bar and the shell come back when their output goes away.
#
# What resume can do to a session: the GPU re-probes its connectors, the
# compositor destroys the output (closing every layer surface on it) and a
# new output takes its place. Before respawn.zig the bar and the shell
# exited on `closed` and the desktop came back bare. Headless sway does the
# same thing on `output <name> unplug`.
#
# For each program: start it, add a second output, unplug the first, and
# expect exactly one copy running again (a new pid) with "restarting" in its
# log; then once more, to check the second restart too.
# Usage: tests/output-loss-live.sh <bar bin dir> [shell bin dir]
set -u
bar_bin=$(readlink -f "${1:?usage: output-loss-live.sh <bar bin dir> [shell bin dir]}")
shell_bin=${2:+$(readlink -f "$2")}
export PATH="${bar_bin}:${shell_bin:+${shell_bin}:}${PATH}"

work=$(mktemp -d)
export HOME="${work}/home" XDG_RUNTIME_DIR="${work}/run" PERIHELIONBAR_LOG_DIR="${work}/logs"
export XDG_CONFIG_HOME="${HOME}/.config" XDG_CACHE_HOME="${HOME}/.cache" XDG_STATE_HOME="${HOME}/.local/state"
mkdir -p "${HOME}/.config/perihelionbar" "${XDG_RUNTIME_DIR}" "${PERIHELIONBAR_LOG_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
unset WAYLAND_DISPLAY DISPLAY PERIHELIONBAR_DOCK PERIHELION_RESPAWN

fails=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
live() { [[ -e /proc/$1 ]] && [[ $(awk '/^State:/{print $2}' "/proc/$1/status" 2>/dev/null) != Z ]]; }
pids() { local p; for p in $(pgrep -x "$1"); do live "$p" && echo "$p"; done; }
cleanup() {
    pkill -x perihelion-bar 2>/dev/null
    pkill -x perihelion-shell 2>/dev/null
    [[ -n ${sway_pid:-} ]] && kill "${sway_pid}" 2>/dev/null
    if (( fails > 0 )); then
        echo "--- sway.log"; tail -n 30 "${work}/sway.log" 2>/dev/null
        echo "--- program logs"; find "${PERIHELIONBAR_LOG_DIR}" -name '*.log' -exec tail -n 20 {} + 2>/dev/null
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

font=$(fc-match -f '%{file}' monospace)
printf '{"appearance":{"font_path":"%s","position":"top"},"dock":{"enabled":true}}\n' "${font}" > "${HOME}/.config/perihelionbar/config.json"

echo "Starting a headless compositor"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    "${SWAY:-sway}" -c /dev/null >"${work}/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 1 100); do
    sock=$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -n 1)
    ipc=$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'sway-ipc.*.sock' 2>/dev/null | head -n 1)
    [[ -n ${sock} && -n ${ipc} ]] && break
    sleep 0.1
done
if [[ -z ${sock:-} || -z ${ipc:-} ]]; then fails=1; echo "  FAIL  no compositor came up"; exit 1; fi
export WAYLAND_DISPLAY=$(basename "${sock}")
msg() { "${SWAYMSG:-swaymsg}" -s "${ipc}" "$@" >/dev/null 2>&1; }
outputs() { "${SWAYMSG:-swaymsg}" -s "${ipc}" -t get_outputs -r 2>/dev/null | grep -o '"name": *"HEADLESS-[0-9]*"' | grep -o 'HEADLESS-[0-9]*'; }

# Waits up to $2 tenths of a second for exactly one live copy of $1 whose
# pid is not $3; prints it.
wait_new() {
    local i p
    for i in $(seq 1 "$2"); do
        p=$(pids "$1")
        if [[ -n ${p} && ${p} != *$'\n'* && ${p} != "$3" ]]; then echo "${p}"; return 0; fi
        sleep 0.1
    done
    return 1
}

check() {  # $1 = program name, $2 = how to start it
    echo "${1}:"
    bash -c "$2" >>"${work}/$1.out" 2>&1 &
    local pid
    if ! pid=$(wait_new "$1" 50 none); then fail "$1 did not start"; return; fi
    sleep 1.5 # mapped and configured
    local round old
    for round in 1 2; do
        old=$(outputs | head -n 1)
        msg create_output
        sleep 0.5
        msg output "${old}" unplug
        if pid=$(wait_new "$1" 120 "${pid}"); then
            sleep 1 # and it stays: no second copy, no exit
            if [[ $(pids "$1" | wc -l) == 1 ]] && live "${pid}"; then
                pass "unplug ${round} (${old}): one $1 running again (pid ${pid})"
            else
                fail "unplug ${round}: $(pids "$1" | wc -l) copies after restart"
            fi
        else
            fail "unplug ${round} (${old}): $1 did not come back ($(pids "$1" | wc -l) running)"
        fi
    done
    if grep -rqs "restarting" "${PERIHELIONBAR_LOG_DIR}"; then pass "$1 logged the restart"
    else fail "$1: no 'restarting' line in its logs"; fi
}

# The bar and the dock together: after each unplug exactly one of each, with
# new pids (the dock must come back as the dock, not as a second bar).
role_pids() {  # $1 = bar|dock
    local pid
    for pid in $(pids perihelion-bar); do
        if tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep -q '^PERIHELIONBAR_DOCK=1'; then
            [[ $1 == dock ]] && echo "${pid}"
        else
            [[ $1 == bar ]] && echo "${pid}"
        fi
    done
}
echo "perihelion-bar and its dock:"
( exec env -u PERIHELIONBAR_DOCK perihelion-bar ) >>"${work}/bar.out" 2>&1 &
( PERIHELIONBAR_DOCK=1 exec perihelion-bar ) >>"${work}/dock.out" 2>&1 &
for _ in $(seq 1 50); do
    [[ -n $(role_pids bar) && -n $(role_pids dock) ]] && break
    sleep 0.1
done
bar_pid=$(role_pids bar); dock_pid=$(role_pids dock)
if [[ -z ${bar_pid} || -z ${dock_pid} ]]; then
    fail "bar (${bar_pid:-none}) or dock (${dock_pid:-none}) did not start"
else
    sleep 1.5
    for round in 1 2; do
        old=$(outputs | head -n 1)
        msg create_output
        sleep 0.5
        msg output "${old}" unplug
        for _ in $(seq 1 120); do
            nb=$(role_pids bar); nd=$(role_pids dock)
            [[ -n ${nb} && -n ${nd} && ${nb} != "${bar_pid}" && ${nd} != "${dock_pid}" \
               && ${nb} != *$'\n'* && ${nd} != *$'\n'* ]] && break
            sleep 0.1
        done
        sleep 1
        nb=$(role_pids bar); nd=$(role_pids dock)
        if [[ $(echo "${nb}" | grep -c .) == 1 && $(echo "${nd}" | grep -c .) == 1 \
              && ${nb} != "${bar_pid}" && ${nd} != "${dock_pid}" ]]; then
            pass "unplug ${round} (${old}): one bar (pid ${nb}) and one dock (pid ${nd}) again"
        else
            fail "unplug ${round} (${old}): bars [${nb//$'\n'/ }] docks [${nd//$'\n'/ }] (before: ${bar_pid}, ${dock_pid})"
        fi
        bar_pid=${nb}; dock_pid=${nd}
    done
    if grep -rqs "restarting" "${PERIHELIONBAR_LOG_DIR}"; then pass "the bar logged the restart"
    else fail "the bar: no 'restarting' line in its logs"; fi
fi
pkill -x perihelion-bar 2>/dev/null
rm -rf "${PERIHELIONBAR_LOG_DIR:?}"/*
if [[ -n ${shell_bin} ]]; then
    check perihelion-shell "exec perihelion-shell"
fi

if (( fails > 0 )); then echo "${fails} check(s) failed"; exit 1; fi
echo "all output-loss checks passed"
