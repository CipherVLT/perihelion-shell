#!/usr/bin/env bash
# shellcheck disable=SC2329  # helpers run through check()
# perihelion-session (the login session) and perihelion-session-start (the
# one autostart line), against a throwaway home with stand-in programs: no
# real Mango, bar or daemon is started and nothing outside the temp folder
# is read or written.
#   tests/session/session-test.sh
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
t=$(mktemp -d)
trap 'pkill -f "${t}/" 2>/dev/null; rm -rf "${t}"' EXIT

fails=0
check() { if "$@"; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }
step() { printf '\n## %s\n' "$*"; }

# ---------------------------------------------------------------- session
step "perihelion-session: a home without ~/.config/mango"
defaults=${t}/defaults
mkdir -p "${defaults}/cfg"
cp "${repo}/desktop/mango/config.conf" "${defaults}/"
cp "${repo}"/desktop/mango/cfg/*.conf "${defaults}/cfg/"
bin=${t}/bin
mkdir -p "${bin}"
cat > "${bin}/mango" <<'EOF'
#!/bin/sh
printf 'mango %s\n' "$*" >> "$HOME/mango-runs"
EOF
chmod 755 "${bin}/mango"
home=${t}/home
mkdir -p "${home}"
login() { env -i HOME="${home}" PATH="${bin}:/usr/bin:/bin" PERIHELION_MANGO_DEFAULTS="${defaults}" \
    bash "${repo}/desktop/bin/perihelion-session" "$@"; }
snapshot() { (cd "${home}/.config/mango" && find . -type f -print0 | sort -z | xargs -0 sha256sum; find . -printf '%p %m\n' | sort); }
unchanged() { [ "$(snapshot)" = "${before}" ]; }

login
check test -f "${home}/.config/mango/config.conf"
check diff -r "${defaults}" "${home}/.config/mango"
check grep -qx 'exec_once=perihelion-session-start' "${home}/.config/mango/cfg/autostart.conf"
check grep -qx 'mango ' "${home}/mango-runs"
check test "$(stat -c %a "${home}/.config/mango/config.conf")" = 644

step "second login changes nothing"
before=$(snapshot)
login --some-arg
check unchanged
check grep -qx 'mango --some-arg' "${home}/mango-runs"

step "a config of yours is never touched (not even a missing part added)"
rm -rf "${home}/.config/mango"
mkdir -p "${home}/.config/mango"
printf 'bind=SUPER,t,spawn,foot\n' > "${home}/.config/mango/config.conf"
before=$(snapshot)
login
check unchanged
check test ! -e "${home}/.config/mango/cfg"

step "no defaults installed: still starts Mango"
rm -rf "${home}/.config/mango"
env -i HOME="${home}" PATH="${bin}:/usr/bin:/bin" PERIHELION_MANGO_DEFAULTS="${t}/nowhere" \
    bash "${repo}/desktop/bin/perihelion-session"
check test ! -e "${home}/.config/mango/config.conf"
check test "$(wc -l < "${home}/mango-runs")" -eq 4

step "XDG_CONFIG_HOME is followed"
env -i HOME="${home}" XDG_CONFIG_HOME="${t}/xdg" PATH="${bin}:/usr/bin:/bin" PERIHELION_MANGO_DEFAULTS="${defaults}" \
    bash "${repo}/desktop/bin/perihelion-session"
check test -f "${t}/xdg/mango/cfg/keybinds.conf"

# ---------------------------------------------------------------- starter
# Stand-ins: each program records that it started and "runs" (a line in
# procs/ that the stand-in pgrep matches against).
sbin=${t}/sbin procs=${t}/procs
mkdir -p "${sbin}" "${procs}"
stub() { # NAME [PROCESS COMMAND LINE it leaves running]
    cat > "${sbin}/$1" <<EOF
#!/bin/sh
echo "\$0 \$*" >> "${t}/started"
[ -n "${2:-}" ] && printf '%s\n' "${2:-}" > "${procs}/$1"
exit 0
EOF
    chmod 755 "${sbin}/$1"
}
stub dbus-update-activation-environment
stub mako "mako"
stub perihelion-wallpaper "swaybg -m fill -i x"
stub perihelion-bar-start "perihelion-bar"
stub perihelion-shell "perihelion-shell"
stub appdrawer "quickshell -p ${t}/appdrawer -d"
stub swayidle "swayidle -w timeout 600 perihelion-lock before-sleep perihelion-lock"
stub perihelion-nightlight "wlsunset -t 4000"
stub polkit-agent "/usr/libexec/polkit-mate-authentication-agent-1"
cat > "${sbin}/pgrep" <<EOF
#!/bin/sh
# pgrep -u UID -f -- PATTERN, over the stand-in processes only
for a; do pat=\$a; done
cat "${procs}"/* 2>/dev/null | grep -qE -- "\$pat"
EOF
cat > "${sbin}/busctl" <<EOF
#!/bin/sh
[ -e "${t}/notif-owned" ] && echo 'b true' || echo 'b false'
EOF
chmod 755 "${sbin}/pgrep" "${sbin}/busctl"
rt=${t}/run
mkdir -p "${rt}"
start() { env -i HOME="${home}" XDG_RUNTIME_DIR="${rt}" PATH="${sbin}:/usr/bin:/bin" \
    PERIHELION_POLKIT_AGENTS="${sbin}/polkit-agent" bash "${repo}/desktop/bin/perihelion-session-start"; }
# setsid -f returns before the child runs; wait for N starts.
wait_starts() { local _; for _ in $(seq 1 50); do [ "$(wc -l < "${t}/started" 2>/dev/null || echo 0)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
count() { local n; n=$(grep -c -- "$1" "${t}/started" 2>/dev/null) || true; echo "${n:-0}"; }
log=${home}/.config/perihelionbar-config/logs/perihelion-session-start/trace.log

step "perihelion-session-start: first run starts every piece once"
start
check wait_starts 9
for p in dbus-update-activation-environment mako perihelion-wallpaper perihelion-bar-start perihelion-shell \
    appdrawer swayidle perihelion-nightlight polkit-agent; do
    check test "$(count "/${p} ")" -eq 1
done
check grep -q '/appdrawer start$' "${t}/started"
check grep -q 'done: started' "${log}"

step "second run: everything is running, nothing starts again (dbus env is refreshed)"
: > "${t}/started"
start
sleep 0.5
check test "$(grep -vc '/dbus-update-activation-environment ' "${t}/started")" -eq 0
check grep -q 'started nothing; already running notifications polkit wallpaper bar shell appdrawer idle-lock nightlight' "${log}"

step "only what stopped is started again"
rm -f "${procs}/perihelion-shell" "${procs}/swayidle"
: > "${t}/started"
start
check wait_starts 3
sleep 0.3
check test "$(count '/perihelion-shell ')" -eq 1
check test "$(count '/swayidle ')" -eq 1
check test "$(count '/perihelion-bar-start ')" -eq 0

step "two at once: the second exits, nothing is doubled"
rm -f "${procs}"/*
: > "${t}/started"
exec 8>"${rt}/perihelion-session-start-$(id -u).lock"
flock 8
start
sleep 0.3
check test ! -s "${t}/started"
check grep -q 'another perihelion-session-start is running' "${log}"
exec 8>&-
start
check wait_starts 9
sleep 0.3
check test "$(count '/perihelion-bar-start ')" -eq 1

step "the lock is not inherited by what it starts"
# The stand-ins have exited, but a real daemon keeps running: start one that
# sleeps, then a later run must still get the lock.
rm -f "${procs}"/* && : > "${t}/started"
cat > "${sbin}/perihelion-shell" <<EOF
#!/bin/sh
echo "\$0 \$*" >> "${t}/started"
exec sleep 30
EOF
start
check wait_starts 9
lock_free() { flock -n "${rt}/perihelion-session-start-$(id -u).lock" true; }
check lock_free

step "another notification daemon owns the name: mako is not started"
rm -f "${procs}"/* && : > "${t}/started"
touch "${t}/notif-owned"
start
check wait_starts 8
sleep 0.3
check test "$(count '/mako ')" -eq 0

step "a missing program is logged and the rest still start"
rm -f "${procs}"/* "${t}/notif-owned" "${sbin}/appdrawer" && : > "${t}/started"
start
check wait_starts 8
check grep -q 'missing appdrawer: appdrawer is not installed' "${log}"
check test "$(count '/swayidle ')" -eq 1

(( fails == 0 )) && echo "session-test: all passed" || echo "session-test: FAILED"
exit "${fails}"
