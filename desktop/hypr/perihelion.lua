-- Perihelion Bar for Hyprland (0.56 and newer read Lua configs).
--
-- The installer adds one line to your ~/.config/hypr/hyprland.lua:
--     require("perihelion")
-- and leaves the rest of that file alone. Delete that line to switch all of
-- this off again. Edit this file freely: the installer asks before it ever
-- replaces it (keep yours, take the new one, or write the new one beside it).
--
-- Same keys and programs as Perihelion Linux's Mango config, so muscle
-- memory carries over. Super+H lists every bind.

local terminal = "kitty"
local browser = "firefox"
local files = "strata"

-- Each bind first drops whatever your own config put on the same keys, so a
-- key never runs two things at once (Hyprland would otherwise run both).
local function bind(keys, dispatcher, description, opts)
    pcall(hl.unbind, keys)
    opts = opts or {}
    opts.description = description
    hl.bind(keys, dispatcher, opts)
end

local function run(cmd)
    return hl.dsp.exec_cmd(cmd)
end

---------------------------------------------------------------------------
-- Started with the session
---------------------------------------------------------------------------
hl.on("hyprland.start", function()
    -- Portals (Open/Save dialogs, screen sharing) need the session's display.
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE")
    hl.exec_cmd("perihelion-wallpaper")
    -- The bar on top; the dock too, when it is switched on in Settings.
    hl.exec_cmd("perihelion-bar-start")
    -- Desktop cards, Glance and the window overview.
    hl.exec_cmd("perihelion-shell")
    -- The app drawer's daemon, so Super+A opens instantly.
    hl.exec_cmd("appdrawer start")
    hl.exec_cmd("/usr/lib/mate-polkit/polkit-mate-authentication-agent-1")
    hl.exec_cmd("perihelion-nightlight")
    -- Lock after 10 idle minutes and before suspend.
    hl.exec_cmd("swayidle -w timeout 600 perihelion-lock before-sleep perihelion-lock")
end)

hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")

---------------------------------------------------------------------------
-- Windows the shell opens
---------------------------------------------------------------------------
hl.window_rule({ match = { class = "^perihelion-float$" }, float = true, size = "50% 55%" })
hl.window_rule({ match = { class = "^io\\.github\\.perihelion\\.Wallpapers$" }, float = true, size = "75% 72%" })

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------
bind("SUPER + Return", run(terminal), "Terminal")
bind("SUPER + SHIFT + Return", run(terminal .. " --class perihelion-float"), "Floating terminal")
bind("SUPER + D", run("perihelion-launcher"), "App launcher")
bind("SUPER + A", run("appdrawer"), "App drawer")
bind("SUPER + I", run("perihelion-shell glance toggle"), "Glance")
bind("ALT + W", run("perihelion-shell overview toggle"), "Window overview")
bind("SUPER + SHIFT + W", run("perihelion-wallpaper-picker"), "Wallpapers")
bind("SUPER + E", run(files), "Files")
bind("SUPER + B", run(browser), "Browser")
bind("SUPER + H", run("perihelion-keys"), "List every key")
bind("SUPER + L", run("perihelion-lock"), "Lock the screen")
bind("SUPER + SHIFT + Q", run("perihelion-power-menu"), "Power menu")
bind("SUPER + SHIFT + D", run("perihelion-bar-start"), "Restart the bar and dock")
bind("SUPER + SHIFT + R", hl.dsp.reload_config(), "Reload this config")
bind("SUPER + SHIFT + E", hl.dsp.exit(), "Log out")

bind("SUPER + Q", hl.dsp.window.close(), "Close window")
bind("SUPER + W", hl.dsp.window.float({ action = "toggle" }), "Float / tile")
bind("SUPER + F", hl.dsp.window.fullscreen(), "Fullscreen")
bind("ALT + Tab", hl.dsp.window.cycle_next(), "Next window")

for _, dir in ipairs({ "left", "right", "up", "down" }) do
    local key = dir:sub(1, 1):upper() .. dir:sub(2)
    bind("SUPER + " .. key, hl.dsp.focus({ direction = dir }), "Focus " .. dir)
    bind("SUPER + SHIFT + CTRL + " .. key, hl.dsp.window.move({ direction = dir }), "Move window " .. dir)
end
bind("SUPER + SHIFT + Right", hl.dsp.window.resize({ x = 30, y = 0, relative = true }), "Wider", { repeating = true })
bind("SUPER + SHIFT + Left", hl.dsp.window.resize({ x = -30, y = 0, relative = true }), "Narrower", { repeating = true })
bind("SUPER + SHIFT + Up", hl.dsp.window.resize({ x = 0, y = -30, relative = true }), "Shorter", { repeating = true })
bind("SUPER + SHIFT + Down", hl.dsp.window.resize({ x = 0, y = 30, relative = true }), "Taller", { repeating = true })

bind("SUPER + SHIFT + S", run("perihelion-screenshot region"), "Screenshot: region")
bind("SUPER + Print", run("perihelion-screenshot region"), "Screenshot: region")
bind("Print", run("perihelion-screenshot full"), "Screenshot: screen")

for i = 1, 9 do
    bind("SUPER + " .. i, hl.dsp.focus({ workspace = i }), "Workspace " .. i)
    bind("SUPER + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }), "Move to workspace " .. i)
end
bind("SUPER + CTRL + Right", hl.dsp.focus({ workspace = "r+1" }), "Next workspace")
bind("SUPER + CTRL + Left", hl.dsp.focus({ workspace = "r-1" }), "Previous workspace")
bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "e+1" }), "Next workspace")
bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "e-1" }), "Previous workspace")
bind("SUPER + mouse:272", hl.dsp.window.drag(), "Move window", { mouse = true })
bind("SUPER + mouse:273", hl.dsp.window.resize(), "Resize window", { mouse = true })

local media = { locked = true }
bind("XF86AudioPlay", run("playerctl play-pause"), "Play / pause", media)
bind("XF86AudioNext", run("playerctl next"), "Next track", media)
bind("XF86AudioPrev", run("playerctl previous"), "Previous track", media)
bind("XF86AudioRaiseVolume", run("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+"), "Volume up", { locked = true, repeating = true })
bind("XF86AudioLowerVolume", run("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), "Volume down", { locked = true, repeating = true })
bind("XF86AudioMute", run("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), "Mute", media)
bind("XF86MonBrightnessUp", run("brightnessctl set +5%"), "Brighter", { locked = true, repeating = true })
bind("XF86MonBrightnessDown", run("brightnessctl set 5%-"), "Dimmer", { locked = true, repeating = true })
