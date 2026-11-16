#!/usr/bin/env bash
# The app drawer follows the picked icon theme, including variants that keep
# their icons behind links into a base theme (MacTahoe-dark, Papirus-Dark),
# and including a hicolor copy of the same app competing with it. Runs the
# drawer's own scan script and ranking (tests/drawer-icons.js reads them out
# of Icons.qml).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
h=$(mktemp -d)
trap 'rm -rf "${h}"' EXIT

mkdir -p "${h}/.config/gtk-3.0" "${h}/.icons" "${h}/.local/share/icons/hicolor/scalable/apps"
# Base theme, laid out like MacTahoe's installer does.
mkdir -p "${h}/.icons/Tahoe/apps/scalable"
printf '[Icon Theme]\nName=Tahoe\nInherits=hicolor\n' > "${h}/.icons/Tahoe/index.theme"
echo '<svg/>' > "${h}/.icons/Tahoe/apps/scalable/firefox.svg"
ln -s apps "${h}/.icons/Tahoe/apps@2x"
# The dark variant: own small icons, scalable ones linked from the base, and
# no Inherits of the base (as MacTahoe-dark ships).
mkdir -p "${h}/.icons/Tahoe-dark/apps/32"
printf '[Icon Theme]\nName=Tahoe-dark\nInherits=hicolor\n' > "${h}/.icons/Tahoe-dark/index.theme"
ln -s ../../Tahoe/apps/scalable "${h}/.icons/Tahoe-dark/apps/scalable"
# A light variant whose whole apps folder is a link.
mkdir -p "${h}/.icons/Tahoe-light"
printf '[Icon Theme]\nName=Tahoe-light\nInherits=hicolor\n' > "${h}/.icons/Tahoe-light/index.theme"
ln -s ../Tahoe/apps "${h}/.icons/Tahoe-light/apps"
# The app's own icon, which a themed one must beat.
echo '<svg/>' > "${h}/.local/share/icons/hicolor/scalable/apps/firefox.svg"

fail=0
for theme in Tahoe Tahoe-dark Tahoe-light; do
    printf '[Settings]\ngtk-icon-theme-name=%s\n' "${theme}" > "${h}/.config/gtk-3.0/settings.ini"
    got=$(node "${here}/drawer-icons.js" "${h}" firefox | awk '$1 == "firefox" {print $2}')
    want="${h}/.icons/${theme}/apps/scalable/firefox.svg"
    if [[ ${got} == "${want}" ]]; then
        echo "ok    ${theme}: ${got#"${h}"/}"
    else
        echo "FAIL  ${theme}: drawer picked ${got#"${h}"/}, want ${want#"${h}"/}"
        fail=1
    fi
done
exit "${fail}"
