//! The slice of FreeType that font.zig uses, declared by hand in Zig (the
//! same approach as gdkpixbuf.zig): no C header, no @cImport (Zig 0.17
//! removed it) and no translate-c build step.
//!
//! Layouts follow FreeType's public headers (freetype/freetype.h,
//! freetype/ftimage.h, freetype/fttypes.h) for LP64 Linux, the only target
//! this project builds for. Only the leading public fields font.zig reads
//! are declared on FT_FaceRec and FT_GlyphSlotRec: FreeType allocates these
//! records and hands out pointers, so this side never needs their full size.
//! The offsets were checked against translate-c's view of the real headers.

pub const FT_Error = c_int;
pub const FT_Pos = c_long;
pub const FT_Fixed = c_long;

pub const LibraryRec = opaque {};
pub const FT_Library = ?*LibraryRec;
pub const FT_Face = [*c]FT_FaceRec;

/// Bit 2: render to an 8-bit anti-aliased bitmap while loading.
pub const FT_LOAD_RENDER: i32 = 1 << 2;

pub const FT_Generic = extern struct {
    data: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
};

pub const FT_BBox = extern struct {
    xMin: FT_Pos,
    yMin: FT_Pos,
    xMax: FT_Pos,
    yMax: FT_Pos,
};

pub const FT_Vector = extern struct {
    x: FT_Pos,
    y: FT_Pos,
};

pub const FT_Size_Metrics = extern struct {
    x_ppem: c_ushort,
    y_ppem: c_ushort,
    x_scale: FT_Fixed,
    y_scale: FT_Fixed,
    ascender: FT_Pos,
    descender: FT_Pos,
    height: FT_Pos,
    max_advance: FT_Pos,
};

pub const FT_SizeRec = extern struct {
    face: FT_Face,
    generic: FT_Generic,
    metrics: FT_Size_Metrics,
    internal: ?*anyopaque,
};

pub const FT_Glyph_Metrics = extern struct {
    width: FT_Pos,
    height: FT_Pos,
    horiBearingX: FT_Pos,
    horiBearingY: FT_Pos,
    horiAdvance: FT_Pos,
    vertBearingX: FT_Pos,
    vertBearingY: FT_Pos,
    vertAdvance: FT_Pos,
};

pub const FT_Bitmap = extern struct {
    rows: c_uint,
    width: c_uint,
    pitch: c_int,
    buffer: [*c]u8,
    num_grays: c_ushort,
    pixel_mode: u8,
    palette_mode: u8,
    palette: ?*anyopaque,
};

/// Leading public fields only (see the file comment).
pub const FT_GlyphSlotRec = extern struct {
    library: FT_Library,
    face: FT_Face,
    next: [*c]FT_GlyphSlotRec,
    glyph_index: c_uint,
    generic: FT_Generic,
    metrics: FT_Glyph_Metrics,
    linearHoriAdvance: FT_Fixed,
    linearVertAdvance: FT_Fixed,
    advance: FT_Vector,
    format: c_uint, // FT_Glyph_Format
    bitmap: FT_Bitmap,
    bitmap_left: c_int,
    bitmap_top: c_int,
};

/// Leading public fields only (see the file comment).
pub const FT_FaceRec = extern struct {
    num_faces: c_long,
    face_index: c_long,
    face_flags: c_long,
    style_flags: c_long,
    num_glyphs: c_long,
    family_name: [*c]u8,
    style_name: [*c]u8,
    num_fixed_sizes: c_int,
    available_sizes: ?*anyopaque,
    num_charmaps: c_int,
    charmaps: ?*anyopaque,
    generic: FT_Generic,
    bbox: FT_BBox,
    units_per_EM: c_ushort,
    ascender: c_short,
    descender: c_short,
    height: c_short,
    max_advance_width: c_short,
    max_advance_height: c_short,
    underline_position: c_short,
    underline_thickness: c_short,
    glyph: [*c]FT_GlyphSlotRec,
    size: [*c]FT_SizeRec,
    charmap: ?*anyopaque,
};

pub extern "c" fn FT_Init_FreeType(alibrary: *FT_Library) FT_Error;
pub extern "c" fn FT_Done_FreeType(library: FT_Library) FT_Error;
pub extern "c" fn FT_New_Face(library: FT_Library, filepathname: [*:0]const u8, face_index: c_long, aface: *FT_Face) FT_Error;
pub extern "c" fn FT_Done_Face(face: FT_Face) FT_Error;
pub extern "c" fn FT_Set_Pixel_Sizes(face: FT_Face, pixel_width: c_uint, pixel_height: c_uint) FT_Error;
pub extern "c" fn FT_Load_Char(face: FT_Face, char_code: c_ulong, load_flags: i32) FT_Error;
