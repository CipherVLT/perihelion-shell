#!/usr/bin/env bash
# remove_old_images: only files whose SHA-256 is listed go, in the home
# folder and under /usr/share (a fake root here); everything else stays.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "${here}/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t}"' EXIT

log() { :; }
ok() { printf 'ok: %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*"; }
need_sudo() { :; }
sudo() { "$@"; }
SRC_DIR=${src}
# shellcheck source=scripts/leftovers.sh
source "${src}/scripts/leftovers.sh"

fails=0
check() { if "$@"; then printf '  pass: %s\n' "$*"; else printf '  FAIL: %s\n' "$*"; fails=1; fi; }

# The shipped list parses: 13 sums, no names of people or old projects.
check test "$(old_image_sums "${src}/scripts/old-images.sha256" | wc -l)" -eq 13

home=${t}/home root=${t}/root
mkdir -p "${home}/.local/share/perihelionbar/assets/icons" "${home}/.local/share/perihelionbar/appdrawer" \
    "${root}/usr/share/icons/hicolor/scalable/apps" "${root}/usr/share/pixmaps"
printf 'old logo bytes' > "${home}/.local/share/perihelionbar/logo.png"
printf 'old svg bytes' > "${home}/.local/share/perihelionbar/assets/icons/perihelionbar-welcome.svg"
printf 'old svg bytes' > "${root}/usr/share/icons/hicolor/scalable/apps/perihelionbar-welcome.svg"
# Same names, different content: must stay.
printf 'my own logo' > "${home}/.local/share/perihelionbar/appdrawer/logo.png"
printf 'my own icon' > "${root}/usr/share/icons/hicolor/scalable/apps/perihelionbar-config.svg"
# A listed image somewhere not looked at: must stay.
printf 'old logo bytes' > "${home}/logo.png"
# A symlink to a listed image: never followed or removed.
ln -s "${home}/logo.png" "${home}/.local/share/perihelionbar/link.png"

list=${t}/sums
{
    printf '# test\n'
    printf '%s  logo\n' "$(printf 'old logo bytes' | sha256sum | cut -d' ' -f1)"
    printf '%s  svg\n' "$(printf 'old svg bytes' | sha256sum | cut -d' ' -f1)"
} > "${list}"

PERIHELION_SYSROOT=${root} remove_old_images "${home}" "${list}"

check test ! -e "${home}/.local/share/perihelionbar/logo.png"
check test ! -e "${home}/.local/share/perihelionbar/assets"
check test ! -e "${root}/usr/share/icons/hicolor/scalable/apps/perihelionbar-welcome.svg"
check test -f "${home}/.local/share/perihelionbar/appdrawer/logo.png"
check test -f "${root}/usr/share/icons/hicolor/scalable/apps/perihelionbar-config.svg"
check test -f "${home}/logo.png"
check test -L "${home}/.local/share/perihelionbar/link.png"

# Second run: nothing left to do, no error.
PERIHELION_SYSROOT=${root} remove_old_images "${home}" "${list}"
# No list: a warning, not a failure.
out=$(remove_old_images "${home}" "${t}/missing")
check test "${out#warn: }" != "${out}"

exit "${fails}"
