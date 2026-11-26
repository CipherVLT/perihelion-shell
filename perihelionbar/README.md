# Protocol XML

`protocols/wlr-layer-shell-unstable-v1.xml` (a wlroots protocol, not part of
`wayland-protocols`) is kept in this repository, so the build needs no download;
`build.zig` points `scanner.addCustomProtocol` at it.

To refresh it from wlroots' protocol repository:

```sh
curl -o protocols/wlr-layer-shell-unstable-v1.xml \
  https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/raw/master/unstable/wlr-layer-shell-unstable-v1/wlr-layer-shell-unstable-v1.xml
```
