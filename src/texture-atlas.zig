const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;

// stb_image integration via C import.
// Make sure 'thirdparty/stb_image.h' exists
const c = @cImport({
    @cInclude("stb_image.h");
    @cDefine("STB_IMAGE_IMPLEMENTATION", "1");
    @cDefine("STBI_ONLY_PNG", "1");
    @cInclude("stb_image.h");
});

pub const LoadError = error{
    FileOpenFailed,
    DecodeFailed,
};

pub fn loadTexture(allocator: std.mem.Allocator, path: []const u8) !sg.Image {
    const zpath = try std.fmt.allocPrintZ(allocator, "{s}", .{path});
    defer allocator.free(zpath);

    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const pixels = c.stbi_load(zpath.ptr, &w, &h, &n, 4);
    if (pixels == null) return LoadError.DecodeFailed;
    defer c.stbi_image_free(pixels);

    var desc: sg.ImageDesc = .{};
    desc.width = @intCast(w);
    desc.height = @intCast(h);
    desc.pixel_format = .RGBA8;
    desc.data.subimage[0][0] = .{
        .ptr = pixels,
        .size = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4,
    };

    return sg.makeImage(desc);
}

pub fn getFrame(atlas: *const Atlas, name: []const u8) ?*const Frame {
    return atlas.frames.getPtr(name);
}

pub const UVRect = struct { u_min: f32, v_min: f32, u_max: f32, v_max: f32 };

pub fn getUVRect(frame: Frame, aw: i32, ah: i32) UVRect {
    return uvRectNormalized(frame.frame, aw, ah);
}

// ------------------------ Texture Atlas Support ------------------------

pub const RectI = struct { x: i32, y: i32, w: i32, h: i32 };
pub const SizeI = struct { w: i32, h: i32 };
pub const Pivot = struct { x: f32, y: f32 };

pub const Frame = struct {
    name: []const u8,
    frame: RectI,
    rotated: bool,
    trimmed: bool,
    spriteSourceSize: RectI,
    sourceSize: SizeI,
    pivot: Pivot,
};

pub const Atlas = struct {
    image: sg.Image,
    width: i32,
    height: i32,
    frames: std.StringHashMap(Frame),
};

pub fn loadAtlas(allocator: std.mem.Allocator, json_path: []const u8) !Atlas {
    // Read JSON file
    const file_data = try std.fs.cwd().readFileAlloc(allocator, json_path, 1024 * 1024);
    defer allocator.free(file_data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const root_obj = root.object;

    // meta
    const meta = root_obj.get("meta").?.object;
    const image_name = meta.get("image").?.string;
    const size_obj = meta.get("size").?.object;
    const atlas_w: i32 = @intCast(size_obj.get("w").?.integer);
    const atlas_h: i32 = @intCast(size_obj.get("h").?.integer);

    // Build png path from json_path directory + image_name
    const slash_index = std.mem.lastIndexOfScalar(u8, json_path, '/');
    const dir = if (slash_index) |idx| json_path[0..idx] else json_path;
    const png_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, image_name });
    defer allocator.free(png_path);

    // Load texture image
    const image = try loadTexture(allocator, png_path);

    // Parse frames
    var frames_map = std.StringHashMap(Frame).init(allocator);

    const frames_obj = root_obj.get("frames").?.object;
    var it = frames_obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const fobj = entry.value_ptr.*.object;

        const frame_obj = fobj.get("frame").?.object;
        const sss_obj = fobj.get("spriteSourceSize").?.object;
        const src_size_obj = fobj.get("sourceSize").?.object;
        const pivot_obj = fobj.get("pivot").?.object;

        const fr = RectI{
            .x = @intCast(frame_obj.get("x").?.integer),
            .y = @intCast(frame_obj.get("y").?.integer),
            .w = @intCast(frame_obj.get("w").?.integer),
            .h = @intCast(frame_obj.get("h").?.integer),
        };
        const sss = RectI{
            .x = @intCast(sss_obj.get("x").?.integer),
            .y = @intCast(sss_obj.get("y").?.integer),
            .w = @intCast(sss_obj.get("w").?.integer),
            .h = @intCast(sss_obj.get("h").?.integer),
        };
        const px_val = pivot_obj.get("x").?; // json.Value
        const py_val = pivot_obj.get("y").?;
        const px: f32 = switch (px_val) {
            .float => |fv| @floatCast(fv),
            .integer => |iv| @as(f32, @floatFromInt(iv)),
            else => 0.5,
        };
        const py: f32 = switch (py_val) {
            .float => |fv| @floatCast(fv),
            .integer => |iv| @as(f32, @floatFromInt(iv)),
            else => 0.5,
        };
        const pivot = Pivot{ .x = px, .y = py };

        const rotated = fobj.get("rotated").?.bool;
        const trimmed = fobj.get("trimmed").?.bool;

        // Store
        const name_dup = try allocator.dupe(u8, name);
        try frames_map.put(name_dup, Frame{
            .name = name_dup,
            .frame = fr,
            .rotated = rotated,
            .trimmed = trimmed,
            .spriteSourceSize = sss,
            .sourceSize = SizeI{ .w = @intCast(src_size_obj.get("w").?.integer), .h = @intCast(src_size_obj.get("h").?.integer) },
            .pivot = pivot,
        });
    }

    return Atlas{
        .image = image,
        .width = atlas_w,
        .height = atlas_h,
        .frames = frames_map,
    };
}

pub fn atlasDeinit(allocator: std.mem.Allocator, atlas: *Atlas) void {
    var it = atlas.frames.iterator();
    while (it.next()) |entry| {
        const key_slice = entry.key_ptr.*;
        allocator.free(key_slice);
    }
    atlas.frames.deinit();
}

pub fn uvRectNormalized(r: RectI, aw: i32, ah: i32) UVRect {
    const inv_w: f32 = 1.0 / @as(f32, @floatFromInt(aw));
    const inv_h: f32 = 1.0 / @as(f32, @floatFromInt(ah));
    return .{
        .u_min = @as(f32, @floatFromInt(r.x)) * inv_w,
        .v_min = @as(f32, @floatFromInt(r.y)) * inv_h,
        .u_max = @as(f32, @floatFromInt(r.x + r.w)) * inv_w,
        .v_max = @as(f32, @floatFromInt(r.y + r.h)) * inv_h,
    };
}

pub fn uvToShort2N(u: f32) i16 {
    var v = u * 32767.0;
    if (v < 0.0) v = 0.0;
    if (v > 32767.0) v = 32767.0;
    return @as(i16, @intFromFloat(v));
}
