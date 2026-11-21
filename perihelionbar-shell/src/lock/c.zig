//! The C libraries perihelion-lockscreen draws, decodes, types and
//! authenticates with, declared by hand (Zig 0.17 has no @cImport; the bar
//! does the same in freetype.zig and gdkpixbuf.zig). Only the calls the lock
//! screen makes. Constants and struct layouts follow the public headers for
//! LP64 Linux: cairo/cairo.h, pango/pango-*.h, security/_pam_types.h,
//! gdk-pixbuf/gdk-pixbuf-*.h and xkbcommon/xkbcommon.h.
//!
//! These libraries are linked into perihelion-lockscreen only.

// --- cairo -----------------------------------------------------------------

pub const cairo = struct {
    pub const Surface = opaque {};
    pub const Context = opaque {};
    pub const Pattern = opaque {};

    pub const FORMAT_ARGB32: c_int = 0;
    pub const STATUS_SUCCESS: c_int = 0;
    pub const SURFACE_TYPE_IMAGE: c_int = 0;
    pub const FILTER_BILINEAR: c_int = 4;
    pub const LINE_CAP_ROUND: c_int = 1;
    pub const LINE_JOIN_ROUND: c_int = 1;

    pub extern "c" fn cairo_image_surface_create(format: c_int, w: c_int, h: c_int) ?*Surface;
    pub extern "c" fn cairo_image_surface_create_for_data(data: [*]u8, format: c_int, w: c_int, h: c_int, stride: c_int) ?*Surface;
    pub extern "c" fn cairo_image_surface_get_width(s: *Surface) c_int;
    pub extern "c" fn cairo_image_surface_get_height(s: *Surface) c_int;
    pub extern "c" fn cairo_image_surface_get_stride(s: *Surface) c_int;
    pub extern "c" fn cairo_image_surface_get_data(s: *Surface) ?[*]u8;
    pub extern "c" fn cairo_surface_get_type(s: *Surface) c_int;
    pub extern "c" fn cairo_surface_status(s: *Surface) c_int;
    pub extern "c" fn cairo_surface_flush(s: *Surface) void;
    pub extern "c" fn cairo_surface_mark_dirty(s: *Surface) void;
    pub extern "c" fn cairo_surface_destroy(s: *Surface) void;
    /// Only the preview tool (preview.zig) writes PNGs.
    pub extern "c" fn cairo_surface_write_to_png(s: *Surface, filename: [*:0]const u8) c_int;

    pub extern "c" fn cairo_create(target: *Surface) ?*Context;
    pub extern "c" fn cairo_destroy(cr: *Context) void;
    pub extern "c" fn cairo_status(cr: *Context) c_int;
    pub extern "c" fn cairo_get_target(cr: *Context) ?*Surface;
    pub extern "c" fn cairo_save(cr: *Context) void;
    pub extern "c" fn cairo_restore(cr: *Context) void;
    pub extern "c" fn cairo_translate(cr: *Context, tx: f64, ty: f64) void;
    pub extern "c" fn cairo_scale(cr: *Context, sx: f64, sy: f64) void;
    pub extern "c" fn cairo_set_source_rgba(cr: *Context, r: f64, g: f64, b: f64, a: f64) void;
    pub extern "c" fn cairo_set_source(cr: *Context, p: *Pattern) void;
    pub extern "c" fn cairo_set_source_surface(cr: *Context, s: *Surface, x: f64, y: f64) void;
    pub extern "c" fn cairo_get_source(cr: *Context) ?*Pattern;
    pub extern "c" fn cairo_paint(cr: *Context) void;
    pub extern "c" fn cairo_fill(cr: *Context) void;
    pub extern "c" fn cairo_stroke(cr: *Context) void;
    pub extern "c" fn cairo_clip(cr: *Context) void;
    pub extern "c" fn cairo_new_path(cr: *Context) void;
    pub extern "c" fn cairo_new_sub_path(cr: *Context) void;
    pub extern "c" fn cairo_close_path(cr: *Context) void;
    pub extern "c" fn cairo_move_to(cr: *Context, x: f64, y: f64) void;
    pub extern "c" fn cairo_line_to(cr: *Context, x: f64, y: f64) void;
    pub extern "c" fn cairo_arc(cr: *Context, xc: f64, yc: f64, r: f64, a1: f64, a2: f64) void;
    pub extern "c" fn cairo_set_line_width(cr: *Context, w: f64) void;
    pub extern "c" fn cairo_set_line_cap(cr: *Context, cap: c_int) void;
    pub extern "c" fn cairo_set_line_join(cr: *Context, join: c_int) void;

    pub extern "c" fn cairo_pattern_create_linear(x0: f64, y0: f64, x1: f64, y1: f64) ?*Pattern;
    pub extern "c" fn cairo_pattern_add_color_stop_rgba(p: *Pattern, offset: f64, r: f64, g: f64, b: f64, a: f64) void;
    pub extern "c" fn cairo_pattern_set_filter(p: *Pattern, filter: c_int) void;
    pub extern "c" fn cairo_pattern_destroy(p: *Pattern) void;
};

// --- pango / pangocairo ------------------------------------------------------

pub const pango = struct {
    pub const Layout = opaque {};
    pub const FontDescription = opaque {};
    pub const AttrList = opaque {};
    pub const Attribute = opaque {};

    pub const Rectangle = extern struct {
        x: c_int = 0,
        y: c_int = 0,
        width: c_int = 0,
        height: c_int = 0,
    };

    pub const SCALE: f64 = 1024.0;

    pub extern "c" fn pango_cairo_create_layout(cr: *cairo.Context) ?*Layout;
    pub extern "c" fn pango_cairo_show_layout(cr: *cairo.Context, layout: *Layout) void;
    pub extern "c" fn pango_cairo_layout_path(cr: *cairo.Context, layout: *Layout) void;
    pub extern "c" fn pango_layout_set_text(layout: *Layout, text: [*]const u8, len: c_int) void;
    pub extern "c" fn pango_layout_set_font_description(layout: *Layout, desc: *const FontDescription) void;
    pub extern "c" fn pango_layout_set_attributes(layout: *Layout, attrs: ?*AttrList) void;
    pub extern "c" fn pango_layout_get_pixel_size(layout: *Layout, w: *c_int, h: *c_int) void;
    pub extern "c" fn pango_layout_get_pixel_extents(layout: *Layout, ink: ?*Rectangle, logical: ?*Rectangle) void;
    pub extern "c" fn pango_layout_get_baseline(layout: *Layout) c_int;

    pub extern "c" fn pango_font_description_new() ?*FontDescription;
    pub extern "c" fn pango_font_description_free(desc: *FontDescription) void;
    pub extern "c" fn pango_font_description_set_family(desc: *FontDescription, family: [*:0]const u8) void;
    /// PangoWeight is a C enum (int): 400 normal, 500 medium, 600 semibold.
    pub extern "c" fn pango_font_description_set_weight(desc: *FontDescription, weight: c_int) void;
    pub extern "c" fn pango_font_description_set_absolute_size(desc: *FontDescription, size: f64) void;

    pub extern "c" fn pango_attr_list_new() ?*AttrList;
    pub extern "c" fn pango_attr_list_unref(list: *AttrList) void;
    pub extern "c" fn pango_attr_list_insert(list: *AttrList, attr: *Attribute) void;
    pub extern "c" fn pango_attr_letter_spacing_new(spacing: c_int) ?*Attribute;
    pub extern "c" fn pango_attr_font_features_new(features: [*:0]const u8) ?*Attribute;

    pub extern "c" fn g_object_unref(obj: *anyopaque) void;
};

// --- gdk-pixbuf ----------------------------------------------------------------

pub const pixbuf = struct {
    pub const Pixbuf = opaque {};
    pub const Format = opaque {};

    pub extern "c" fn gdk_pixbuf_get_file_info(filename: [*:0]const u8, w: ?*c_int, h: ?*c_int) ?*Format;
    pub extern "c" fn gdk_pixbuf_new_from_file_at_scale(filename: [*:0]const u8, w: c_int, h: c_int, preserve_aspect: c_int, err: ?*?*anyopaque) ?*Pixbuf;
    pub extern "c" fn gdk_pixbuf_apply_embedded_orientation(src: *Pixbuf) ?*Pixbuf;
    pub extern "c" fn gdk_pixbuf_get_width(pb: *const Pixbuf) c_int;
    pub extern "c" fn gdk_pixbuf_get_height(pb: *const Pixbuf) c_int;
    pub extern "c" fn gdk_pixbuf_get_rowstride(pb: *const Pixbuf) c_int;
    pub extern "c" fn gdk_pixbuf_get_n_channels(pb: *const Pixbuf) c_int;
    pub extern "c" fn gdk_pixbuf_get_has_alpha(pb: *const Pixbuf) c_int;
    pub extern "c" fn gdk_pixbuf_get_pixels(pb: *const Pixbuf) [*]const u8;
    pub extern "c" fn g_object_unref(obj: *anyopaque) void;
    pub extern "c" fn g_error_free(err: *anyopaque) void;
};

// --- xkbcommon -------------------------------------------------------------------

pub const xkb = struct {
    pub const Context = opaque {};
    pub const Keymap = opaque {};
    pub const State = opaque {};

    pub const KEYMAP_FORMAT_TEXT_V1: c_int = 1;
    pub const STATE_MODS_EFFECTIVE: c_int = 1 << 3;
    pub const MOD_INVALID: u32 = 0xffff_ffff;

    pub const KEY_Return: u32 = 0xff0d;
    pub const KEY_KP_Enter: u32 = 0xff8d;
    pub const KEY_BackSpace: u32 = 0xff08;
    pub const KEY_Escape: u32 = 0xff1b;

    pub extern "c" fn xkb_context_new(flags: c_int) ?*Context;
    pub extern "c" fn xkb_context_unref(ctx: *Context) void;
    pub extern "c" fn xkb_keymap_new_from_string(ctx: *Context, s: [*:0]const u8, format: c_int, flags: c_int) ?*Keymap;
    pub extern "c" fn xkb_keymap_unref(km: *Keymap) void;
    pub extern "c" fn xkb_keymap_mod_get_index(km: *Keymap, name: [*:0]const u8) u32;
    pub extern "c" fn xkb_state_new(km: *Keymap) ?*State;
    pub extern "c" fn xkb_state_unref(st: *State) void;
    pub extern "c" fn xkb_state_update_mask(st: *State, depressed: u32, latched: u32, locked: u32, d_layout: u32, l_layout: u32, lk_layout: u32) c_int;
    pub extern "c" fn xkb_state_key_get_one_sym(st: *State, key: u32) u32;
    pub extern "c" fn xkb_state_key_get_utf8(st: *State, key: u32, buf: [*]u8, size: usize) c_int;
    pub extern "c" fn xkb_state_mod_name_is_active(st: *State, name: [*:0]const u8, kind: c_int) c_int;
};

// --- PAM ---------------------------------------------------------------------------

pub const pam = struct {
    pub const Handle = opaque {};

    pub const SUCCESS: c_int = 0;
    pub const BUF_ERR: c_int = 5;
    pub const CONV_ERR: c_int = 19;
    pub const PROMPT_ECHO_OFF: c_int = 1;
    pub const PROMPT_ECHO_ON: c_int = 2;
    pub const MAX_NUM_MSG: c_int = 32;

    pub const Message = extern struct {
        msg_style: c_int,
        msg: ?[*:0]const u8,
    };

    pub const Response = extern struct {
        resp: ?[*]u8,
        resp_retcode: c_int,
    };

    pub const ConvFn = *const fn (num_msg: c_int, msg: ?[*]?*const Message, resp: ?*?[*]Response, appdata: ?*anyopaque) callconv(.c) c_int;

    pub const Conv = extern struct {
        conv: ConvFn,
        appdata_ptr: ?*anyopaque,
    };

    pub extern "c" fn pam_start(service: [*:0]const u8, user: [*:0]const u8, conv: *const Conv, handle: *?*Handle) c_int;
    pub extern "c" fn pam_authenticate(handle: *Handle, flags: c_int) c_int;
    pub extern "c" fn pam_end(handle: *Handle, status: c_int) c_int;
};

// --- libc bits std.c does not cover the way we need ------------------------------

pub extern "c" fn calloc(n: usize, size: usize) ?*anyopaque;
pub extern "c" fn malloc(size: usize) ?*anyopaque;
pub extern "c" fn free(p: ?*anyopaque) void;
pub extern "c" fn mlock(addr: *const anyopaque, len: usize) c_int;
pub extern "c" fn munlock(addr: *const anyopaque, len: usize) c_int;
