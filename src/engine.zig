const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const spr = @import("shaders/sprite_shader-shader.zig");
const mat4 = @import("math.zig").Mat4;
const tex = @import("texture-atlas.zig");
const sprite = @import("sprite.zig");
const pipeline = @import("pipeline.zig");
const camera = @import("camera2d.zig");

const world_mod = @import("world.zig");
const sys_render = @import("systems/render.zig");
const lua_vm = @import("scripting/lua_vm.zig");
const text_font = @import("text/font.zig");
const text_renderer = @import("text/renderer.zig");

pub const AspectMode = enum { letterbox, stretch, crop, fit_width, fit_height };

pub const Engine = struct {
    pass_action: sg.PassAction = .{},
    pip_direct: sg.Pipeline = .{},
    pip_smooth: sg.Pipeline = .{},
    bind: sg.Bindings = .{},
    atlas: ?tex.Atlas = null,
    spr_renderer: ?sprite.SpriteRenderer = null,
    txt_renderer: ?text_renderer.TextRenderer = null,
    font: ?text_font.Font = null,
    sprite_linear: bool = true,
    smooth_filter: bool = false,
    spr_sampler_nearest: sg.Sampler = .{},
    spr_sampler_linear: sg.Sampler = .{},
    aspect_mode: AspectMode = .letterbox,
    virtual_w: i32 = 640,
    virtual_h: i32 = 360,
    cam: camera.Camera2D = camera.Camera2D.init(),
    overlay_visible: bool = true,
    // input state for camera
    key_left: bool = false,
    key_right: bool = false,
    key_up: bool = false,
    key_down: bool = false,
    // ECS
    world: ?world_mod.World = null,
    render_sys: ?sys_render.RenderSystem = null,
    use_ecs_render: bool = false,

    extra_atlases: ?std.ArrayList(tex.Atlas) = null,
};

pub var state: Engine = .{};

// Basic vertex definition used by sprite renderer
const Vertex = extern struct { x: f32, y: f32, z: f32, color: u32, u: i16, v: i16 };

pub fn init(virtual_w: i32, virtual_h: i32, aspect: AspectMode) void {
    state.virtual_w = virtual_w;
    state.virtual_h = virtual_h;
    state.aspect_mode = aspect;
    // Initialize scripting VM (load script later after ECS context is ready)
    lua_vm.init();
}

// --- Runtime configuration setters (for Lua bindings) ---
pub fn setVirtualResolution(w: i32, h: i32) void {
    state.virtual_w = if (w > 0) w else state.virtual_w;
    state.virtual_h = if (h > 0) h else state.virtual_h;
}

pub fn setAspectMode(mode: AspectMode) void {
    state.aspect_mode = mode;
}

pub fn loadAtlas(atlas_path: []const u8) void {
    const allocator = std.heap.page_allocator;
    state.atlas = tex.loadAtlas(allocator, atlas_path) catch |e| blk: {
        std.log.warn("failed to load atlas: {}", .{e});
        break :blk null;
    };
}

pub fn initWorldAndRenderer() void {
    // Initialize renderer, ECS world, and render system regardless of atlas status.
    const allocator = std.heap.page_allocator;
    if (state.spr_renderer == null) {
        state.spr_renderer = sprite.SpriteRenderer.init(allocator, 200);
    }
    if (state.txt_renderer == null) {
        state.txt_renderer = text_renderer.TextRenderer.init(allocator, 256);
    }
    if (state.spr_renderer) |*r| {
        if (state.world == null) state.world = world_mod.World.init(allocator);
        if (state.render_sys == null) state.render_sys = sys_render.RenderSystem.init(r, &state.bind);
    }
    if (state.extra_atlases == null) {
        state.extra_atlases = std.ArrayList(tex.Atlas).init(allocator);
    }

    // Load a default font for testing (no Lua binding yet)
    if (state.font == null) {
        const font_path: []const u8 = "assets/fonts/Inter_18pt-Regular.ttf";
        const f = text_font.Font.loadFromFile(allocator, font_path, 32.0, 512, 512) catch |e| blk: {
            std.log.warn("failed to load font {s}: {any}", .{ font_path, e });
            break :blk null;
        };
        if (f) |font_inst| {
            state.font = font_inst;
        }
    }
}

pub fn loadGameScript() void {
    if (state.world) |*w| {
        if (state.spr_renderer) |*r| {
            lua_vm.setContext(.{ .world = w, .renderer = r });
            var script_path: []const u8 = "assets/scripts/game.lua";
            var script_alloc: ?[]u8 = null;
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "GAME_SCRIPT")) |sp| {
                script_alloc = sp;
                script_path = sp;
            } else |_| {}
            lua_vm.loadScript(script_path);
            if (script_alloc) |buf| std.heap.page_allocator.free(buf);
            state.use_ecs_render = true;
        }
    }
}

pub fn setPipelinesAndSamplers() void {
    // samplers
    const samplers = pipeline.makeSpriteSamplers();
    state.spr_sampler_nearest = samplers.nearest;
    state.spr_sampler_linear = samplers.linear;
    state.sprite_linear = true;
    state.bind.samplers[spr.SMP_smp] = state.spr_sampler_linear;

    // pipelines
    const base_layout = pipeline.makeSpriteVertexLayout(Vertex);
    const pipes = pipeline.make(base_layout);
    state.pip_direct = pipes.pip_direct;
    state.pip_smooth = pipes.pip_smooth;

    // pass action
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 },
    };
}

pub fn frame() void {
    // begin pass and select pipeline
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(if (state.smooth_filter) state.pip_smooth else state.pip_direct);

    // viewport from aspect
    const ww: i32 = sapp.width();
    const wh: i32 = sapp.height();
    const vw: f32 = @as(f32, @floatFromInt(state.virtual_w));
    const vh: f32 = @as(f32, @floatFromInt(state.virtual_h));
    const win_w_f: f32 = @as(f32, @floatFromInt(ww));
    const win_h_f: f32 = @as(f32, @floatFromInt(wh));
    const scale_letterbox: f32 = @min(win_w_f / vw, win_h_f / vh);
    var vp_x: i32 = 0;
    var vp_y: i32 = 0;
    var vp_w: i32 = ww;
    var vp_h: i32 = wh;

    switch (state.aspect_mode) {
        .letterbox => {
            const view_w: i32 = @intFromFloat(@round(vw * scale_letterbox));
            const view_h: i32 = @intFromFloat(@round(vh * scale_letterbox));
            const off_x: i32 = @divTrunc(ww - view_w, 2);
            const off_y: i32 = @divTrunc(wh - view_h, 2);
            vp_x = off_x;
            vp_y = off_y;
            vp_w = view_w;
            vp_h = view_h;
            sg.applyViewport(vp_x, vp_y, vp_w, vp_h, true);
        },
        .stretch => sg.applyViewport(0, 0, ww, wh, true),
        .crop, .fit_width, .fit_height => sg.applyViewport(0, 0, ww, wh, true),
    }

    // dt and camera
    const dt_real: f64 = sapp.frameDuration();
    const dt_scale_cam: f32 = @as(f32, @floatCast(dt_real)) * 60.0;
    state.cam.update(dt_scale_cam, state.virtual_w, state.virtual_h);

    // Lua scripting update
    lua_vm.callUpdate(@as(f32, @floatCast(dt_real)));

    if (state.spr_renderer) |*renderer| {
        // ECS path: render system handles begin/uniforms/flush
        if (state.use_ecs_render and state.world != null and state.render_sys != null) {
            state.render_sys.?.run(&state.world.?, &state.cam, state.virtual_w, state.virtual_h);
        } else {
            // If ECS not ready yet, do nothing (no legacy game path)
            _ = renderer; // silence unused var in this branch
        }
    }

    // Test text rendering (no Lua yet): draw in full virtual canvas space
    if (state.txt_renderer) |*tr| {
        if (state.font) |*fnt| {
            // apply full-virtual ortho for UI-space text
            var vs_params: spr.VsParams = makeFullVirtualOrtho();
            sg.applyUniforms(spr.UB_vs_params, sg.asRange(&vs_params));
            tr.begin();
            // white text
            const white: u32 = 0xFFFFFFFF;
            // snap to integer pixels to avoid subpixel blur
            const tx: f32 = std.math.floor(8.0);
            const ty: f32 = std.math.floor(144.0);
            tr.drawText(fnt, tx, ty, white, "Hello Font!");
            // temporarily switch to nearest sampler for crisper text
            const prev_sampler = state.bind.samplers[spr.SMP_smp];
            state.bind.samplers[spr.SMP_smp] = state.spr_sampler_nearest;
            tr.flush(&state.bind);
            // restore previous sampler state
            state.bind.samplers[spr.SMP_smp] = prev_sampler;
        }
    }

    // overlay (minimal)
    if (state.overlay_visible) {
        sdtx.canvas(sapp.widthf() * 0.5, sapp.heightf() * 0.5);
        sdtx.origin(0.5, 0.5);
        sdtx.home();
        sdtx.color3b(0xff, 0xff, 0xff);

        const dt2 = sapp.frameDuration();
        const fps_est2: f32 = if (dt2 > 0) @as(f32, @floatCast(1.0 / dt2)) else 0.0;
        var sprites: usize = 0;
        var cap: usize = 0;
        var tex_batches: usize = 0; // batches split by texture
        var draw_calls: usize = 0; // actual sg.draw invocations
        if (state.spr_renderer) |*rptr| {
            sprites = rptr.sprite_count;
            cap = if (rptr.index_capacity_sprites == 0) 16383 else rptr.index_capacity_sprites;
            tex_batches = rptr.batches.items.len;
            var bi: usize = 0;
            while (bi < rptr.batches.items.len) : (bi += 1) {
                const cnt = rptr.batches.items[bi].count;
                draw_calls += (cnt + cap - 1) / cap;
            }
        }
        const aspect_str: []const u8 = switch (state.aspect_mode) {
            .letterbox => "letterbox",
            .stretch => "stretch",
            .crop => "crop",
            .fit_width => "fit_width",
            .fit_height => "fit_height",
        };

        var buf: [256:0]u8 = undefined;
        _ = std.fmt.bufPrintZ(&buf, "fps: {d:.1}\n" ++
            "sprites: {d}\n" ++
            "texture-batches: {d}\n" ++
            "draw-calls: {d} (cap/draw: {d})\n" ++
            "aspect: {s}\n", .{ fps_est2, sprites, tex_batches, draw_calls, cap, aspect_str }) catch {};
        sdtx.puts(&buf);
        sdtx.draw();
    }

    sg.endPass();
    sg.commit();
}

pub fn event(ev: *const sapp.Event) void {
    switch (ev.type) {
        .MOUSE_DOWN => {
            const v = windowToVirtual(ev.mouse_x, ev.mouse_y);
            lua_vm.callOnInput(.{ .t = .mouse_down, .x = v.x, .y = v.y, .mouse_button = @intFromEnum(ev.mouse_button) });
            switch (ev.mouse_button) {
                .LEFT => {
                    state.cam.startDrag(v.x, v.y);
                },
                else => {},
            }
        },
        .MOUSE_MOVE => {
            const v = windowToVirtual(ev.mouse_x, ev.mouse_y);
            if (state.cam.dragging) {
                state.cam.dragTo(v.x, v.y, state.virtual_w, state.virtual_h);
            }
            lua_vm.callOnInput(.{ .t = .mouse_move, .x = v.x, .y = v.y });
        },
        .MOUSE_UP => {
            const v = windowToVirtual(ev.mouse_x, ev.mouse_y);
            lua_vm.callOnInput(.{ .t = .mouse_up, .x = v.x, .y = v.y, .mouse_button = @intFromEnum(ev.mouse_button) });
            switch (ev.mouse_button) {
                .LEFT => state.cam.endDrag(),
                else => {},
            }
        },
        .KEY_DOWN => {
            lua_vm.callOnInput(.{ .t = .key_down, .key_code = @intFromEnum(ev.key_code) });
            switch (ev.key_code) {
                .T => {
                    lua_vm.callOnMessage("ping", "{\"from\":\"engine\"}");
                },
                .H => state.overlay_visible = !state.overlay_visible,
                .J => state.cam.left = true,
                .L => state.cam.right = true,
                .I => state.cam.up = true,
                .O => state.cam.down = true,
                .LEFT => state.key_left = true,
                .RIGHT => state.key_right = true,
                .UP => state.key_up = true,
                .DOWN => state.key_down = true,
                .EQUAL => state.cam.zoomBy(1.1),
                .MINUS => state.cam.zoomBy(1.0 / 1.1),
                .R => {
                    state.sprite_linear = !state.sprite_linear;
                    state.bind.samplers[spr.SMP_smp] = if (state.sprite_linear) state.spr_sampler_linear else state.spr_sampler_nearest;
                },
                // .V removed; aspect mode now fixed at init
                .F => {
                    state.smooth_filter = !state.smooth_filter;
                    if (state.smooth_filter) {
                        state.sprite_linear = true;
                        state.bind.samplers[spr.SMP_smp] = state.spr_sampler_linear;
                    }
                },
                else => {},
            }
        },
        .KEY_UP => {
            lua_vm.callOnInput(.{ .t = .key_up, .key_code = @intFromEnum(ev.key_code) });
            switch (ev.key_code) {
                .J => state.cam.left = false,
                .L => state.cam.right = false,
                .I => state.cam.up = false,
                .O => state.cam.down = false,
                .LEFT => state.key_left = false,
                .RIGHT => state.key_right = false,
                .UP => state.key_up = false,
                .DOWN => state.key_down = false,
                else => {},
            }
        },
        else => {},
    }
}

pub fn shutdown() void {
    // Notify Lua script of shutdown
    lua_vm.callFinal();
    if (state.render_sys) |*rs| {
        rs.deinit();
        state.render_sys = null;
    }
    if (state.txt_renderer) |*tr| {
        tr.deinit();
        state.txt_renderer = null;
    }
    if (state.extra_atlases) |*list| {
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            tex.atlasDeinit(std.heap.page_allocator, &list.items[i]);
        }
        list.deinit();
        state.extra_atlases = null;
    }
    if (state.spr_renderer) |*r| {
        r.deinit();
        state.spr_renderer = null;
    }
    if (state.font) |*f| {
        f.deinit();
        state.font = null;
    }
    if (state.atlas) |*a| {
        tex.atlasDeinit(std.heap.page_allocator, a);
        state.atlas = null;
    }
    if (state.world) |*w| {
        w.deinit();
        state.world = null;
    }
    lua_vm.shutdown();
}

pub fn loadAndRegisterAtlas(atlas_path: []const u8) void {
    const allocator = std.heap.page_allocator;
    const atlas = tex.loadAtlas(allocator, atlas_path) catch |e| blk: {
        std.log.warn("failed to load extra atlas: {any} {s}", .{ e, atlas_path });
        break :blk null;
    };
    if (atlas) |a| {
        if (state.spr_renderer) |*r| {
            _ = r.registerAtlas(&a);
        }
        if (state.extra_atlases == null) {
            state.extra_atlases = std.ArrayList(tex.Atlas).init(allocator);
        }
        _ = state.extra_atlases.?.append(a) catch {};
    }
}

fn windowToVirtual(mx: f32, my: f32) struct { x: f32, y: f32 } {
    const vw: f32 = @as(f32, @floatFromInt(state.virtual_w));
    const vh: f32 = @as(f32, @floatFromInt(state.virtual_h));
    const ww: i32 = sapp.width();
    const wh: i32 = sapp.height();
    const ww_f: f32 = @as(f32, @floatFromInt(ww));
    const wh_f: f32 = @as(f32, @floatFromInt(wh));
    const scale_letterbox: f32 = @min(ww_f / vw, wh_f / vh);
    const scale_crop: f32 = @max(ww_f / vw, wh_f / vh);
    switch (state.aspect_mode) {
        .letterbox => {
            const view_w: f32 = @round(vw * scale_letterbox);
            const view_h: f32 = @round(vh * scale_letterbox);
            const off_x: f32 = (ww_f - view_w) * 0.5;
            const off_y: f32 = (wh_f - view_h) * 0.5;
            return .{ .x = (mx - off_x) / scale_letterbox, .y = (my - off_y) / scale_letterbox };
        },
        .stretch => {
            const sx: f32 = ww_f / vw;
            const sy: f32 = wh_f / vh;
            return .{ .x = mx / sx, .y = my / sy };
        },
        .crop => {
            const view_w: f32 = vw * scale_crop;
            const view_h: f32 = vh * scale_crop;
            const off_x: f32 = (ww_f - view_w) * 0.5;
            const off_y: f32 = (wh_f - view_h) * 0.5;
            return .{ .x = (mx - off_x) / scale_crop, .y = (my - off_y) / scale_crop };
        },
        .fit_width => {
            const s: f32 = ww_f / vw;
            return .{ .x = mx / s, .y = my / s };
        },
        .fit_height => {
            const s: f32 = wh_f / vh;
            return .{ .x = mx / s, .y = my / s };
        },
    }
}

fn makeViewOrtho(ox: f32, oy: f32, vw: f32, vh: f32) spr.VsParams {
    const left: f32 = ox;
    const right: f32 = ox + vw;
    const top: f32 = oy;
    const bottom: f32 = oy + vh;
    const proj = mat4.ortho(left, right, bottom, top, -1.0, 1.0);
    return spr.VsParams{ .mvp = proj };
}

fn makeCameraOrtho() spr.VsParams {
    const proj = state.cam.getOrtho(state.virtual_w, state.virtual_h);
    return spr.VsParams{ .mvp = proj };
}

fn makeFullVirtualOrtho() spr.VsParams {
    const w: f32 = @as(f32, @floatFromInt(state.virtual_w));
    const h: f32 = @as(f32, @floatFromInt(state.virtual_h));
    const proj = mat4.ortho(0.0, w, h, 0.0, -1.0, 1.0);
    return spr.VsParams{ .mvp = proj };
}
