const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;

// stb_truetype integration via C import.
// Make sure 'thirdparty/stb_truetype.h' exists
const c = @cImport({
    @cInclude("stb_truetype.h");
});

pub const Glyph = struct {
    // texture page index (we only use page 0 for this minimal test)
    page: u32,
    // atlas rect
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    // layout metrics
    xoff: f32,
    yoff: f32,
    xadvance: f32,
    // normalized UVs cached for convenience
    u_min: f32,
    v_min: f32,
    u_max: f32,
    v_max: f32,
};

pub const Font = struct {
    allocator: std.mem.Allocator,
    // raw ttf data (kept alive for lifetime of font)
    ttf_data: []u8,
    info: c.stbtt_fontinfo,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    // baked size
    pixel_height: f32,
    // single atlas page for minimal implementation
    page_img: sg.Image,
    page_w: i32,
    page_h: i32,
    // glyphs for ASCII range 32..126
    glyphs: [127]Glyph, // index by codepoint; entries <32 unused

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8, pixel_height: f32, page_w: i32, page_h: i32) !Font {
        var f = Font{
            .allocator = allocator,
            .ttf_data = &[_]u8{},
            .info = undefined,
            .ascent = 0,
            .descent = 0,
            .line_gap = 0,
            .pixel_height = pixel_height,
            .page_img = .{},
            .page_w = page_w,
            .page_h = page_h,
            .glyphs = undefined,
        };

        // read TTF
        f.ttf_data = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);

        // init font info
        if (c.stbtt_InitFont(&f.info, f.ttf_data.ptr, c.stbtt_GetFontOffsetForIndex(f.ttf_data.ptr, 0)) == 0) {
            return error.InvalidFont;
        }

        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);
        const scale: f32 = c.stbtt_ScaleForPixelHeight(&f.info, pixel_height);
        f.ascent = @as(f32, @floatFromInt(asc)) * scale;
        f.descent = @as(f32, @floatFromInt(desc)) * scale;
        f.line_gap = @as(f32, @floatFromInt(gap)) * scale;

        // bake ASCII 32..126 into one atlas
        const bw: usize = @intCast(page_w * page_h);
        var bitmap = try allocator.alloc(u8, bw * 4); // RGBA8 atlas (A=coverage, RGB=255)
        defer allocator.free(bitmap);
        @memset(bitmap, 0);

        // simple skyline packer
        var x_cursor: i32 = 1;
        var y_cursor: i32 = 1;
        var row_h: i32 = 0;

        var cp: usize = 32;
        while (cp <= 126) : (cp += 1) {
            const codepoint: c_int = @intCast(cp);
            var ax: c_int = 0;
            var lsb: c_int = 0;
            c.stbtt_GetCodepointHMetrics(&f.info, codepoint, &ax, &lsb);

            var x0: c_int = 0;
            var y0: c_int = 0;
            var x1: c_int = 0;
            var y1: c_int = 0;
            c.stbtt_GetCodepointBitmapBox(&f.info, codepoint, scale, scale, &x0, &y0, &x1, &y1);
            const gw: i32 = @intCast(x1 - x0);
            const gh: i32 = @intCast(y1 - y0);
            const pad: i32 = 1;
            if (gw <= 0 or gh <= 0) {
                // space or non-rendering glyph
                f.glyphs[cp] = .{ .page = 0, .x = 0, .y = 0, .w = 0, .h = 0, .xoff = 0, .yoff = 0, .xadvance = @as(f32, @floatFromInt(ax)) * scale, .u_min = 0, .v_min = 0, .u_max = 0, .v_max = 0 };
                continue;
            }
            if (x_cursor + gw + pad >= page_w) {
                x_cursor = 1;
                y_cursor += row_h + pad;
                row_h = 0;
            }
            if (y_cursor + gh + pad >= page_h) {
                return error.AtlasTooSmall;
            }

            // render glyph bitmap (8-bit coverage)
            const gsize: usize = @intCast(gw * gh);
            const gbuf = try allocator.alloc(u8, gsize);
            defer allocator.free(gbuf);
            @memset(gbuf, 0);
            _ = c.stbtt_MakeCodepointBitmap(&f.info, gbuf.ptr, gw, gh, gw, scale, scale, codepoint);

            // blit into RGBA atlas with white RGB and coverage in A
            var yy: i32 = 0;
            while (yy < gh) : (yy += 1) {
                var xx: i32 = 0;
                while (xx < gw) : (xx += 1) {
                    const cov: u8 = gbuf[@intCast(@as(usize, @intCast(yy)) * @as(usize, @intCast(gw)) + @as(usize, @intCast(xx)))];
                    const dst_x: i32 = x_cursor + xx;
                    const dst_y: i32 = y_cursor + yy;
                    const di: usize = @intCast((dst_y * page_w + dst_x) * 4);
                    bitmap[di + 0] = 0xFF;
                    bitmap[di + 1] = 0xFF;
                    bitmap[di + 2] = 0xFF;
                    bitmap[di + 3] = cov;
                }
            }

            // metrics and uv
            var xoff_f: c_int = 0;
            var yoff_f: c_int = 0;
            c.stbtt_GetCodepointBitmapBoxSubpixel(&f.info, codepoint, scale, scale, 0, 0, &x0, &y0, &x1, &y1);
            xoff_f = x0;
            yoff_f = y0;
            const adv: f32 = @as(f32, @floatFromInt(ax)) * scale;
            const u_min_val: f32 = @as(f32, @floatFromInt(x_cursor)) / @as(f32, @floatFromInt(page_w));
            const v_min_val: f32 = @as(f32, @floatFromInt(y_cursor)) / @as(f32, @floatFromInt(page_h));
            const u_max_val: f32 = @as(f32, @floatFromInt(x_cursor + gw)) / @as(f32, @floatFromInt(page_w));
            const v_max_val: f32 = @as(f32, @floatFromInt(y_cursor + gh)) / @as(f32, @floatFromInt(page_h));

            f.glyphs[cp] = .{
                .page = 0,
                .x = x_cursor,
                .y = y_cursor,
                .w = gw,
                .h = gh,
                .xoff = @as(f32, @floatFromInt(xoff_f)),
                .yoff = @as(f32, @floatFromInt(yoff_f)),
                .xadvance = adv,
                .u_min = u_min_val,
                .v_min = v_min_val,
                .u_max = u_max_val,
                .v_max = v_max_val,
            };

            x_cursor += gw + pad;
            if (gh > row_h) row_h = gh;
        }

        // upload atlas to GPU
        var img_desc: sg.ImageDesc = .{};
        img_desc.width = @intCast(page_w);
        img_desc.height = @intCast(page_h);
        img_desc.pixel_format = .RGBA8;
        img_desc.data.subimage[0][0] = .{ .ptr = bitmap.ptr, .size = @as(usize, @intCast(page_w * page_h * 4)) };
        f.page_img = sg.makeImage(img_desc);

        return f;
    }

    pub fn deinit(self: *Font) void {
        if (self.page_img.id != 0) sg.destroyImage(self.page_img);
        if (self.ttf_data.len > 0) self.allocator.free(self.ttf_data);
        self.ttf_data = &[_]u8{};
    }

    pub fn getGlyph(self: *const Font, codepoint: u32) ?*const Glyph {
        if (codepoint < 127 and codepoint >= 32) {
            return &self.glyphs[@intCast(codepoint)];
        }
        return null;
    }

    pub fn getLineAdvance(self: *const Font) f32 {
        return self.ascent - self.descent + self.line_gap;
    }
};
