# shellcheck shell=bash
# What starts with the session, and how Settings > Updates knows this copy.
# Sourced by install.sh.

# Lines each window manager's config needs for the full desktop.
MANGO_NEEDS=(
    'exec_once=perihelion-bar-start'
    'exec_once=perihelion-shell'
    'exec_once=appdrawer start'
    'exec_once=swayidle -w timeout 600 perihelion-lock before-sleep perihelion-lock'
    'exec_once=dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE'
    'bind=SUPER,i,spawn,perihelion-shell glance toggle'
    'bind=SUPER,l,spawn,perihelion-lock'
)

# The update check Settings > Updates expects: a user timer that fires every
# hour and runs `perihelion-settings --check-updates --if-due`, which checks
# only when "Check automatically" is on and its interval has passed.
write_unit() { # NAME CONTENT
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" tmp
    mkdir -p "${dir}"
    tmp=$(mktemp)
    printf '%s\n' "$2" > "${tmp}"
    if cmp -s "${tmp}" "${dir}/$1"; then rm -f "${tmp}"; return 1; fi
    mv -f "${tmp}" "${dir}/$1"
    chmod 644 "${dir}/$1"
}

install_update_timer() {
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" changed=0
    write_unit perihelion-update-check.service '[Unit]
Description=Check for a new Perihelion Shell release

[Service]
Type=oneshot
ExecStart=/usr/bin/perihelion-settings --check-updates --if-due' && changed=1
    write_unit perihelion-update-check.timer '[Unit]
Description=Check for a new Perihelion Shell release (Settings > Updates decides how often)

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target' && changed=1
    # Enabled the way `systemctl --user enable` does it, so it works even
    # without a running user session (first install over SSH, containers).
    mkdir -p "${dir}/timers.target.wants"
    if [[ ! -L ${dir}/timers.target.wants/perihelion-update-check.timer ]]; then
        ln -sfn ../perihelion-update-check.timer "${dir}/timers.target.wants/perihelion-update-check.timer"
        changed=1
    fi
    if (( changed )) && systemctl --user daemon-reload >/dev/null 2>&1; then
        systemctl --user start perihelion-update-check.timer >/dev/null 2>&1 || true
    fi
    if (( changed )); then ok "Update check: perihelion-update-check.timer"; else ok "Update check already set up"; fi
}

# Settings > Updates reads "install.sh <commit>" from here.
write_install_marker() {
    local marker="${STATE_DIR}/install-method" want="install.sh ${COMMIT}"
    if [[ -f ${marker} && $(< "${marker}") == "${want}" ]]; then
        return 0
    fi
    printf '%s\n' "${want}" > "${marker}"
    ok "Settings > Updates: installed with install.sh at ${COMMIT}"
}

check_mango_autostart() {
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/mango" line missing=()
    [[ -d ${dir} ]] || return 0
    for line in "${MANGO_NEEDS[@]}"; do
        grep -rqsxF "${line}" "${dir}" --include='*.conf' || missing+=("${line}")
    done
    if (( ${#missing[@]} )); then
        warn "Your Mango config lacks lines Perihelion Bar needs; add them to ~/.config/mango/cfg/ (autostart.conf / keybinds.conf):"
        printf '      %s\n' "${missing[@]}"
        log "missing mango lines: ${missing[*]}"
    else
        ok "MangoWM starts the bar, dock, shell, drawer and idle lock"
    fi
}

check_hyprland_autostart() {
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
    if grep -qE 'require[[:space:]]*\(?[[:space:]]*["'"'"']perihelion["'"'"']' "${dir}/hyprland.lua" 2>/dev/null &&
        grep -q 'perihelion-bar-start' "${dir}/perihelion.lua" 2>/dev/null; then
        ok "Hyprland starts the bar, dock, shell, drawer and idle lock"
    else
        warn "Hyprland does not load ~/.config/hypr/perihelion.lua yet (require(\"perihelion\") in hyprland.lua)"
    fi
}

install_autostart() {
    (( WANT_MANGO )) && check_mango_autostart
    (( WANT_HYPR )) && check_hyprland_autostart
    install_update_timer
    write_install_marker
}
