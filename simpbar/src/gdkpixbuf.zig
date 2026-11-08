//! gdk-pixbuf, declared by hand in Zig (it replaces the old C shim).
//!
//! @cImport of gdk-pixbuf.h fails: GLib's headers expand to _Pragma(...)
//! runs that translate-c can't parse. The bar's GTK code solved the same
//! problem with plain extern declarations against the library's ABI
//! (welcome_gtk.zig); this does the same for the seven calls the icon and
//! cover-art decoders need, so no C file is compiled any more.
//!
//! The names match the old shim (simpbar_pixbuf_*) so callers only change
//! their import. A Pixbuf is the GdkPixbuf object itself, no wrapper
//! allocation in between.

pub const SimpbarPixbuf = opaque {};

extern "c" fn gdk_pixbuf_new_from_file_at_size(filename: [*:0]const u8, width: c_int, height: c_int, err: ?*?*anyopaque) ?*SimpbarPixbuf;
extern "c" fn gdk_pixbuf_get_width(pb: *const SimpbarPixbuf) c_int;
extern "c" fn gdk_pixbuf_get_height(pb: *const SimpbarPixbuf) c_int;
extern "c" fn gdk_pixbuf_get_rowstride(pb: *const SimpbarPixbuf) c_int;
extern "c" fn gdk_pixbuf_get_n_channels(pb: *const SimpbarPixbuf) c_int;
extern "c" fn gdk_pixbuf_get_has_alpha(pb: *const SimpbarPixbuf) c_int;
extern "c" fn gdk_pixbuf_get_pixels(pb: *const SimpbarPixbuf) [*]const u8;
extern "c" fn g_object_unref(obj: *anyopaque) void;
extern "c" fn g_error_free(err: *anyopaque) void;

/// Decodes `path` scaled to fit target_size x target_size (aspect kept).
/// null on a bad path, an unsupported format or a decode error.
pub fn simpbar_pixbuf_load(path: [*:0]const u8, target_size: c_int) ?*SimpbarPixbuf {
    var err: ?*anyopaque = null;
    const pb = gdk_pixbuf_new_from_file_at_size(path, target_size, target_size, &err);
    if (err) |e| g_error_free(e); // the reason isn't needed, only freed
    return pb;
}

pub fn simpbar_pixbuf_free(pb: *SimpbarPixbuf) void {
    g_object_unref(pb);
}

pub fn simpbar_pixbuf_width(pb: *const SimpbarPixbuf) c_int {
    return gdk_pixbuf_get_width(pb);
}
pub fn simpbar_pixbuf_height(pb: *const SimpbarPixbuf) c_int {
    return gdk_pixbuf_get_height(pb);
}
pub fn simpbar_pixbuf_rowstride(pb: *const SimpbarPixbuf) c_int {
    return gdk_pixbuf_get_rowstride(pb);
}
pub fn simpbar_pixbuf_channels(pb: *const SimpbarPixbuf) c_int {
    return gdk_pixbuf_get_n_channels(pb);
}
pub fn simpbar_pixbuf_has_alpha(pb: *const SimpbarPixbuf) c_int {
    return gdk_pixbuf_get_has_alpha(pb);
}
pub fn simpbar_pixbuf_pixels(pb: *const SimpbarPixbuf) [*]const u8 {
    return gdk_pixbuf_get_pixels(pb);
}
