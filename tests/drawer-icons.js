// Runs the app drawer's icon scan (quickshell/appdrawer/Icons.qml) outside
// Quickshell: the same shell script and the same ranking functions, taken
// from the QML file itself, so this tests what ships.
//
//   node tests/drawer-icons.js HOME NAME...    print the icon picked for each NAME
//
// HOME is the home folder whose gtk-3.0/settings.ini names the theme and whose
// .icons / .local/share/icons are searched (with /usr/share/icons).
"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const qml = fs.readFileSync(path.join(__dirname, "../quickshell/appdrawer/Icons.qml"), "utf8");

const scanSrc = qml.match(/scanScript:\s*(\[[\s\S]*?\])\.join\("\\n"\)/);
if (!scanSrc) throw new Error("scanScript not found in Icons.qml");
const script = eval(scanSrc[1]).join("\n");

function grabFn(name) {
    const start = qml.indexOf("function " + name + "(");
    if (start < 0) throw new Error("function " + name + " not found");
    let depth = 0, i = qml.indexOf("{", start);
    for (; i < qml.length; i++) {
        if (qml[i] === "{") depth++;
        else if (qml[i] === "}" && --depth === 0) break;
    }
    return qml.substring(start, i + 1);
}

const home = process.argv[2];
const names = process.argv.slice(3);
const root = {
    themeRoots: ["/usr/share/icons", home + "/.local/share/icons", home + "/.icons"],
};
const fns = ["themeOf", "rankOf", "sizeRank", "offer"].map(grabFn).join("\n");
const bound = new Function("root", fns + "\nreturn {themeOf, rankOf, sizeRank, offer};")(root);
Object.assign(root, bound);
// The QML functions call each other bare (themeOf(...)) inside the item.
globalThis.themeOf = bound.themeOf;
globalThis.sizeRank = bound.sizeRank;
globalThis.rankOf = bound.rankOf;
globalThis.themeRoots = root.themeRoots;

const out = execFileSync("sh", ["-c", script, "appdrawer-icons",
    "/usr/share/icons", home + "/.local/share/icons", home + "/.icons"],
    { env: { ...process.env, HOME: home, XDG_CONFIG_HOME: home + "/.config" }, maxBuffer: 1 << 28 }).toString();

const chain = [];
const map = {};
for (const raw of out.split("\n")) {
    const l = raw.trim();
    if (l.startsWith("@@theme ")) chain.push(l.substring(8));
    else if (l.length > 0) bound.offer(map, chain, l);
}
console.log("chain " + chain.join(">"));
for (const n of names) console.log(n + " " + (map[n] ? map[n].path : "(none)"));
