pragma Singleton

import Quickshell
import Quickshell.Io

// Icon name -> absolute file path.
//
// Qt's Image does NOT resolve freedesktop icon theme names: `source: "firefox"`
// fails with Image.Error even though the file is installed, and this Qt build
// has no theme-aware Image type (IconImage exists in
// libQt6QuickControls2Impl but exposes no fromTheme, and Quickshell's
// IconImage is only a thin Image wrapper). So we resolve names ourselves with
// a single one-shot `find` over the app-icon directories, then pick the best
// candidate per name. One subprocess per scan (~4k lines), no cache file to go
// stale: once at startup, then again whenever the drawer opens so icons
// installed alongside new apps resolve on their first appearance.
//
// The icon theme picked in Perihelion Settings (gtk-icon-theme-name in
// ~/.config/gtk-3.0/settings.ini) wins, then the themes it inherits from,
// then hicolor and the plain/Flatpak locations, and only then any other
// installed theme (for a name nothing above has). Each scan builds a fresh
// map, so a theme change takes effect the next time the drawer opens.
Singleton {
    id: root

    // Roots are walked at runtime (see AppModel's rescan note). HOME paths are
    // built with Quickshell.env("HOME") because plain QML strings do NOT
    // interpolate `${...}`: the ${HOME} roots used to sit here as literal
    // strings, `find` skipped the nonexistent paths, and every icon that only
    // exists in a user directory -- Lutris game art, user flatpak exports --
    // silently resolved to nothing and drew a text glyph instead.
    readonly property var roots: [
        "/usr/share/icons",
        "/usr/share/pixmaps",
        (Quickshell.env("HOME") || "") + "/.local/share/icons",
        (Quickshell.env("HOME") || "") + "/.icons",
        // Flatpaks do NOT install into /usr/share/icons. Their desktop entries
        // declare icon names like `io.github.shiftey.Desktop` that only exist
        // in flatpak's own appstream store, under a per-app hash directory.
        "/var/lib/flatpak/appstream",
        "/var/lib/flatpak/exports/share/icons",
        (Quickshell.env("HOME") || "") + "/.local/share/flatpak/exports/share/icons"
    ]

    property var best: ({})     // basename -> { path: ..., rank: ... }

    readonly property string scanScript: [
        'cfg="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/settings.ini"',
        'theme=$(sed -n "s/^[[:space:]]*gtk-icon-theme-name[[:space:]]*=[[:space:]]*//p" "$cfg" 2>/dev/null | head -n 1 | tr -d "\\r")',
        'queue=$theme; seen=,; n=0',
        'while [ -n "$queue" ] && [ "$n" -lt 8 ]; do',
        '  t=${queue%%,*}',
        '  if [ "$t" = "$queue" ]; then queue=; else queue=${queue#*,}; fi',
        '  t=$(printf %s "$t" | tr -d " \\t")',
        '  case "$t" in ""|hicolor|*/*) continue ;; esac',
        '  case "$seen" in *",$t,"*) continue ;; esac',
        '  seen="$seen$t,"; n=$((n + 1)); echo "@@theme $t"',
        '  for r in "$@"; do',
        '    if [ -f "$r/$t/index.theme" ]; then',
        '      inh=$(sed -n "/^\\[Icon Theme\\]/,/^\\[/s/^Inherits[[:space:]]*=[[:space:]]*//p" "$r/$t/index.theme" | head -n 1 | tr -d "\\r")',
        '      [ -n "$inh" ] && queue="${queue:+$queue,}$inh"',
        '      break',
        '    fi',
        '  done',
        'done',
        "find \"$@\" -type f \\( -iname '*.png' -o -iname '*.svg' -o -iname '*.xpm' \\) 2>/dev/null",
        'exit 0'
    ].join("\n")

    // The picked theme and the ones it inherits, best first (from the scan).
    property var themeChain: []

    // Icon roots whose next path segment is a theme name.
    readonly property var themeRoots: [
        "/usr/share/icons",
        (Quickshell.env("HOME") || "") + "/.local/share/icons",
        (Quickshell.env("HOME") || "") + "/.icons",
        "/var/lib/flatpak/exports/share/icons",
        (Quickshell.env("HOME") || "") + "/.local/share/flatpak/exports/share/icons"
    ]

    // The theme a path belongs to ("" when it is not under a theme root).
    function themeOf(path) {
        for (var i = 0; i < themeRoots.length; i++) {
            var r = themeRoots[i] + "/";
            if (path.indexOf(r) === 0) {
                var rest = path.substring(r.length);
                var slash = rest.indexOf("/");
                return slash > 0 ? rest.substring(0, slash) : "";
            }
        }
        return "";
    }
    property bool ready: false

    // Mirrors the scan process so a consumer can tell a finished walk from one
    // that is still running: a snapshot taken mid-scan would bake in empty
    // icon strings for apps whose art only exists in the fresh pass.
    property bool scanning: true

    // A lookup made now is guaranteed to see every icon on disk: the last
    // scan finished and no rescan is in flight.
    readonly property bool settled: ready && !scanning

    // Re-run the directory walk so icons installed after startup resolve too
    // (drawn from the same story as AppModel.refresh()). The collector merges
    // into the existing map -- offer() keeps the higher-ranked candidate -- so
    // stale entries linger harmlessly and new files simply show up.
    function rescan() {
        if (scan.running)
            return;
        scanning = true;
        scan.running = true;
    }

    // Rank candidates: the picked theme (and what it inherits) first, then
    // the closest-to-native-size icon. Higher is better.
    function rankOf(path, chain) {
        var theme = themeOf(path);
        if (theme !== "" && theme !== "hicolor") {
            var at = chain.indexOf(theme);
            if (at >= 0)
                return (chain.length - at) * 100000 + sizeRank(path);
            // Another installed theme: only for a name nothing else has.
            return sizeRank(path) - 50000;
        }
        return sizeRank(path);
    }

    // Size and format preference within one tier.
    function sizeRank(path) {
        var ext = path.substring(path.lastIndexOf(".") + 1).toLowerCase();

        // Flatpak appstream art is generic 64/128px raster art kept in a cache
        // store, not a themed icon. Rank it below every real theme tier (whose
        // lowest is ~201 for a 1px icon) so a genuine themed icon always wins
        // and this only ever fills a genuine gap. Within appstream, prefer the
        // 128px copy over the 64px one; the cap keeps the best possible
        // appstream rank (170) below that ~201 floor.
        if (path.indexOf("/appstream/") !== -1) {
            var sm = path.match(/\/icons\/(\d+)x\d+\//);
            return 150 + (sm ? Math.min(20, parseInt(sm[1], 10) / 8) : 0);
        }

        var score = 0;

        // Scalable art stays crisp at any tile size.
        if (ext === "svg")
            score += 1000;

        // pixmaps have no size directory; trust them but rank below a real
        // theme hit at a sensible resolution.
        if (path.indexOf("/pixmaps/") !== -1)
            return 700 + score;

        var m = path.match(/\/(\d+)x(\d+)(?:@\d+x\d+)?\//);
        if (m) {
            var w = parseInt(m[1], 10);
            // Sweet spot is 96-192px: crisp for a ~44px tile, not wasteful.
            if (w >= 96 && w <= 192)
                score += 400;
            else if (w < 96)
                score += 200 + w;          // prefer bigger among the small
            else
                score += 400 - Math.min(300, (w - 192) / 4);
        } else {
            score += 300;
        }

        // One-color symbolic art is for status icons; an app tile wants
        // the full-color one.
        if (path.indexOf("/symbolic/") !== -1)
            score -= 900;

        return score;
    }

    function offer(map, chain, path) {
        var dot = path.lastIndexOf(".");
        if (dot <= 0)
            return;
        var name = path.substring(path.lastIndexOf("/") + 1, dot);
        if (name.length === 0)
            return;
        var rank = rankOf(path, chain);
        var cur = map[name];
        if (cur === undefined || rank > cur.rank) {
            map[name] = { "path": path, "rank": rank };
        }
    }

    // Public lookup. Returns "" when nothing matches so callers can fall back to
    // a text glyph rather than showing a broken image.
    function path(name) {
        if (!name)
            return "";
        if (name.indexOf("/") === 0)      // already an absolute path
            return name;
        var hit = best[name];
        return hit ? hit.path : "";
    }

    Process {
        id: scan
        // The argument list is built from `roots` rather than hardcoding
        // roots[0..3]: a hardcoded index list silently skips any root added
        // later, which is exactly the bug that left every Flatpak icon missing.
        //
        // `sh -c 'find "$@"' sh <roots...>` so that roots which do not exist on
        // this machine are skipped instead of making `find` exit non-zero, and
        // the trailing `exit 0` keeps a missing optional root from looking like
        // a scan failure.
        //
        // Before the walk, the script prints the picked theme and the themes
        // it inherits (breadth first, hicolor left out) as "@@theme NAME"
        // lines, read from settings.ini and each theme's index.theme.
        command: ["sh", "-c", root.scanScript, "appdrawer-icons"].concat(root.roots)
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = String(this.text).split("\n");
                var chain = [];
                var map = {};
                for (var i = 0; i < lines.length; i++) {
                    var l = lines[i].trim();
                    if (l.indexOf("@@theme ") === 0)
                        chain.push(l.substring(8));
                    else if (l.length > 0)
                        root.offer(map, chain, l);
                }
                // A fresh map each scan: winners from the previous theme
                // must not linger.
                root.themeChain = chain;
                root.best = map;
                root.ready = true;
                root.scanning = false;
                console.log("ICONS ready entries=" + Object.keys(root.best).length + " theme=" + chain.join(">"));
            }
        }
    }
}