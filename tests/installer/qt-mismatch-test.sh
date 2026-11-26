#!/usr/bin/env bash
# Quickshell built against another Qt than the one installed (Qt updated
# before the distro rebuilt Quickshell): it crashes at start "likely due to
# a Qt version mismatch". The installer's last checks must say so in plain
# words (warn only, per distro family), and the app drawer must not leave a
# crash dialog on the desktop: crash handler off, the crash logged to the
# session trace log. A stand-in quickshell; nothing real is started.
# shellcheck disable=SC2329,SC2034,SC2030,SC2031  # helpers run through check(); variables read by the sourced scripts; subshells scope PATH/HOME on purpose
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t}"' EXIT
fails=0
check() { if "$@"; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }

bin=${t}/bin
mkdir -p "${bin}"
# quickshell -V -v prints what the real one does; ${t}/qt holds the line
# after "Qt: ". Started as a daemon it records its environment and
# arguments, then exits as ${t}/rc says (139 = SIGSEGV, as in the crash).
cat > "${bin}/quickshell" <<EOF
#!/bin/sh
if [ "\$1" = -V ]; then
    echo "===== Version Information ====="
    echo "Quickshell: 0.3.2 (revision , distributed by Arch Linux)"
    echo "Qt: \$(cat "${t}/qt")"
    echo
    echo "===== Build Information ====="
    exit 0
fi
case "\$1" in ipc|kill) exit 255 ;; esac
echo "args=\$* crash_handler_off=\${QS_DISABLE_CRASH_HANDLER:-}" >> "${t}/runs"
exit \$(cat "${t}/rc" 2>/dev/null || echo 0)
EOF
chmod 755 "${bin}/quickshell"

# installer FAMILY: run the installer's Qt check with the stand-in.
installer() {
    (
        export PATH="${bin}:${PATH}" HOME="${t}/home"
        mkdir -p "${HOME}"
        source "${repo}/install.sh"
        STATE_DIR=${t}/state LOG_FILE=${t}/state/install.log
        mkdir -p "${STATE_DIR}"
        WARNINGS=() DISTRO_FAMILY=$1
        # shellcheck disable=SC1090
        source "${repo}/scripts/packages-$1.sh"
        source "${repo}/scripts/autostart.sh"
        check_quickshell_qt
        printf 'WARNINGS=%s\n' "${#WARNINGS[@]}"
    ) > "${t}/out" 2>&1
}
out_has() { grep -qF -- "$1" "${t}/out"; }

echo "## Arch: mismatch -> the plain-words warning with the pacman/AUR fix"
echo "6.12.1 (built against 6.12.0)" > "${t}/qt"
installer arch
check out_has "Quickshell was built for Qt 6.12.0, your system has Qt 6.12.1; the app drawer may crash. Run sudo pacman -Syu; if it persists, wait for the repo rebuild or rebuild quickshell from the AUR (paru -S quickshell-git --rebuild)."
check out_has "WARNINGS=1"

echo "## Fedora and PikaOS: the same warning, their own package manager"
installer fedora
check out_has "Quickshell was built for Qt 6.12.0, your system has Qt 6.12.1; the app drawer may crash. Run sudo dnf upgrade --refresh"
installer pikaos
check out_has "your system has Qt 6.12.1; the app drawer may crash. Run sudo apt update && sudo apt full-upgrade"

echo "## matching Qt: no warning"
echo "6.12.1" > "${t}/qt"
installer arch
check out_has "WARNINGS=0"
check test "$(grep -c 'Quickshell was built' "${t}/out")" = 0

echo "## no quickshell installed: no warning, no error"
mv "${bin}/quickshell" "${bin}/qs.off"
(
    export PATH="${bin}:/usr/bin:/bin" HOME="${t}/home"
    source "${repo}/install.sh"
    WARNINGS=() DISTRO_FAMILY=arch
    source "${repo}/scripts/packages-arch.sh"
    source "${repo}/scripts/autostart.sh"
    # Only a real quickshell outside the stand-in folder could answer.
    check_command() { [[ $1 != quickshell ]] && command -v "$1" >/dev/null; }
    check_quickshell_qt
    printf 'WARNINGS=%s\n' "${#WARNINGS[@]}"
) > "${t}/out" 2>&1
check out_has "WARNINGS=0"
mv "${bin}/qs.off" "${bin}/quickshell"

# drawer CMD: run the appdrawer script with the stand-in, then wait for its
# background watcher to log (or not).
logs=${t}/logs
log=${logs}/perihelion-session-start/trace.log
drawer() {
    rm -f "${t}/runs" "${log}"
    env HOME="${t}/home" PATH="${bin}:/usr/bin:/bin" PERIHELIONBAR_LOG_DIR="${logs}" XDG_DATA_HOME="${t}/data" \
        sh "${repo}/appdrawer" "$1" > /dev/null 2>&1
    local i=0
    while [ "${i}" -lt 50 ] && [ ! -s "${t}/runs" ]; do sleep 0.1; i=$((i + 1)); done
    sleep 0.5
}

echo "## app drawer crash (Qt mismatch): no crash dialog, logged with the versions"
echo "6.12.1 (built against 6.12.0)" > "${t}/qt"
echo 139 > "${t}/rc"
drawer start
check grep -q 'crash_handler_off=1' "${t}/runs"
check test "$(grep -c -- ' -d' "${t}/runs")" = 0
check grep -q 'appdrawer: quickshell crashed (signal 11); Qt 6.12.1 (built against 6.12.0): a Qt version mismatch' "${log}"

echo "## any other crash: logged, with where to find the details"
echo "6.12.1" > "${t}/qt"
echo 134 > "${t}/rc"
drawer start
check grep -q 'appdrawer: quickshell crashed (signal 6) (Qt 6.12.1); details: quickshell log -c appdrawer' "${log}"

echo "## stopped normally (quickshell kill, logout): nothing logged"
for rc in 0 143; do
    echo "${rc}" > "${t}/rc"
    drawer restart
    check grep -q 'crash_handler_off=1' "${t}/runs"
    check test ! -s "${log}"
done

exit "${fails}"
