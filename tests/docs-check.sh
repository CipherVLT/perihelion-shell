#!/usr/bin/env bash
# The install docs stay honest:
#  1. every relative link in README.md and docs/install/*.md points at a file
#     that exists (anchors are not checked);
#  2. every row of the README's distro table either names a guide whose
#     distro has an installer CI job (.github/workflows/installer.yml), or
#     says "experimental, not tested in CI". Perihelion Linux is tested by
#     the ISO repository's own CI, so its row may say "Tested in CI" too.
#   tests/docs-check.sh
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo}" || exit 1
fails=0
bad() { echo "  FAIL  $*"; fails=1; }

echo "## relative links"
n=0
for doc in README.md docs/install/*.md; do
    dir=$(dirname "${doc}")
    while IFS= read -r target; do
        target=${target%%#*}
        [[ -z ${target} ]] && continue
        n=$((n + 1))
        [[ -e "${dir}/${target}" ]] || bad "${doc}: link to ${target} (no such file)"
    done < <(grep -oE '\]\([^)[:space:]]+\)' "${doc}" | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^(https?:|mailto:|#)')
done
echo "  ${n} links checked"

echo "## distro table against CI"
jobs=$(sed -n -E 's/.*distro: *([a-z0-9-]+).*/\1/p' .github/workflows/installer.yml | sort -u | tr '\n' ' ')
echo "  installer CI jobs: ${jobs}"
rows=0
while IFS= read -r row; do
    rows=$((rows + 1))
    guide=$(grep -oE 'docs/install/[a-z-]+\.md' <<<"${row}" | head -1)
    name=$(basename "${guide:-?}" .md)
    status=$(awk -F'|' '{print $(NF-1)}' <<<"${row}")
    [[ -n ${guide} && -f ${guide} ]] || { bad "row without an existing guide: ${row}"; continue; }
    if grep -qi 'experimental, not tested in CI' <<<"${status}" && ! grep -qi '^ *Tested in CI' <<<"${status}"; then
        continue    # untested, and says so
    fi
    case "${name}" in
        perihelion-linux) continue ;;           # the ISO repository's CI
    esac
    if [[ " ${jobs} " != *" ${name} "* ]]; then
        bad "${name}: no installer CI job, but its row doesn't say \"experimental, not tested in CI\""
    fi
    grep -qi 'tested in CI' <<<"${status}" || bad "${name}: status doesn't say what CI tests"
done < <(awk '/^<!-- distro-table/{on=1; next} on && /^\|/{print; seen=1; next} on && seen{exit}' README.md | grep -E '^\| .*docs/install/')
(( rows >= 4 )) || bad "found ${rows} table rows (expected the four distro rows)"
echo "  ${rows} rows checked"

echo "## table rows: each one line, starting and ending with |"
for doc in README.md docs/install/*.md; do
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        line=${line%"${line##*[![:space:]]}"}          # trailing blanks
        if [[ ${line} == '|'* && ${line} != *'|' ]]; then
            bad "${doc}:${lineno}: table row does not end with | (split across lines?)"
        elif [[ ${line} != '|'* && ${line} == *'|' && ${prev:-} == '|'* ]]; then
            bad "${doc}:${lineno}: line ends with | but does not start with one (a row split across lines)"
        fi
        prev=${line}
    done < <(awk '/^```/{f=!f; print ""; next} f{print ""; next} {print}' "${doc}")
done

echo "## only the supported distros"
others=$(grep -n -i -w -E 'ubuntu|debian|mint|nobara|manjaro|opensuse|nixos|gentoo|artix|void linux|ultramarine' README.md docs/install/*.md |
    grep -v -E 'Debian sid|Debian-based|other Debian' || true)
[[ -z ${others} ]] || bad "unsupported distros named in the docs:"$'\n'"${others}"

(( fails == 0 )) && echo "docs-check: all passed" || echo "docs-check: FAILED"
exit "${fails}"
