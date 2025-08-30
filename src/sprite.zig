const std = @import("std");
const sg = @import("sokol").gfx;
const tex = @import("texture-atlas.zig");
const spr_shader = @import("shaders/sprite_shader-shader.zig");

// u16 index limit: indices are 0..65535; 4 verts per sprite -> max 16383 sprites per draw
const MAX_SPRITES_PER_DRAW: usize = 65535 / 4;

pub const Vertex = extern struct { x: f32, y: f32, z: f32, color: u32, u: i16, v: i16 };
const Batch = struct { image: sg.Image, start_sprite: usize, count: usize };

pub const Sprite = struct {
    x: f32,
    y: f32,
    rotation: f32 = 0.0, // radians (unused for now)
    color: u32 = 0xFFFFFFFF,
    frame_name: []const u8,
};

pub const SpriteRenderer = struct {
    allocator: std.mem.Allocator,
    // initial capacity hint; renderer grows beyond this automatically
    max_sprites: usize,

    // CPU-side vertex staging
    verts: std.ArrayList(Vertex),
    sprite_count: usize,

    // GPU buffers
    // transient vertex buffer created per flush()
    // persistent index buffer reused
    ibuf: sg.Buffer,
    index_capacity_sprites: usize, // how many sprites indices can reference currently

    // Multi-atlas: images, frames per atlas, and name->packed handle map
    atlas_images: std.ArrayList(sg.Image),
    atlas_widths: std.ArrayList(i32),
    atlas_heights: std.ArrayList(i32),
    frames_per_atlas: std.ArrayList(std.ArrayList(*const tex.Frame)),
    name_to_id: std.StringHashMap(usize),

    // Batching by image
    batches: std.ArrayList(Batch),

    inline fn packHandle(atlas_idx: u32, frame_idx: u32) usize {
        return @intCast((atlas_idx << 24) | (frame_idx & 0x00FF_FFFF));
    }

    inline fn handleAtlas(h: usize) u32 {
        const h32: u32 = @intCast(h & 0xFFFF_FFFF);
        return h32 >> 24;
    }

    inline fn handleFrame(h: usize) u32 {
        const h32: u32 = @intCast(h & 0xFFFF_FFFF);
        return h32 & 0x00FF_FFFF;
    }

    pub fn init(allocator: std.mem.Allocator, max_sprites: usize) SpriteRenderer {
        var sr = SpriteRenderer{
            .allocator = allocator,
            .max_sprites = max_sprites,
            .verts = std.ArrayList(Vertex).init(allocator),
            .sprite_count = 0,
            .ibuf = .{},
            .index_capacity_sprites = 0,
            .atlas_images = std.ArrayList(sg.Image).init(allocator),
            .frames_per_atlas = std.ArrayList(std.ArrayList(*const tex.Frame)).init(allocator),
            .name_to_id = std.StringHashMap(usize).init(allocator),
            .batches = std.ArrayList(Batch).init(allocator),
            .atlas_widths = std.ArrayList(i32).init(allocator),
            .atlas_heights = std.ArrayList(i32).init(allocator),
        };
        // reserve CPU array (hint only; renderer auto-grows)
        _ = sr.verts.ensureTotalCapacity(4 * max_sprites) catch {};
        // create index buffer with initial capacity
        sr.ensureIndexCapacity(max_sprites);
        return sr;
    }

    pub fn registerAtlas(self: *SpriteRenderer, atlas: *const tex.Atlas) u8 {
        const atlas_idx_usize: usize = self.atlas_images.items.len;
        const atlas_idx_u8: u8 = @intCast(atlas_idx_usize);
        self.atlas_images.append(atlas.image) catch {};
        self.atlas_widths.append(atlas.width) catch {};
        self.atlas_heights.append(atlas.height) catch {};
        var frames_list = std.ArrayList(*const tex.Frame).init(self.allocator);
        var it = atlas.frames.iterator();
        while (it.next()) |entry| {
            const idx_in_atlas: usize = frames_list.items.len;
            frames_list.append(entry.value_ptr) catch {};
            const handle: usize = packHandle(@intCast(atlas_idx_u8), @intCast(idx_in_atlas));
            _ = self.name_to_id.put(entry.key_ptr.*, handle) catch {};
        }
        self.frames_per_atlas.append(frames_list) catch {};
        return atlas_idx_u8;
    }

    pub fn deinit(self: *SpriteRenderer) void {
        if (self.ibuf.id != 0) sg.destroyBuffer(self.ibuf);
        self.verts.deinit();
        var i: usize = 0;
        while (i < self.frames_per_atlas.items.len) : (i += 1) {
            self.frames_per_atlas.items[i].deinit();
        }
        self.frames_per_atlas.deinit();
        self.atlas_images.deinit();
        self.atlas_widths.deinit();
        self.atlas_heights.deinit();
        self.batches.deinit();
        self.name_to_id.deinit();
    }

    pub fn begin(self: *SpriteRenderer) void {
        self.verts.clearRetainingCapacity();
        self.sprite_count = 0;
        self.batches.clearRetainingCapacity();
    }

    // Pre-grow CPU vertices and GPU index buffer to handle at least n sprites without further reallocations.
    pub fn reserveSprites(self: *SpriteRenderer, n: usize) void {
        const clamped = @min(n, MAX_SPRITES_PER_DRAW);
        self.ensureCapacitySprites(clamped);
    }

    pub fn submit(self: *SpriteRenderer, _: *const Sprite, _: i32, _: i32) void {
        _ = self;
    }

    pub fn getIdByName(self: *SpriteRenderer, name: []const u8) ?usize {
        return self.name_to_id.get(name);
    }

    pub fn addSpriteByName(self: *SpriteRenderer, name: []const u8, x: f32, y: f32, color: u32, rotation: ?f32) void {
        if (self.name_to_id.get(name)) |id| {
            self.addSpriteById(id, x, y, color, rotation);
        } else {
            return;
        }
    }

    pub fn addSpriteById(self: *SpriteRenderer, id: usize, x: f32, y: f32, color: u32, rotation: ?f32) void {
        const atlas_idx_u32 = handleAtlas(id);
        const frame_idx_u32 = handleFrame(id);
        const atlas_idx: usize = @intCast(atlas_idx_u32);
        if (atlas_idx >= self.frames_per_atlas.items.len) return;
        const frames_list = self.frames_per_atlas.items[atlas_idx];
        const fidx: usize = @intCast(frame_idx_u32);
        if (fidx >= frames_list.items.len) return;
        if (self.sprite_count >= MAX_SPRITES_PER_DRAW) return; // hard cap per frame
        // ensure capacity for one more sprite
        self.ensureCapacitySprites(self.sprite_count + 1);

        const fr = frames_list.items[fidx].*;
        const uv = tex.uvRectNormalized(fr.frame, self.atlas_widths.items[atlas_idx], self.atlas_heights.items[atlas_idx]);
        const u_min_s: i16 = tex.uvToShort2N(uv.u_min);
        const v_min_s: i16 = tex.uvToShort2N(uv.v_min);
        const u_max_s: i16 = tex.uvToShort2N(uv.u_max);
        const v_max_s: i16 = tex.uvToShort2N(uv.v_max);

        const w: f32 = @floatFromInt(fr.frame.w);
        const h: f32 = @floatFromInt(fr.frame.h);

        if (rotation) |rot| {
            const cx: f32 = x + 0.5 * w;
            const cy: f32 = y + 0.5 * h;
            const hw: f32 = 0.5 * w;
            const hh: f32 = 0.5 * h;
            const c: f32 = std.math.cos(rot);
            const s: f32 = std.math.sin(rot);

            // corners in TL, TR, BR, BL order for UV mapping
            const tlx = -hw;
            const tly = -hh;
            const trx = hw;
            const try_y = -hh;
            const brx = hw;
            const bry = hh;
            const blx = -hw;
            const bly = hh;

            const p0x: f32 = cx + tlx * c - tly * s;
            const p0y: f32 = cy + tlx * s + tly * c;
            const p1x: f32 = cx + trx * c - try_y * s;
            const p1y: f32 = cy + trx * s + try_y * c;
            const p2x: f32 = cx + brx * c - bry * s;
            const p2y: f32 = cy + brx * s + bry * c;
            const p3x: f32 = cx + blx * c - bly * s;
            const p3y: f32 = cy + blx * s + bly * c;

            self.verts.appendAssumeCapacity(.{ .x = p0x, .y = p0y, .z = 0.0, .color = color, .u = u_min_s, .v = v_min_s });
            self.verts.appendAssumeCapacity(.{ .x = p1x, .y = p1y, .z = 0.0, .color = color, .u = u_max_s, .v = v_min_s });
            self.verts.appendAssumeCapacity(.{ .x = p2x, .y = p2y, .z = 0.0, .color = color, .u = u_max_s, .v = v_max_s });
            self.verts.appendAssumeCapacity(.{ .x = p3x, .y = p3y, .z = 0.0, .color = color, .u = u_min_s, .v = v_max_s });
        } else {
            // No rotation, use axis-aligned vertices
            const x0: f32 = x;
            const y0: f32 = y;
            const x1: f32 = x + w;
            const y1: f32 = y + h;

            self.verts.appendAssumeCapacity(.{ .x = x0, .y = y0, .z = 0.0, .color = color, .u = u_min_s, .v = v_min_s });
            self.verts.appendAssumeCapacity(.{ .x = x1, .y = y0, .z = 0.0, .color = color, .u = u_max_s, .v = v_min_s });
            self.verts.appendAssumeCapacity(.{ .x = x1, .y = y1, .z = 0.0, .color = color, .u = u_max_s, .v = v_max_s });
            self.verts.appendAssumeCapacity(.{ .x = x0, .y = y1, .z = 0.0, .color = color, .u = u_min_s, .v = v_max_s });
        }

        // batching by image
        const img = self.atlas_images.items[atlas_idx];
        if (self.batches.items.len == 0) {
            self.batches.append(.{ .image = img, .start_sprite = self.sprite_count, .count = 1 }) catch {};
        } else {
            var last = &self.batches.items[self.batches.items.len - 1];
            if (last.image.id == img.id) {
                last.count += 1;
            } else {
                self.batches.append(.{ .image = img, .start_sprite = self.sprite_count, .count = 1 }) catch {};
            }
        }

        self.sprite_count += 1;
    }

    pub fn flush(self: *SpriteRenderer, bind: *sg.Bindings) void {
        if (self.sprite_count == 0) return;
        const vbuf = sg.makeBuffer(.{ .data = sg.asRange(self.verts.items) });
        bind.vertex_buffers[0] = vbuf;
        bind.index_buffer = self.ibuf;

        const cap_raw: usize = self.index_capacity_sprites;
        const cap: usize = if (cap_raw == 0) 16383 else cap_raw; // safety

        var bi: usize = 0;
        while (bi < self.batches.items.len) : (bi += 1) {
            const b = self.batches.items[bi];
            bind.images[spr_shader.IMG_tex] = b.image;
            sg.applyBindings(bind.*);

            var remaining: usize = b.count;
            var drawn: usize = 0;
            while (remaining > 0) {
                const batch_count: usize = @min(remaining, cap);
                const sprite_base: usize = b.start_sprite + drawn;
                const base_elem: u32 = @intCast(6 * sprite_base);
                const index_count: u32 = @intCast(6 * batch_count);
                sg.draw(base_elem, index_count, 1);
                remaining -= batch_count;
                drawn += batch_count;
            }
        }
        sg.destroyBuffer(vbuf);
    }

    fn ensureCapacitySprites(self: *SpriteRenderer, needed_sprites: usize) void {
        // vertices: 4 per sprite
        const clamped_needed = @min(needed_sprites, MAX_SPRITES_PER_DRAW);
        const needed_verts = std.math.mul(usize, 4, clamped_needed) catch (MAX_SPRITES_PER_DRAW * 4);
        _ = self.verts.ensureTotalCapacity(needed_verts) catch {};
        // indices: grow index buffer if needed
        if (clamped_needed > self.index_capacity_sprites) {
            var new_cap: usize = if (self.index_capacity_sprites == 0) self.max_sprites else self.index_capacity_sprites * 2;
            if (new_cap < clamped_needed) new_cap = clamped_needed;
            self.ensureIndexCapacity(new_cap);
        }
    }

    fn ensureIndexCapacity(self: *SpriteRenderer, capacity_sprites: usize) void {
        if (capacity_sprites <= self.index_capacity_sprites) return;
        const capped: usize = @min(capacity_sprites, MAX_SPRITES_PER_DRAW);
        // rebuild indices up to capped
        const index_count = std.math.mul(usize, 6, capped) catch (MAX_SPRITES_PER_DRAW * 6);
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
        self.index_capacity_sprites = capped;
    }
};
