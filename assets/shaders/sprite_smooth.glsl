// Smooth pixel filtering variant using derivative-aware UV biasing
// Sokol '#pragma sokol' shader format, compatible with existing vertex layout
// Idea from here: https://github.com/CptPotato/GodotThings/tree/master/SmoothPixelFiltering
#pragma sokol @header const m = @import("math.zig")
#pragma sokol @ctype mat4 m.Mat4

#pragma sokol @vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};

in vec4 pos;
in vec2 texcoord0;
in vec4 color0;

out vec2 uv;
out vec4 color;

void main() {
    gl_Position = mvp * pos;
    uv = texcoord0;
    color = color0;
}
#pragma sokol @end

#pragma sokol @fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

in vec2 uv;
in vec4 color;
out vec4 frag_color;

// Exact port of Godot's derivative-aware point smooth filtering
vec4 texturePointSmooth(vec2 in_uv, vec2 pixel_size)
{
    vec2 ddx = dFdx(in_uv);
    vec2 ddy = dFdy(in_uv);
    vec2 lxy = sqrt(ddx * ddx + ddy * ddy);

    vec2 uv_pixels = in_uv / pixel_size;

    vec2 uv_pixels_floor = round(uv_pixels) - vec2(0.5);
    vec2 uv_dxy_pixels = uv_pixels - uv_pixels_floor;

    uv_dxy_pixels = clamp((uv_dxy_pixels - vec2(0.5)) * pixel_size / lxy + vec2(0.5), 0.0, 1.0);

    vec2 base_uv = uv_pixels_floor * pixel_size;

    return textureGrad(sampler2D(tex, smp), base_uv + uv_dxy_pixels * pixel_size, ddx, ddy);
}

void main() {
    ivec2 isz = textureSize(sampler2D(tex, smp), 0);
    vec2 pixel_size = 1.0 / vec2(isz);
    vec4 tex_color = texturePointSmooth(uv, pixel_size);
    frag_color = tex_color * color;
}
#pragma sokol @end

#pragma sokol @program sprite_smooth vs fs
