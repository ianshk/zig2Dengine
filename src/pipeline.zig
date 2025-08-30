const sg = @import("sokol").gfx;
const sapp = @import("sokol").app;
const spr = @import("shaders/sprite_shader-shader.zig");
const spr_smooth = @import("shaders/sprite_smooth-shader.zig");

pub const Pipelines = struct {
    pip_direct: sg.Pipeline = .{},
    pip_smooth: sg.Pipeline = .{},
};

pub const SpriteSamplers = struct {
    nearest: sg.Sampler = .{},
    linear: sg.Sampler = .{},
};

// Create default samplers used by the sprite renderer.
pub fn makeSpriteSamplers() SpriteSamplers {
    const nearest = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
    const linear = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
    return .{ .nearest = nearest, .linear = linear };
}

// Standard vertex layout used by the sprite renderer.
pub fn makeSpriteVertexLayout(comptime Vertex: type) sg.VertexLayoutState {
    var l = sg.VertexLayoutState{};
    l.buffers[0].stride = @sizeOf(Vertex);
    // Attribute locations expected by both shaders: 0=pos, 1=texcoord0, 2=color0
    l.attrs[0] = .{ .format = .FLOAT3, .offset = 0 };
    l.attrs[2] = .{ .format = .UBYTE4N, .offset = 12 };
    l.attrs[1] = .{ .format = .SHORT2N, .offset = 16 };
    return l;
}

pub fn make(base_layout: sg.VertexLayoutState) Pipelines {
    // shaders
    const shd = sg.makeShader(spr.spriteShaderDesc(sg.queryBackend()));
    const shd_s = sg.makeShader(spr_smooth.spriteSmoothShaderDesc(sg.queryBackend()));

    // swapchain info
    const swap_color: sg.PixelFormat = @enumFromInt(sapp.colorFormat());
    const swap_depth: sg.PixelFormat = @enumFromInt(sapp.depthFormat());
    const swap_samples: i32 = sapp.sampleCount();

    // common color state with alpha blending enabled
    var colors_dir = [_]sg.ColorTargetState{.{}} ** 4;
    colors_dir[0].pixel_format = swap_color;
    colors_dir[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .op_rgb = .ADD,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        .op_alpha = .ADD,
    };

    const colors_smooth = colors_dir; // same blending

    var out = Pipelines{};
    out.pip_direct = sg.makePipeline(.{
        .shader = shd,
        .layout = base_layout,
        .index_type = .UINT16,
        .depth = .{ .pixel_format = swap_depth, .compare = .ALWAYS, .write_enabled = false },
        .cull_mode = .NONE,
        .color_count = 1,
        .colors = colors_dir,
        .sample_count = swap_samples,
    });

    out.pip_smooth = sg.makePipeline(.{
        .shader = shd_s,
        .layout = base_layout,
        .index_type = .UINT16,
        .depth = .{ .pixel_format = swap_depth, .compare = .ALWAYS, .write_enabled = false },
        .cull_mode = .NONE,
        .color_count = 1,
        .colors = colors_smooth,
        .sample_count = swap_samples,
    });

    return out;
}
