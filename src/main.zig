const std = @import("std");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const vec3 = @import("math.zig").Vec3;
const mat4 = @import("math.zig").Mat4;
const spr = @import("shaders/sprite_shader-shader.zig");

const tex = @import("texture-atlas.zig");
const sprite = @import("sprite.zig");
const camera = @import("camera2d.zig");
const pipeline = @import("pipeline.zig");
const engine = @import("engine.zig");

const state = struct {
    var rx: f32 = 0.0;
    var ry: f32 = 0.0;
    var pass_action: sg.PassAction = .{};
    var pip_direct: sg.Pipeline = .{};
    var pip_smooth: sg.Pipeline = .{};
    var bind: sg.Bindings = .{};
    const view: mat4 = mat4.identity();
    var atlas: ?tex.Atlas = null;
    var spr_renderer: ?sprite.SpriteRenderer = null;
    var test_sprite: ?sprite.Sprite = null;

    // virtual resolution, this is set in lua now
    var virtual_w: i32 = 640;
    var virtual_h: i32 = 360; // 16:9
    // aspect handling, this is set in lua now
    var aspect_mode: engine.AspectMode = .letterbox;
    // timing
    var use_dt: bool = true; // enable delta time updates by default
    // overlay and sprite sampling filter
    var overlay_visible: bool = true;
    var sprite_linear: bool = true;
    var smooth_filter: bool = false; // when true, use smooth shader (best with linear sampling)
    var spr_sampler_nearest: sg.Sampler = .{};
    var spr_sampler_linear: sg.Sampler = .{};
    // input state for continuous movement
    var key_left: bool = false;
    var key_right: bool = false;
    var key_up: bool = false;
    var key_down: bool = false;
    // camera (world)
    var cam: camera.Camera2D = camera.Camera2D.init();
};

// a vertex struct with position, color and uv-coords
const Vertex = extern struct { x: f32, y: f32, z: f32, color: u32, u: i16, v: i16 };

// Minimal RNG helpers (deterministic, compact) for Zig 0.14 without std.rand
// fn rngNext64(seed: *u64) u64 {
//     var x = seed.*;
//     x ^= x << 13;
//     x ^= x >> 7;
//     x ^= x << 17;
//     seed.* = x;
//     return x;
// }

// moved: use engine.windowToVirtual(mx, my)

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    // setup sokol-debugtext with a builtin font
    sdtx.setup(.{
        .fonts = init: {
            var f: [8]sdtx.FontDesc = @splat(.{});
            f[0] = sdtx.fontCpc();
            break :init f;
        },
        .logger = .{ .func = slog.func },
    });

    // Initialize engine
    engine.init(state.virtual_w, state.virtual_h, state.aspect_mode);
    engine.initWorldAndRenderer();
    engine.setPipelinesAndSamplers();
    // Explicitly load one or more atlases as needed
    engine.loadAndRegisterAtlas("assets/textures/texture.json");
    engine.loadAndRegisterAtlas("assets/textures/texture2.json");
    engine.loadGameScript();
}

export fn frame() void {
    engine.frame();
}

export fn event(ev: ?*const sapp.Event) void {
    const e = ev.?;
    engine.event(e);
}

export fn cleanup() void {
    engine.shutdown();
    sdtx.shutdown();
    sg.shutdown();
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = event,
        .cleanup_cb = cleanup,
        .width = 1280,
        .height = 720,
        .sample_count = 1,
        .icon = .{ .sokol_default = true },
        .window_title = "zengine",
        .logger = .{ .func = slog.func },
    });
}
