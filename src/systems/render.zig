const std = @import("std");
const sg = @import("sokol").gfx;
const spr = @import("../shaders/sprite_shader-shader.zig");
const world = @import("../world.zig");
const tcomp = @import("../components/transform.zig");
const scomp = @import("../components/sprite.zig");
const sprite = @import("../sprite.zig");
const camera = @import("../camera2d.zig");

const DrawItem = struct { frame_id: usize, x: f32, y: f32, z: f32, color: u32, rot: ?f32, atlas: u32, ord: usize };

pub const RenderSystem = struct {
    renderer: *sprite.SpriteRenderer,
    bind: *sg.Bindings,
    allocator: std.mem.Allocator,
    scratch_items: std.ArrayList(DrawItem),

    pub fn init(renderer: *sprite.SpriteRenderer, bind: *sg.Bindings) RenderSystem {
        const allocator = std.heap.page_allocator;
        return .{ .renderer = renderer, .bind = bind, .allocator = allocator, .scratch_items = std.ArrayList(DrawItem).init(allocator) };
    }

    pub fn deinit(self: *RenderSystem) void {
        self.scratch_items.deinit();
    }

    pub fn run(self: *RenderSystem, w: *world.World, cam: *camera.Camera2D, virtual_w: i32, virtual_h: i32) void {
        self.renderer.begin();
        // Uniforms: camera-based ortho over full virtual canvas
        const proj = cam.getOrtho(virtual_w, virtual_h);
        var vs_params: spr.VsParams = .{ .mvp = proj };
        sg.applyUniforms(spr.UB_vs_params, sg.asRange(&vs_params));

        // Collect then sort by texture (atlas index from packed frame_id) to reduce texture switches
        var items = &self.scratch_items;
        items.clearRetainingCapacity();

        var it = w.sprites.iter();
        var ord_counter: usize = 0;
        while (it.next()) |entry| {
            const id = entry[0];
            const sp: *scomp.Sprite = entry[1];
            if (!sp.enabled or !sp.visible) continue;
            if (w.getTransform(id)) |t| {
                if (!t.enabled) continue;
                const rot_opt: ?f32 = blk: {
                    if (t.rot != 0) break :blk t.rot;
                    if (sp.rotation != 0) break :blk sp.rotation;
                    break :blk null;
                };
                const h32: u32 = @intCast(sp.frame_id & 0xFFFF_FFFF);
                const atlas_idx: u32 = h32 >> 24;
                const di: DrawItem = .{ .frame_id = sp.frame_id, .x = t.x, .y = t.y, .z = sp.z, .color = sp.color, .rot = rot_opt, .atlas = atlas_idx, .ord = ord_counter };
                items.append(di) catch {};
                ord_counter += 1;
            }
        }
        // Sort by z (asc), then atlas (asc), then original order to preserve stability
        std.sort.block(DrawItem, items.items, {}, struct {
            fn lessThan(_: void, a: DrawItem, b: DrawItem) bool {
                if (a.z < b.z) return true;
                if (a.z > b.z) return false;
                if (a.atlas < b.atlas) return true;
                if (a.atlas > b.atlas) return false;
                return a.ord < b.ord;
            }
        }.lessThan);

        // Emit in sorted order
        for (items.items) |di| {
            self.renderer.addSpriteById(di.frame_id, di.x, di.y, di.color, di.rot);
        }

        self.renderer.flush(self.bind);
    }
};
