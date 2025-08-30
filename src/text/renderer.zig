const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const spr_shader = @import("../shaders/sprite_shader-shader.zig");
const FontMod = @import("font.zig");

pub const Vertex = extern struct { x: f32, y: f32, z: f32, color: u32, u: i16, v: i16 };
const Batch = struct { image: sg.Image, start: usize, count: usize };

// Max quads per draw (u16 indices, 4 verts per quad)
const MAX_QUADS_PER_DRAW: usize = 65535 / 4;

pub const TextRenderer = struct {
    allocator: std.mem.Allocator,
    max_quads_hint: usize,

    verts: std.ArrayList(Vertex),
    quad_count: usize,

    ibuf: sg.Buffer,
    index_capacity_quads: usize,

    batches: std.ArrayList(Batch),

    pub fn init(allocator: std.mem.Allocator, max_quads: usize) TextRenderer {
        var tr = TextRenderer{
            .allocator = allocator,
            .max_quads_hint = max_quads,
            .verts = std.ArrayList(Vertex).init(allocator),
            .quad_count = 0,
            .ibuf = .{},
            .index_capacity_quads = 0,
            .batches = std.ArrayList(Batch).init(allocator),
        };
        _ = tr.verts.ensureTotalCapacity(4 * max_quads) catch {};
        tr.ensureIndexCapacity(max_quads);
        return tr;
    }

    pub fn deinit(self: *TextRenderer) void {
        if (self.ibuf.id != 0) sg.destroyBuffer(self.ibuf);
        self.verts.deinit();
        self.batches.deinit();
    }

    pub fn begin(self: *TextRenderer) void {
        self.verts.clearRetainingCapacity();
        self.quad_count = 0;
        self.batches.clearRetainingCapacity();
    }

    pub fn reserveQuads(self: *TextRenderer, n: usize) void {
        const clamped = @min(n, MAX_QUADS_PER_DRAW);
        self.ensureCapacityQuads(clamped);
    }

    inline fn uvToShort2N(u: f32) i16 {
        var v = u * 32767.0;
        if (v < 0.0) v = 0.0;
        if (v > 32767.0) v = 32767.0;
        return @as(i16, @intFromFloat(v));
    }

    pub fn drawText(self: *TextRenderer, font: *const FontMod.Font, x: f32, y: f32, color: u32, text: []const u8) void {
        var pen_x = x;
        const baseline_y = y + font.ascent; // place baseline so glyph yoffs apply correctly
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const ch: u8 = text[i];
            if (ch == '\n') {
                pen_x = x;
                // move down by line advance
                // y increases downward in our ortho setup, so add
                continue;
            }
            const g_opt = font.getGlyph(ch);
            if (g_opt) |g| {
                if (g.w > 0 and g.h > 0) {
                    if (self.quad_count >= MAX_QUADS_PER_DRAW) break;
                    self.ensureCapacityQuads(self.quad_count + 1);

                    const uv0_u: i16 = uvToShort2N(g.u_min);
                    const uv0_v: i16 = uvToShort2N(g.v_min);
                    const uv1_u: i16 = uvToShort2N(g.u_max);
                    const uv1_v: i16 = uvToShort2N(g.v_max);

                    const gx0: f32 = pen_x + g.xoff;
                    const gy0: f32 = baseline_y + g.yoff;
                    const gx1: f32 = gx0 + @as(f32, @floatFromInt(g.w));
                    const gy1: f32 = gy0 + @as(f32, @floatFromInt(g.h));

                    self.verts.appendAssumeCapacity(.{ .x = gx0, .y = gy0, .z = 0, .color = color, .u = uv0_u, .v = uv0_v });
                    self.verts.appendAssumeCapacity(.{ .x = gx1, .y = gy0, .z = 0, .color = color, .u = uv1_u, .v = uv0_v });
                    self.verts.appendAssumeCapacity(.{ .x = gx1, .y = gy1, .z = 0, .color = color, .u = uv1_u, .v = uv1_v });
                    self.verts.appendAssumeCapacity(.{ .x = gx0, .y = gy1, .z = 0, .color = color, .u = uv0_u, .v = uv1_v });

                    // batching (single page for now)
                    const img = font.page_img;
                    if (self.batches.items.len == 0) {
                        self.batches.append(.{ .image = img, .start = self.quad_count, .count = 1 }) catch {};
                    } else {
                        var last = &self.batches.items[self.batches.items.len - 1];
                        if (last.image.id == img.id) {
                            last.count += 1;
                        } else {
                            self.batches.append(.{ .image = img, .start = self.quad_count, .count = 1 }) catch {};
                        }
                    }

                    self.quad_count += 1;
                }
                pen_x += g.xadvance;
            }
        }
    }

    pub fn flush(self: *TextRenderer, bind: *sg.Bindings) void {
        if (self.quad_count == 0) return;
        const vbuf = sg.makeBuffer(.{ .data = sg.asRange(self.verts.items) });
        bind.vertex_buffers[0] = vbuf;
        bind.index_buffer = self.ibuf;

        const cap_raw: usize = self.index_capacity_quads;
        const cap: usize = if (cap_raw == 0) 16383 else cap_raw;

        var bi: usize = 0;
        while (bi < self.batches.items.len) : (bi += 1) {
            const b = self.batches.items[bi];
            bind.images[spr_shader.IMG_tex] = b.image;
            sg.applyBindings(bind.*);

            var remaining: usize = b.count;
            var drawn: usize = 0;
            while (remaining > 0) {
                const batch_count: usize = @min(remaining, cap);
                const base_elem: u32 = @intCast(6 * (b.start + drawn));
                const index_count: u32 = @intCast(6 * batch_count);
                sg.draw(base_elem, index_count, 1);
                remaining -= batch_count;
                drawn += batch_count;
            }
        }
        sg.destroyBuffer(vbuf);
    }

    fn ensureCapacityQuads(self: *TextRenderer, needed: usize) void {
        const clamped = @min(needed, MAX_QUADS_PER_DRAW);
        const needed_verts = std.math.mul(usize, 4, clamped) catch (MAX_QUADS_PER_DRAW * 4);
        _ = self.verts.ensureTotalCapacity(needed_verts) catch {};
        if (clamped > self.index_capacity_quads) {
            var new_cap: usize = if (self.index_capacity_quads == 0) self.max_quads_hint else self.index_capacity_quads * 2;
            if (new_cap < clamped) new_cap = clamped;
            self.ensureIndexCapacity(new_cap);
        }
    }

    fn ensureIndexCapacity(self: *TextRenderer, capacity_quads: usize) void {
        if (capacity_quads <= self.index_capacity_quads) return;
        const capped: usize = @min(capacity_quads, MAX_QUADS_PER_DRAW);
        const index_count = std.math.mul(usize, 6, capped) catch (MAX_QUADS_PER_DRAW * 6);
        var indices16 = self.allocator.alloc(u16, index_count) catch unreachable;
        defer self.allocator.free(indices16);
        var vi2: u32 = 0;
        var ii2: usize = 0;
        var s2: usize = 0;
        while (s2 < capped) : (s2 += 1) {
            indices16[ii2 + 0] = @intCast(vi2 + 0);
            indices16[ii2 + 1] = @intCast(vi2 + 1);
            indices16[ii2 + 2] = @intCast(vi2 + 2);
            indices16[ii2 + 3] = @intCast(vi2 + 0);
            indices16[ii2 + 4] = @intCast(vi2 + 2);
            indices16[ii2 + 5] = @intCast(vi2 + 3);
            vi2 += 4;
            ii2 += 6;
        }
        if (self.ibuf.id != 0) sg.destroyBuffer(self.ibuf);
        self.ibuf = sg.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = sg.asRange(indices16) });
        self.index_capacity_quads = capped;
    }
};
