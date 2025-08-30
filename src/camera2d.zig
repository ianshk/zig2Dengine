const std = @import("std");
const mat4 = @import("math.zig").Mat4;

pub const Camera2D = struct {
    // top-left world position of the visible area
    x: f32 = 0.0,
    y: f32 = 0.0,
    // zoom: 1 shows full virtual size, >1 zooms in
    zoom: f32 = 1.0,

    // input flags (set by app)
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,

    // config
    min_zoom: f32 = 0.25,
    max_zoom: f32 = 4.0,
    pan_speed: f32 = 2.0, // in virtual units per update second at zoom=1

    // optional bounds in world space (inclusive min, exclusive max)
    has_bounds: bool = false,
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,

    // mouse dragging
    dragging: bool = false,
    drag_last_vx: f32 = 0.0, // last cursor position in virtual coords
    drag_last_vy: f32 = 0.0,

    pub fn init() Camera2D {
        return .{};
    }

    pub fn startDrag(self: *Camera2D, vx: f32, vy: f32) void {
        self.dragging = true;
        self.drag_last_vx = vx;
        self.drag_last_vy = vy;
    }

    pub fn dragTo(self: *Camera2D, vx: f32, vy: f32, vw: i32, vh: i32) void {
        if (!self.dragging) return;
        const dx_v = vx - self.drag_last_vx;
        const dy_v = vy - self.drag_last_vy;
        self.drag_last_vx = vx;
        self.drag_last_vy = vy;
        // convert virtual delta to world delta
        const z = @max(self.zoom, 0.001);
        self.pan(-dx_v / z, -dy_v / z, vw, vh);
    }

    pub fn endDrag(self: *Camera2D) void {
        self.dragging = false;
    }

    pub fn setBounds(self: *Camera2D, min_x: f32, min_y: f32, max_x: f32, max_y: f32) void {
        self.has_bounds = true;
        self.min_x = min_x;
        self.min_y = min_y;
        self.max_x = max_x;
        self.max_y = max_y;
        self.clampToBounds(0, 0); // no vw/vh yet; noop if over-wide
    }

    pub fn clearBounds(self: *Camera2D) void {
        self.has_bounds = false;
    }

    pub fn zoomBy(self: *Camera2D, factor: f32) void {
        const z = std.math.clamp(self.zoom * factor, self.min_zoom, self.max_zoom);
        self.zoom = z;
    }

    pub fn setZoom(self: *Camera2D, z: f32) void {
        self.zoom = std.math.clamp(z, self.min_zoom, self.max_zoom);
    }

    // Center the camera so that world point (cx,cy) is centered in view
    pub fn lookAt(self: *Camera2D, cx: f32, cy: f32, vw: i32, vh: i32) void {
        const vw_f: f32 = @floatFromInt(vw);
        const vh_f: f32 = @floatFromInt(vh);
        const vis_w: f32 = vw_f / @max(self.zoom, 0.001);
        const vis_h: f32 = vh_f / @max(self.zoom, 0.001);
        self.x = cx - vis_w * 0.5;
        self.y = cy - vis_h * 0.5;
        self.clampToBounds(vw, vh);
    }


    pub fn pan(self: *Camera2D, dx: f32, dy: f32, vw: i32, vh: i32) void {
        self.x += dx;
        self.y += dy;
        self.clampToBounds(vw, vh);
    }

    // Update from input flags; vw/vh used to keep speed feel consistent and clamp
    pub fn update(self: *Camera2D, dt: f32, vw: i32, vh: i32) void {
        const z = @max(self.zoom, 0.001);
        const speed = self.pan_speed / z; // keep feel constant as you zoom in
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (self.left) dx -= speed * dt;
        if (self.right) dx += speed * dt;
        if (self.up) dy -= speed * dt;
        if (self.down) dy += speed * dt;
        if (dx != 0 or dy != 0) self.pan(dx, dy, vw, vh);
    }

    // Build a top-left origin ortho covering the visible world rect
    pub fn getOrtho(self: *const Camera2D, vw: i32, vh: i32) mat4 {
        const vw_f: f32 = @floatFromInt(vw);
        const vh_f: f32 = @floatFromInt(vh);
        const z = @max(self.zoom, 0.001);
        const vis_w: f32 = vw_f / z;
        const vis_h: f32 = vh_f / z;
        const left = self.x;
        const top = self.y;
        const right = left + vis_w;
        const bottom = top + vis_h;
        return mat4.ortho(left, right, bottom, top, -1.0, 1.0);
    }

    // Convert world to virtual-screen coordinates (pre-viewport). Top-left origin.
    pub fn worldToVirtual(self: *const Camera2D, _vw: i32, _vh: i32, wx: f32, wy: f32) struct { x: f32, y: f32 } {
        _ = _vw; // silence unused
        _ = _vh; // silence unused
        const z = @max(self.zoom, 0.001);
        return .{ .x = (wx - self.x) * z, .y = (wy - self.y) * z };
    }

    pub fn virtualToWorld(self: *const Camera2D, _vw: i32, _vh: i32, sx: f32, sy: f32) struct { x: f32, y: f32 } {
        _ = _vw; // silence unused
        _ = _vh; // silence unused
        const z = @max(self.zoom, 0.001);
        return .{ .x = self.x + sx / z, .y = self.y + sy / z };
    }

    fn clampToBounds(self: *Camera2D, vw: i32, vh: i32) void {
        if (!self.has_bounds) return;
        const z = @max(self.zoom, 0.001);
        const vw_f: f32 = @floatFromInt(vw);
        const vh_f: f32 = @floatFromInt(vh);
        const vis_w: f32 = vw_f / z;
        const vis_h: f32 = vh_f / z;
        // Allow showing beyond bounds if world smaller than view
        const min_x = self.min_x;
        const min_y = self.min_y;
        const max_x = self.max_x - vis_w;
        const max_y = self.max_y - vis_h;
        if (max_x >= min_x) self.x = std.math.clamp(self.x, min_x, max_x);
        if (max_y >= min_y) self.y = std.math.clamp(self.y, min_y, max_y);
    }
};
