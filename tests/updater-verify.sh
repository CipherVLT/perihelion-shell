#!/usr/bin/env bash
# The updater's verification, end to end and offline: a release made by
# tools/make-release.sh from this build must pass `perihelion-settings
# --verify-update`, and each kind of bad release must be refused with
# nothing installed (verify never installs; this checks it says no, and why).
#
# Run from the repo root after building both packages with -Dversion=VERSION.
# Usage: tests/updater-verify.sh VERSION
set -u
version=${1:?usage: updater-verify.sh VERSION}
tag="v${version}"
root=$(pwd)
settings="${root}/perihelionbar/zig-out/bin/perihelion-settings"
top="perihelion-shell-${version}-x86_64"

work=$(mktemp -d)
export HOME="${work}/home"
mkdir -p "${HOME}"
unset DISPLAY WAYLAND_DISPLAY
fails=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
trap 'rm -rf "${work}"' EXIT

verify() { timeout 120 "${settings}" --verify-update "$1" "$2" 2>/dev/null | tail -n 1; }

# Re-packs a changed copy of the staged release into a new folder with a
# matching SHA256SUMS (what an attacker who controls the files would do).
repack() {  # $1 = stage dir (holding ${top}), $2 = new out dir
    mkdir -p "$2"
    tar --owner=0 --group=0 --numeric-owner --sort=name -C "$1" -czf "$2/${top}.tar.gz" "${top}"
    ( cd "$2" && sha256sum "${top}.tar.gz" > SHA256SUMS )
}
copy_stage() {  # $1 = new stage dir
    mkdir -p "$1"
    cp -a "${work}/good/stage/${top}" "$1/"
}
expect_refused() {  # $1 = name, $2 = dir, $3 = text the error must contain, [$4 = tag]
    local line
    line=$(verify "$2" "${4:-${tag}}")
    if [[ ${line} == error* && ${line} == *"$3"* ]]; then pass "$1: refused (${line#error })"
    else fail "$1: expected an error with '$3', got: ${line}"; fi
}

echo "Building the release"
if ! tools/make-release.sh "${version}" "${work}/good" >/dev/null; then
    echo "  FAIL  tools/make-release.sh"; exit 1
fi

line=$(verify "${work}/good" "${tag}")
if [[ ${line} == "ready ${work}/good" ]]; then pass "the release passes"; else fail "the release: ${line}"; fi

# 1. One byte of the tarball changed, SHA256SUMS left as it was.
mkdir -p "${work}/flip"
cp "${work}/good/${top}.tar.gz" "${work}/good/SHA256SUMS" "${work}/flip/"
printf '\xff' | dd of="${work}/flip/${top}.tar.gz" bs=1 seek=2000 conv=notrunc status=none
expect_refused "changed byte" "${work}/flip" "checksum does not match"

# 2. No SHA256SUMS line for the tarball.
mkdir -p "${work}/nosum"
cp "${work}/good/${top}.tar.gz" "${work}/nosum/"
: > "${work}/nosum/SHA256SUMS"
expect_refused "empty SHA256SUMS" "${work}/nosum" "SHA256SUMS"

# 3. An extra file the allowlist doesn't know.
copy_stage "${work}/s-extra"
printf '#!/bin/sh\n' > "${work}/s-extra/${top}/bin/evil"
repack "${work}/s-extra" "${work}/extra"
expect_refused "unknown file" "${work}/extra" "unexpected file"

# 4. A symlink in place of a program.
copy_stage "${work}/s-link"
rm "${work}/s-link/${top}/bin/perihelion-lock"
ln -s /etc/passwd "${work}/s-link/${top}/bin/perihelion-lock"
repack "${work}/s-link" "${work}/link"
expect_refused "symlink" "${work}/link" "not a plain file"

# 5. MANIFEST sending the drawer into ~/.config.
copy_stage "${work}/s-cfg"
sed -i 's|~/.local/share/perihelionbar/appdrawer/shell.qml|~/.config/quickshell/appdrawer/shell.qml|' "${work}/s-cfg/${top}/MANIFEST"
repack "${work}/s-cfg" "${work}/cfg"
expect_refused "manifest into ~/.config" "${work}/cfg" "somewhere it does not belong"

# 6. A program that does not start here (as a missing library looks).
copy_stage "${work}/s-lib"
printf '#!/bin/sh\necho "perihelion-shell: error while loading shared libraries: libfoo.so.1: cannot open shared object file"\nexit 127\n' > "${work}/s-lib/${top}/bin/perihelion-shell"
chmod 755 "${work}/s-lib/${top}/bin/perihelion-shell"
repack "${work}/s-lib" "${work}/lib"
expect_refused "program fails --version" "${work}/lib" "does not start on this system"

# 7. A required program left out of MANIFEST.
copy_stage "${work}/s-miss"
sed -i '/bin\/perihelion-lockscreen/d' "${work}/s-miss/${top}/MANIFEST"
rm "${work}/s-miss/${top}/bin/perihelion-lockscreen"
repack "${work}/s-miss" "${work}/miss"
expect_refused "missing program" "${work}/miss" "missing bin/perihelion-lockscreen"

# 8. The right files, but checked as another version.
expect_refused "other version" "${work}/good" "SHA256SUMS" "v9.9.9"

if (( fails > 0 )); then echo "${fails} check(s) failed"; exit 1; fi
echo "all updater checks passed"
