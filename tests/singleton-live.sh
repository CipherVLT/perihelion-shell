#!/usr/bin/env bash
# Live test: one Perihelion Bar and one Dock, whatever is toggled.
#
# Runs the real perihelion-bar and perihelion-settings against a headless
# Wayland compositor (sway, no screen needed) and flips the same switches
# Perihelion Settings has, through its --bar / --dock command line (the code
# the switches run). After every step it counts the bars and docks that are
# actually running. Usage: tests/singleton-live.sh <dir with the binaries>
set -u
bin=$(readlink -f "${1:?usage: singleton-live.sh <bin dir>}")
export PATH="${bin}:${PATH}"

work=$(mktemp -d)
export HOME="${work}/home" XDG_RUNTIME_DIR="${work}/run"
export XDG_CONFIG_HOME="${HOME}/.config" XDG_CACHE_HOME="${HOME}/.cache" XDG_STATE_HOME="${HOME}/.local/state"
mkdir -p "${HOME}/.config/simpbar" "${XDG_RUNTIME_DIR}" "${work}/fake"
chmod 700 "${XDG_RUNTIME_DIR}"
unset WAYLAND_DISPLAY DISPLAY SIMPBAR_DOCK

fails=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }

# Bars / docks really running: perihelion-bar processes, told apart the way
# the shell itself does (started with SIMPBAR_DOCK=1 or not).
count() {  # $1 = bar|dock
    local n=0 pid
    for pid in $(pgrep -x perihelion-bar); do
        [[ -r /proc/${pid}/environ ]] || continue
        [[ $(awk '/^State:/{print $2}' "/proc/${pid}/status" 2>/dev/null) == Z ]] && continue
        if tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep -q '^SIMPBAR_DOCK=1'; then
            [[ $1 == dock ]] && n=$((n + 1))
        else
            [[ $1 == bar ]] && n=$((n + 1))
        fi
    done
    echo "${n}"
}
# Waits (up to 5 s) for the counts to settle at the expected values, then
# holds for a moment to catch a late extra copy.
expect() {  # $1 = bars, $2 = docks, $3 = step
    local i b d
    for i in $(seq 1 50); do
        b=$(count bar); d=$(count dock)
        [[ ${b} == "$1" && ${d} == "$2" ]] && break
        sleep 0.1
    done
    sleep 0.6
    b=$(count bar); d=$(count dock)
    if [[ ${b} == "$1" && ${d} == "$2" ]]; then pass "$3: ${b} bar, ${d} dock"
    else fail "$3: ${b} bar(s), ${d} dock(s); expected $1 and $2"; fi
}
settings() { perihelion-settings "$@" >>"${work}/settings.log" 2>&1; }
cleanup() {
    pkill -x perihelion-bar 2>/dev/null
    [[ -n ${sway_pid:-} ]] && kill "${sway_pid}" 2>/dev/null
    if (( fails > 0 )); then
        echo "--- sway.log"; tail -n 30 "${work}/sway.log" 2>/dev/null
        echo "--- bar.log"; tail -n 60 "${work}/bar.log" 2>/dev/null
        echo "--- settings.log"; tail -n 40 "${work}/settings.log" 2>/dev/null
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

# A font the bar can load (Perihelion ships its own) and the bar at the top,
# so the dock is allowed.
font=$(fc-match -f '%{file}' monospace)
printf '{"appearance":{"font_path":"%s","position":"top"}}\n' "${font}" > "${HOME}/.config/simpbar/config.json"

echo "Starting a headless compositor"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    "${SWAY:-sway}" -c /dev/null >"${work}/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 1 100); do
    sock=$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -n 1)
    [[ -n ${sock} ]] && break
    sleep 0.1
done
if [[ -z ${sock:-} ]]; then fails=1; echo "  FAIL  no compositor came up"; exit 1; fi
export WAYLAND_DISPLAY=${sock##*/}

start_bar()  { setsid -f env -u SIMPBAR_DOCK perihelion-bar >>"${work}/bar.log" 2>&1; }
start_dock() { SIMPBAR_DOCK=1 setsid -f perihelion-bar >>"${work}/bar.log" 2>&1; }

echo "Session start (what perihelion-bar-start does)"
settings --dock on            # the dock is off until switched on
start_dock; start_bar
expect 1 1 "session start"

# From here on Perihelion Settings runs the way it did when the bug showed:
# started from the dock, with the dock's SIMPBAR_DOCK=1 in its environment.
export SIMPBAR_DOCK=1

echo "The reported sequence"
settings --bar off;  expect 0 1 "bar off (no dock appears)"
settings --bar on;   expect 1 1 "bar on (a bar, not a second dock)"
for i in 1 2 3 4 5; do
    settings --dock off; expect 1 0 "dock off #${i}"
    settings --dock on;  expect 1 1 "dock on #${i}"
done

echo "As fast as possible, no pauses"
for i in $(seq 1 10); do settings --dock off; settings --dock on; done
expect 1 1 "10 quick dock off/on"
for i in $(seq 1 10); do settings --bar off; settings --bar on; done
expect 1 1 "10 quick bar off/on"
for i in 1 2 3 4 5; do settings --bar restart; done
expect 1 1 "5 quick Restart Bar"
settings --dock on; settings --dock on; settings --bar on; settings --bar on
expect 1 1 "switching on what is already on"

echo "Starting more copies by hand"
unset SIMPBAR_DOCK
for i in 1 2 3; do
    t0=$(date +%s%N)
    out=$(env -u SIMPBAR_DOCK perihelion-bar 2>&1); rc=$?
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    if [[ ${rc} == 0 && ${out} == *"bar: already running"* && ${ms} -lt 1000 ]]; then pass "second bar #${i} left on its own (${ms} ms)"
    else fail "second bar #${i}: exit ${rc} after ${ms} ms: ${out}"; fi
    t0=$(date +%s%N)
    out=$(SIMPBAR_DOCK=1 perihelion-bar 2>&1); rc=$?
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    if [[ ${rc} == 0 && ${out} == *"dock: already running"* && ${ms} -lt 1000 ]]; then pass "second dock #${i} left on its own (${ms} ms)"
    else fail "second dock #${i}: exit ${rc} after ${ms} ms: ${out}"; fi
done
for i in $(seq 1 8); do start_dock; start_bar; done
expect 1 1 "16 starts at once"

# Duplicates from a build without the lock: processes named perihelion-bar
# that hold no lock (a renamed sleep stands in for them).
cp "$(command -v sleep)" "${work}/fake/perihelion-bar"
old_copies() {  # $1 = docks, $2 = bars
    local i
    for i in $(seq 1 "$1"); do SIMPBAR_DOCK=1 setsid -f "${work}/fake/perihelion-bar" 600; done
    for i in $(seq 1 "$2"); do setsid -f env -u SIMPBAR_DOCK "${work}/fake/perihelion-bar" 600; done
    sleep 0.3
}
echo "Self-healing: duplicates left by an older build"
old_copies 2 1
expect 2 3 "three stray copies planted (2 docks, 1 bar)"
settings --dock on            # what opening Perihelion Settings does first
expect 1 1 "cleared when Settings runs"
old_copies 2 2
# Any settings or wallpaper change reloads the real bar and dock (SIGUSR1).
kill -USR1 "$(cat "${HOME}/.config/simpbar/simpbar.pid")" "$(cat "${HOME}/.config/simpbar/dock.pid")"
expect 1 1 "cleared by the running bar and dock at a reload"
old_copies 3 0
settings --dock off; expect 1 0 "dock off stops every copy"
settings --dock on;  expect 1 1 "dock back on: one"
settings --bar off;  expect 0 1 "final: bar off"
settings --bar on;   expect 1 1 "final: bar on"

echo
if (( fails > 0 )); then echo "${fails} step(s) failed"; exit 1; fi
echo "All steps passed: never more than one bar and one dock."
