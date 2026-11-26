#!/usr/bin/env bash
# The installer's title and step lines on different terminals: emoji and
# Unicode only where they can be drawn (never on the Linux console), colour
# only on a terminal (never with NO_COLOR or into a pipe).
# shellcheck disable=SC2329,SC2016,SC2001  # helpers run through check(); the bash -c text expands in the child; sed strips colour codes
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fails=0
check() { if "$@"; then echo "  ok    $*"; else echo "  FAIL  $*"; fails=1; fi; }

# show ENV...: the banner and one step line, as that terminal gets them.
# A throwaway HOME, so nothing is logged anywhere real; the script name is
# "banner-test", so sourcing install.sh never runs its main.
home=$(mktemp -d)
trap 'rm -rf "${home}"' EXIT
show() {
    env -i PATH=/usr/bin:/bin HOME="${home}" "$@" bash -c '
        source "$1"
        banner 0.1.0-test abc1234
        STEP_TOTAL=5; step Packages "📦"; ok done; warn careful
    ' banner-test "${repo}/install.sh"
}
# Checks on the last output ($out); text checks ignore colour codes.
plain() { sed 's/\x1b\[[0-9;]*m//g' <<<"${out}"; }
has() { plain | grep -q -- "$1"; }
lacks() { ! plain | grep -q -- "$1"; }
has_esc() { grep -q $'\e\\[' <<<"${out}"; }
no_esc() { ! has_esc; }
# Any 4-byte UTF-8 sequence: where emoji live.
no_emoji() { ! LC_ALL=C grep -qP '[\xF0-\xF4][\x80-\xBF]{3}' <<<"${out}"; }

echo "## Linux console (TERM=linux, UTF-8 locale, a terminal)"
out=$(show PERIHELION_TTY=1 TERM=linux LANG=C.UTF-8 COLUMNS=100)
check lacks '🚀'
check no_emoji
check lacks '█'
check lacks '✓'
check has '####   #####  ####'
check has '>> Perihelion Bar installer'
check has '\[1/5\] Packages'
check has '  + done'

echo "## a modern terminal (xterm-256color, UTF-8)"
out=$(show PERIHELION_TTY=1 TERM=xterm-256color LANG=en_US.UTF-8 COLUMNS=100)
check has '🚀 '
check has '▄███▄'
check has '\[1/5\].*📦 .*Packages'
check has '✓'
check has_esc
shaded() { grep -q $'\e\\[1;38;5;220m' <<<"${out}"; }
check shaded

echo "## not a terminal (piped into a file)"
out=$(show TERM=xterm-256color LANG=en_US.UTF-8 COLUMNS=100)
check no_esc
check no_emoji
check has 'Perihelion Bar installer'

echo "## NO_COLOR and TERM=dumb"
out=$(show PERIHELION_TTY=1 NO_COLOR=1 TERM=xterm-256color LANG=en_US.UTF-8 COLUMNS=100)
check no_esc
out=$(show PERIHELION_TTY=1 TERM=dumb LANG=en_US.UTF-8 COLUMNS=100)
check no_esc
check no_emoji

echo "## no UTF-8 locale"
out=$(show PERIHELION_TTY=1 TERM=xterm-256color LANG=C COLUMNS=100)
check no_emoji
check has '#####'

echo "## a narrow terminal: one plain title line"
out=$(show PERIHELION_TTY=1 TERM=xterm-256color LANG=en_US.UTF-8 COLUMNS=50)
check has 'P E R I H E L I O N'
check lacks '█████'

echo "## every title row is the same width (64)"
rows_ok() {
    local w
    w=$(HOME=${home} bash -c 'source "$1" >/dev/null 2>&1; for r in "${TITLE_ROWS[@]}"; do printf "%s\n" "${#r}"; done | sort -u' banner-test "${repo}/install.sh")
    [[ ${w} == 64 ]]
}
check rows_ok

(( fails == 0 )) && echo "banner-test: all passed" || echo "banner-test: FAILED"
exit "${fails}"
