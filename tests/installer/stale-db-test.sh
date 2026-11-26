#!/usr/bin/env bash
# A stale package database: the mirrors answer 404 for the versions it lists
# (as with vulkan-intel 26.3.1 when the database was older than the mirror).
# The installer must explain it, force a refresh (pacman -Syyu / dnf clean
# metadata), retry once, and never stop without saying why. Stand-ins for
# sudo, pacman and dnf; nothing is installed.
# shellcheck disable=SC2329,SC2034  # helpers run through check(); variables read by the sourced scripts
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t}"' EXIT
fails=0
check() { if "$@"; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }

bin=${t}/bin
mkdir -p "${bin}"
# pacman: -Syu fails with a 404 while the "database" is stale; -Syyu
# refreshes it (removes ${t}/stale) and then succeeds. ${t}/broken: every
# download fails. ${t}/other: a non-download error.
cat > "${bin}/pacman" <<EOF
#!/bin/sh
echo "pacman \$*" >> "${t}/calls"
[ -e "${t}/other" ] && { echo "error: failed to prepare transaction (conflicting dependencies)"; exit 1; }
case " \$* " in *" -Syyu "*) [ -e "${t}/broken" ] || rm -f "${t}/stale" ;; esac
if [ -e "${t}/stale" ] || [ -e "${t}/broken" ]; then
    echo "error: failed retrieving file 'vulkan-intel-26.3.1-1-x86_64.pkg.tar.zst' from mirror.example : The requested URL returned error: 404"
    echo "error: failed to commit transaction (failed to retrieve some files)"
    exit 1
fi
echo "installed"
EOF
cat > "${bin}/dnf" <<EOF
#!/bin/sh
echo "dnf \$*" >> "${t}/calls"
case " \$* " in *" clean metadata "*) rm -f "${t}/stale"; exit 0 ;; esac
if [ -e "${t}/stale" ]; then
    echo "Curl error (22): HTTP response code said error for https://mirror.example/fedora/x.rpm [The requested URL returned error: 404]"
    exit 1
fi
echo "Complete!"
EOF
# apt-get (PikaOS): installs fail with 404 until "clean" + "update" ran.
cat > "${bin}/apt-get" <<EOF
#!/bin/sh
echo "apt-get \$*" >> "${t}/calls"
case " \$* " in *" clean "*) rm -f "${t}/stale"; exit 0 ;; *" update "*) exit 0 ;; esac
if [ -e "${t}/stale" ]; then
    echo "Err:1 https://ppa.pika-os.com pika/nest amd64 swaybg amd64 1.2.2-1"
    echo "  404  Not Found [IP: 192.0.2.1 443]"
    echo "E: Failed to fetch https://ppa.pika-os.com/pool/s/swaybg/swaybg_1.2.2-1_amd64.deb  404  Not Found"
    echo "E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?"
    exit 100
fi
echo "Setting up swaybg"
EOF
chmod 755 "${bin}/pacman" "${bin}/dnf" "${bin}/apt-get"

# run FAMILY OS_ID CODE: source the installer and that family's package
# script with stand-ins, then run CODE in a subshell (die exits it).
run() {
    local family=$1 osid=$2 code=$3
    (
        export PATH="${bin}:${PATH}" HOME="${t}/home"
        mkdir -p "${HOME}"
        source "${repo}/install.sh"
        STATE_DIR=${t}/state LOG_FILE=${t}/state/install.log
        mkdir -p "${STATE_DIR}"
        OPT_YES=1 WARNINGS=() PKGS_INSTALLED=() DISTRO_ID=${osid}
        sudo() { "$@"; }
        need_sudo() { :; }
        # shellcheck disable=SC1090
        source "${repo}/scripts/packages-${family}.sh"
        eval "${code}"
    ) > "${t}/out" 2>&1
}
out_has() { grep -q -- "$1" "${t}/out"; }
calls() { grep -c -- "$1" "${t}/calls" 2>/dev/null || true; }
reset() { rm -f "${t}/calls" "${t}/stale" "${t}/broken" "${t}/other"; }

echo "## Arch: stale database -> explained, pacman -Syyu, retried, installed"
reset; touch "${t}/stale"
run arch arch 'pacman_install vulkan-intel mangowm'; rc=$?
check test "${rc}" -eq 0
check out_has 'pacman could not download some packages'
check out_has 'mirror list or package database is out of date'
check out_has 'vulkan-intel-26.3.1'
check test "$(calls ' -Syu ')" -eq 1
check test "$(calls ' -Syyu ')" -eq 1
check out_has 'database refreshed'
check grep -q 'returned error: 404' "${t}/state/install.log"

echo "## CachyOS: the hint names cachyos-rate-mirrors"
reset; touch "${t}/stale"
run arch cachyos 'pacman_install vulkan-intel'
check out_has 'cachyos-rate-mirrors'

echo "## still failing after the refresh: stops, and says what to do"
reset; touch "${t}/broken"
run arch cachyos 'pacman_install vulkan-intel'; rc=$?
check test "${rc}" -ne 0
check out_has 'still return errors after a forced refresh'
check out_has 'cachyos-rate-mirrors'
check test "$(calls ' -Syyu ')" -eq 1

echo "## you say no to the refresh: stops, and says what to do"
reset; touch "${t}/stale"
run arch arch 'OPT_YES=0; ask_yes() { return 1; }; pacman_install vulkan-intel'; rc=$?
check test "${rc}" -ne 0
check out_has 'packages not installed. Refresh the database and mirrors'
check test "$(calls ' -Syyu ')" -eq 0

echo "## a different pacman error: no refresh offered, the error is shown"
reset; touch "${t}/other"
run arch arch 'pacman_install vulkan-intel'; rc=$?
check test "${rc}" -ne 0
check out_has 'conflicting dependencies'
check test "$(calls ' -Syyu ')" -eq 0

echo "## always refreshes first: the first transaction is -Syu --needed"
reset
run arch arch 'pacman_install mangowm'
check grep -q '^pacman -Syu --needed --noconfirm mangowm$' "${t}/calls"

echo "## Fedora: stale metadata -> explained, dnf clean metadata, retried"
reset; touch "${t}/stale"
run fedora fedora 'dnf_install mangowm'; rc=$?
check test "${rc}" -eq 0
check out_has 'dnf could not download some packages'
check test "$(calls 'clean metadata')" -eq 1
check test "$(calls 'install -y --refresh')" -eq 2

echo "## PikaOS: stale lists -> explained, apt-get clean + update, retried"
reset; touch "${t}/stale"
run pikaos pika 'apt_install swaybg'; rc=$?
check test "${rc}" -eq 0
check out_has 'apt could not download some packages'
check out_has 'pikman upgrade'
check test "$(calls 'apt-get clean')" -eq 1
check test "$(calls 'install -y --no-install-recommends swaybg')" -eq 2
refreshed_first() { [ "$(head -1 "${t}/calls")" = "apt-get update" ]; }
check refreshed_first

echo "## only what Perihelion Bar needs: no gaming, lib32, Discord or flatpak"
no_extras() {
    local f
    for f in "${repo}"/scripts/packages-arch.sh "${repo}"/scripts/packages-fedora.sh "${repo}"/scripts/packages-pikaos.sh; do
        if grep -v '^\s*#' "${f}" | grep -iE 'lib32|vulkan-|steam|discord|vesktop|flatpak|bazaar|gamemode|mangohud|nvidia'; then return 1; fi
    done
    return 0
}
check no_extras

(( fails == 0 )) && echo "stale-db-test: all passed" || echo "stale-db-test: FAILED"
exit "${fails}"
