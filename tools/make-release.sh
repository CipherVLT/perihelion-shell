#!/usr/bin/env bash
# Builds a Perihelion Shell release from already-built programs:
#
#   OUTDIR/perihelion-shell-VERSION-x86_64.tar.gz
#   OUTDIR/SHA256SUMS
#
# The tarball holds one folder with bin/ (the five compiled programs and the
# scripts install.sh puts in /usr/bin), appdrawer/ (the drawer's QML) and
# MANIFEST, which perihelion-settings prints from the updater's own
# allowlist (--release-manifest), so the two can never disagree.
#
# Run from the repo root after `zig build -Doptimize=ReleaseFast
# -Dversion=VERSION` in perihelionbar/ and perihelionbar-shell/.
# OUTDIR must not exist yet; nothing is ever deleted.
#
# Usage: tools/make-release.sh VERSION OUTDIR
set -euo pipefail
version=${1:?usage: make-release.sh VERSION OUTDIR}
out=${2:?usage: make-release.sh VERSION OUTDIR}
root=$(pwd)
bar_bin="${root}/perihelionbar/zig-out/bin"
shell_bin="${root}/perihelionbar-shell/zig-out/bin"
[[ -x "${bar_bin}/perihelion-settings" ]] || { echo "build perihelionbar first" >&2; exit 1; }
[[ -e "${out}" ]] && { echo "${out} already exists" >&2; exit 1; }

top="perihelion-shell-${version}-x86_64"
stage="${out}/stage/${top}"
mkdir -p "${stage}/bin" "${stage}/appdrawer"
"${bar_bin}/perihelion-settings" --release-manifest > "${stage}/MANIFEST"

while read -r mode src _dest; do
    name=$(basename "${src}")
    case "${src}" in
        bin/perihelion-bar|bin/perihelion-settings|bin/perihelionbar-welcome) from="${bar_bin}/${name}" ;;
        bin/perihelion-shell|bin/perihelion-lockscreen) from="${shell_bin}/${name}" ;;
        bin/perihelion-session|bin/perihelion-session-start) from="${root}/desktop/bin/${name}" ;;
        bin/*) from="${root}/${name}" ;;
        appdrawer/*) from="${root}/quickshell/appdrawer/${name}" ;;
        *) echo "unknown manifest entry: ${src}" >&2; exit 1 ;;
    esac
    [[ -f "${from}" ]] || { echo "missing: ${from}" >&2; exit 1; }
    install -m "${mode}" "${from}" "${stage}/${src}"
done < "${stage}/MANIFEST"

tar --owner=0 --group=0 --numeric-owner --sort=name --mtime=@0 \
    -C "${out}/stage" -czf "${out}/${top}.tar.gz" "${top}"
( cd "${out}" && sha256sum "${top}.tar.gz" > SHA256SUMS )
echo "${out}/${top}.tar.gz"
cat "${out}/SHA256SUMS"
