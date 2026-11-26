#!/usr/bin/env bash
# The installer end to end in a container (run as root): Arch, CachyOS or
# Fedora 45 (CI's installer jobs). Users get passwordless sudo, as a desktop
# user who typed their password once would have.
#   tests/installer/e2e.sh <mango|hyprland>
# shellcheck disable=SC1091,SC2012,SC2034,SC2329  # helpers run through check(); variables are read by the sourced installer
set -Eeuo pipefail

wm=$1
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
commit=$(git -C "${repo}" rev-parse --short=7 HEAD)

if command -v pacman >/dev/null; then
    pacman -Syu --noconfirm --needed sudo git >/dev/null
else
    dnf install -y --setopt=install_weak_deps=False sudo git-core shadow-utils util-linux procps-ng findutils >/dev/null
fi

as_user() { # USER COMMAND...
    local u=$1
    shift
    runuser -u "${u}" -- env -i HOME="/home/${u}" USER="${u}" PATH=/usr/bin:/bin LANG=C.UTF-8 "$@"
}

new_user() {
    useradd -m "$1"
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$1" > "/etc/sudoers.d/$1"
    rm -rf "/home/$1/src"
    cp -a "${repo}" "/home/$1/src"
    chown -R "$1:$1" "/home/$1/src"
}

snapshot() { # USER: every file the installer may touch, with its hash
    {
        find /usr/bin -maxdepth 1 \( -name 'perihelion*' -o -name appdrawer \) -print0 | sort -z | xargs -0 sha256sum
        sha256sum /etc/pam.d/perihelion-lock
        cd "/home/$1" && find .config .local/share/perihelionbar/appdrawer .local/state/perihelionbar \
            -path .local/state/perihelionbar/install.log -prune -o -type f -print0 | sort -z | xargs -0 sha256sum
    }
}

fails=0
step() { printf '\n######## %s\n' "$*"; }

step "fresh home: install.sh --yes --wm=${wm}"
new_user fresh
as_user fresh bash -c "cd ~/src && ./install.sh --yes --wm=${wm}"
(cd "${repo}" && as_user fresh bash "${repo}/tests/installer/install-check.sh" "${wm}" "${commit}") || fails=1
check() { if "$@"; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }
check test -x /home/fresh/.local/share/perihelionbar/zig-0.17.1/zig
zig_version() { [[ $(/home/fresh/.local/share/perihelionbar/zig-0.17.1/zig version) == 0.17.1 ]]; }
check zig_version
check grep -q 'Zig 0.17.1: signature checked (minisign)' /home/fresh/.local/state/perihelionbar/install.log

step "second run changes nothing"
before=$(snapshot fresh)
out=$(as_user fresh bash -c "cd ~/src && ./install.sh --yes --wm=${wm}" 2>&1)
printf '%s\n' "${out}" | tail -n 30
grep -q "Programs already built at ${commit}" <<<"${out}" || { echo "FAIL: second run rebuilt"; fails=1; }
after=$(snapshot fresh)
if [[ ${before} != "${after}" ]]; then
    echo "FAIL: the second run changed files:"
    diff <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") || true
    fails=1
fi
ls -d /home/fresh/.local/state/perihelionbar/backup-* 2>/dev/null && { echo "FAIL: backups on a fresh home"; fails=1; }

step "existing setup, --existing=new: replaced after a backup"
new_user olduser
mkdir -p /home/olduser/.config/mango/cfg /home/olduser/.config/hypr /home/olduser/.config/perihelionbar
printf 'my mango\n' > /home/olduser/.config/mango/config.conf
printf 'bind=SUPER,t,spawn,foot\n' > /home/olduser/.config/mango/cfg/keybinds.conf
printf -- '-- my hyprland\nhl.env("MINE", "1")\n' > /home/olduser/.config/hypr/hyprland.lua
printf '{ "mine": true }\n' > /home/olduser/.config/perihelionbar/config.json
chown -R olduser:olduser /home/olduser/.config
as_user olduser bash -c "cd ~/src && ./install.sh --yes --wm=${wm} --existing=new"
(cd "${repo}" && as_user olduser bash "${repo}/tests/installer/install-check.sh" "${wm}" "${commit}") || fails=1
b=$(ls -d /home/olduser/.local/state/perihelionbar/backup-* | head -1)
check() { if "$@"; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }
check grep -qx '{ "mine": true }' "${b}/.config/perihelionbar/config.json"
if [[ ${wm} == mango ]]; then
    check grep -qx 'my mango' "${b}/.config/mango/config.conf"
    check grep -qx 'bind=SUPER,t,spawn,foot' "${b}/.config/mango/cfg/keybinds.conf"
else
    check grep -qx 'hl.env("MINE", "1")' /home/olduser/.config/hypr/hyprland.lua
    check grep -qx -- '-- my hyprland' "${b}/.config/hypr/hyprland.lua"
fi

step "existing setup, run again: nothing changes, no new backup"
before=$(snapshot olduser)
as_user olduser bash -c "cd ~/src && ./install.sh --yes --wm=${wm}" | tail -n 15
check test "$(snapshot olduser)" = "${before}"
check test "$(ls -d /home/olduser/.local/state/perihelionbar/backup-* | wc -l)" -eq 1

step "existing setup, plain --yes: yours kept, Perihelion's written beside"
new_user keeper
mkdir -p /home/keeper/.config/kitty
printf 'font_size 14\n' > /home/keeper/.config/kitty/kitty.conf
chown -R keeper:keeper /home/keeper/.config
as_user keeper bash -c "cd ~/src && ./install.sh --yes --wm=${wm}" | tail -n 15
check grep -qx 'font_size 14' /home/keeper/.config/kitty/kitty.conf
check test -f /home/keeper/.config/kitty/kitty.conf.perihelion-new
check grep -q 'file:~/.config/kitty/kitty.conf=beside' /home/keeper/.local/state/perihelionbar/installer-answers

if [[ ${wm} == mango ]]; then
    step "a user created after the install: first login through the Perihelion session"
    useradd -m latecomer
    # A stand-in mango: the session runs `exec mango`, which needs a display here.
    mkdir -p /tmp/stub-mango
    # shellcheck disable=SC2016  # expands when the stub runs
    printf '#!/bin/sh\necho "mango $*" > "$HOME/mango-ran"\n' > /tmp/stub-mango/mango
    chmod 755 /tmp/stub-mango/mango
    check test ! -e /home/latecomer/.config/mango
    runuser -u latecomer -- env -i HOME=/home/latecomer USER=latecomer PATH=/tmp/stub-mango:/usr/bin:/bin perihelion-session
    check test -f /home/latecomer/mango-ran
    check diff -r /usr/share/perihelion/mango /home/latecomer/.config/mango
    check mango -p -c /home/latecomer/.config/mango/config.conf
    check grep -qx 'exec_once=perihelion-session-start' /home/latecomer/.config/mango/cfg/autostart.conf
    owned_by_user() { [[ -z $(find /home/latecomer/.config/mango ! -user latecomer) ]]; }
    check owned_by_user
fi

step "not as root, not on another distro"
check bash -c "! bash ${repo}/install.sh --yes 2>/dev/null"
printf 'ID=debian\nID_LIKE=""\n' > /tmp/os-release-debian
refuses_debian() {
    local out
    out=$(as_user fresh env PERIHELION_OS_RELEASE=/tmp/os-release-debian bash "${repo}/install.sh" --yes 2>&1) && return 1
    grep -q 'supports Arch Linux, Arch-based distros and Fedora 45+' <<<"${out}"
}
check refuses_debian

step "on Perihelion Linux: says so, changes nothing"
touch /tmp/fake-perihelion.ref
on_perihelion() {
    local out before after
    before=$(snapshot fresh)
    out=$(as_user fresh env PERIHELION_ISO_REF=/tmp/fake-perihelion.ref bash "${repo}/install.sh" --yes 2>&1) || return 1
    after=$(snapshot fresh)
    grep -q 'This is Perihelion Linux: Perihelion Bar is already installed' <<<"${out}" &&
        grep -q 'Settings > Updates' <<<"${out}" && [[ ${before} == "${after}" ]]
}
check on_perihelion

(( fails == 0 )) && echo "e2e ($(. /etc/os-release && echo "${ID}"), ${wm}): all passed" || echo "e2e (${wm}): FAILED"
exit "${fails}"
