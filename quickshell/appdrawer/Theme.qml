pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Theme tokens.
//
// Colours come from matugen's generated file -- the same source simpbar's bar
// already follows -- so the drawer and the bar repaint together when the
// wallpaper changes. JsonAdapter maps each declared property to a JSON key of
// the same name, so these are live bindings rather than a parsed blob.
//
// Defaults are the values matugen currently generates, so a missing or
// malformed file degrades to the correct palette instead of an unstyled or
// invisible window.
Singleton {
    id: root

    FileView {
        id: view
        // Quickshell.env("HOME") rather than a literal path: the installer
        // drops this config into every user's ~/.config/quickshell, so a
        // hardcoded home directory would point at the wrong user's matugen
        // output (or nothing at all) on every install but the developer's.
        path: Quickshell.env("HOME") + "/.config/simpbar/matugen.json"
        // matugen rewrites this file on wallpaper change.
        watchChanges: true
        blockLoading: true
        onFileChanged: reload()

        JsonAdapter {
            property string bg_color: "#0a0f14"
            property string text_color: "#dee3eb"
            property string border_color: "#c5cd71"
            property string hover_color: "#454b00"
            property string popup_bg_color: "#1b2026"
            property string popup_hover_color: "#454b00"
            property string popup_separator_color: "#3f4852"
            property string popup_disabled_color: "#bec7d5"
        }
    }

    // Pull the adapter's values out into plain properties so the rest of the
    // config binds to one stable name per colour.
    readonly property color window: view.adapter.bg_color
    readonly property color text: view.adapter.text_color
    readonly property color accent: view.adapter.border_color
    readonly property color bg: view.adapter.popup_bg_color
    readonly property color hover: view.adapter.popup_hover_color
    readonly property color separator: view.adapter.popup_separator_color
    readonly property color dim: view.adapter.popup_disabled_color

    readonly property bool themeLoaded: view.loaded

    // ---- glass ---------------------------------------------------------
    // The panel is the popup colour at a little under full opacity, so the
    // desktop shows faintly through it (and the compositor's blur, where a
    // layer rule turns it on for the "appdrawer" namespace). Edges are a
    // hairline of the accent and a lighter top highlight, the way GNOME's
    // shell and libadwaita cards read as raised glass without a shadow pass.
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    readonly property color glass: alpha(bg, 0.88)
    readonly property color glassEdge: alpha(accent, 0.22)
    readonly property color glassHighlight: Qt.rgba(1, 1, 1, 0.07)
    readonly property color hoverSoft: alpha(hover, 0.60)
    readonly property color selectedSoft: alpha(accent, 0.18)

    // ---- motion ----------------------------------------------------------
    // One motion language for the whole drawer. Curves are cubic beziers in
    // Qt's BezierSpline form [c1x, c1y, c2x, c2y, 1, 1]:
    //   out   GNOME's ease-out-quint: fast start, long soft landing (enter,
    //         scroll, highlight moves)
    //   in    accelerate away (leave)
    readonly property var curveOut: [0.22, 1.0, 0.36, 1.0, 1.0, 1.0]
    readonly property var curveIn: [0.55, 0.0, 0.85, 0.35, 1.0, 1.0]
    readonly property int durEnter: 300
    readonly property int durLeave: 190
    readonly property int durScroll: 280
    readonly property int durMove: 200
    readonly property int durHover: 120
    readonly property int durPress: 90

    // Metrics. barHeight must match simpbar's appearance.bar_height so the panel
    // sits flush above the bar instead of overlapping or leaving a gap.
    readonly property int barHeight: 25
    readonly property int radius: 22
    readonly property int tileRadius: 16
    readonly property int iconSize: 44
    readonly property int tileWidth: 100
    readonly property int tileHeight: 88
}