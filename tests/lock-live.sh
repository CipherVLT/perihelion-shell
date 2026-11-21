#!/usr/bin/env bash
# Live test: perihelion-lockscreen against a real ext-session-lock-v1
# compositor (headless sway, software rendering, no screen needed).
#
#   * -f returns 0 only once the lock is in place, and the locker keeps
#     running in the background;
#   * a second start while locked exits 0 and leaves the first lock alone;
#   * SIGTERM and SIGKILL end the locker without unlocking (the log never
#     says "unlocked"), and a new locker can take the lock over afterwards
#     (the recovery path the README documents).
#
# No password is ever typed here: PAM is not exercised (the auth handling is
# unit-tested against a fake in test-lock).
# Usage: tests/lock-live.sh <dir with perihelion-lockscreen> [picture dir]
set -u
bin=$(readlink -f "${1:?usage: lock-live.sh <bin dir> [picture dir]}")
shots=${2:-}
lockscreen="${bin}/perihelion-lockscreen"

work=$(mktemp -d)
export HOME="${work}/home" XDG_RUNTIME_DIR="${work}/run" PERIHELIONBAR_LOG_DIR="${work}/logs"
mkdir -p "${HOME}/.config/perihelionbar" "${XDG_RUNTIME_DIR}" "${PERIHELIONBAR_LOG_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
unset WAYLAND_DISPLAY DISPLAY
log="${PERIHELIONBAR_LOG_DIR}/perihelion-lockscreen/trace.log"

fails=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
lockers() { pgrep -x perihelion-lock | wc -l; } # comm is cut to 15 chars
cleanup() {
    pkill -9 -x perihelion-lock 2>/dev/null
    [[ -n ${sway_pid:-} ]] && kill "${sway_pid}" 2>/dev/null
    if (( fails > 0 )); then
        echo "--- sway.log"; tail -n 30 "${work}/sway.log" 2>/dev/null
        echo "--- lockscreen logs"; tail -n 60 "${PERIHELIONBAR_LOG_DIR}"/perihelion-lockscreen/*.log 2>/dev/null
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

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

# Starts `perihelion-lockscreen -f` and reports its exit status and time.
start_f() {
    local t0 t1 rc
    t0=$(date +%s%N)
    timeout 10 "${lockscreen}" -f
    rc=$?
    t1=$(date +%s%N)
    echo "${rc} $(( (t1 - t0) / 1000000 ))"
}

echo "-f locks, then returns"
read -r rc ms < <(start_f)
if [[ ${rc} == 0 ]]; then pass "-f returned 0 after ${ms} ms"; else fail "-f returned ${rc}"; fi
sleep 0.3
if [[ $(lockers) == 1 ]]; then pass "the locker keeps running in the background"; else fail "$(lockers) locker(s) running, expected 1"; fi
if grep -q 'lock: locked' "${log}" 2>/dev/null; then pass "the compositor confirmed the lock"; else fail "no 'locked' in the log"; fi
first=$(pgrep -x perihelion-lock | head -n 1)

if [[ -n ${shots} ]] && command -v grim >/dev/null; then
    mkdir -p "${shots}"
    grim "${shots}/lock-live.png" 2>/dev/null && pass "picture: lock-live.png" || echo "  (grim could not capture the locked output)"
fi

echo "A second start leaves the first lock alone"
read -r rc ms < <(start_f)
if [[ ${rc} == 0 ]]; then pass "second -f exited 0 (${ms} ms)"; else fail "second -f returned ${rc}"; fi
sleep 0.3
if [[ $(lockers) == 1 ]] && kill -0 "${first}" 2>/dev/null; then pass "the first locker is still in charge"; else fail "the first locker is gone or a second one stayed"; fi
if grep -q 'another lock is active' "${log}"; then pass "refusal logged"; else fail "refusal not logged"; fi

echo "SIGTERM ends the locker without unlocking"
kill -TERM "${first}"
for _ in $(seq 1 30); do kill -0 "${first}" 2>/dev/null || break; sleep 0.1; done
if ! kill -0 "${first}" 2>/dev/null; then pass "the locker exited on SIGTERM"; else fail "the locker ignored SIGTERM"; fi
if grep -q 'exiting with the session still locked' "${log}"; then pass "left the session locked"; else fail "no 'still locked' in the log"; fi

echo "Recovery: a new locker takes the lock over"
read -r rc ms < <(start_f)
if [[ ${rc} == 0 ]]; then pass "relock after the dead locker: -f returned 0 (${ms} ms)"; else fail "relock returned ${rc}"; fi
sleep 0.3
second=$(pgrep -x perihelion-lock | head -n 1)
if [[ -n ${second} ]]; then pass "a locker is running again"; else fail "no locker after relock"; fi

echo "SIGKILL (a crash) does not unlock either"
[[ -n ${second} ]] && kill -KILL "${second}"
sleep 0.5
read -r rc ms < <(start_f)
if [[ ${rc} == 0 ]]; then pass "relock after a crash: -f returned 0 (${ms} ms)"; else fail "relock after a crash returned ${rc}"; fi

if grep -q 'lock: unlocked' "${log}" 2>/dev/null; then fail "something unlocked the session"; else pass "nothing ever unlocked"; fi
if grep -Eqi 'password[^ ]* *(=|:|len)' "${PERIHELIONBAR_LOG_DIR}"/perihelion-lockscreen/*.log 2>/dev/null; then fail "the log mentions a password value"; else pass "no password details in the logs"; fi

echo
if (( fails > 0 )); then echo "${fails} check(s) failed"; exit 1; fi
echo "All lock screen checks passed"
