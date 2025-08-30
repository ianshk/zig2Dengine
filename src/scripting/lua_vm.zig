const std = @import("std");
const world_mod = @import("../world.zig");
const tcomp = @import("../components/transform.zig");
const scomp = @import("../components/sprite.zig");
const sprite_mod = @import("../sprite.zig");
const engine = @import("../engine.zig");
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

// Minimal, no-op Lua VM scaffold with real ECS bindings.

pub const ActionType = enum { mouse_down, mouse_move, mouse_up, key_down, key_up };

pub const Action = struct {
    t: ActionType,
    // virtual-space coordinates (already converted by engine)
    x: f32 = 0,
    y: f32 = 0,
    // key/mouse payload (optional)
    key_code: i32 = 0,
    mouse_button: i32 = 0,
};

pub const Context = struct {
    world: *world_mod.World,
    renderer: *sprite_mod.SpriteRenderer,
};

var g_inited: bool = false;
var g_ctx: ?Context = null;
var g_L: ?*c.lua_State = null;
var g_script_ref: c_int = c.LUA_NOREF;
// simple debug harness to exercise bindings before real Lua
var g_debug_example: bool = false;
var dbg_id: u32 = 0;
var dbg_t: f32 = 0.0;

// Batching support removed to simplify engine API.

pub fn setContext(ctx: Context) void {
    g_ctx = ctx;
}

fn l_go_set_z(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id = expectInteger(st, 1);
    const z = @as(f32, @floatCast(expectNumber(st, 2)));
    go_set_z(id, z);
    return 0;
}

fn l_go_get_z(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id = expectInteger(st, 1);
    const z = go_get_z(id);
    c.lua_pushnumber(st, z);
    return 1;
}

// No-op: batch API removed.

fn l_go_set_xy(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id = expectInteger(st, 1);
    const x = @as(f32, @floatCast(expectNumber(st, 2)));
    const y = @as(f32, @floatCast(expectNumber(st, 3)));
    go_set_xy(id, x, y);
    return 0;
}

fn l_go_delete(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id = expectInteger(st, 1);
    go_delete(id);
    return 0;
}

pub fn callOnMessage(message_id: []const u8, data_json: []const u8) void {
    if (!g_inited) return;
    if (g_L) |L| {
        if (g_script_ref != c.LUA_NOREF) {
            _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, g_script_ref); // self
            _ = c.lua_getfield(L, -1, "on_message");
            if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
                c.lua_pushvalue(L, -2); // self
                _ = c.lua_pushlstring(L, message_id.ptr, message_id.len);
                _ = c.lua_pushlstring(L, data_json.ptr, data_json.len);
                if (c.lua_pcallk(L, 3, 0, 0, 0, null) != 0) {
                    var l4: usize = 0;
                    const msg = c.lua_tolstring(L, -1, &l4);
                    std.log.err("lua_vm: on_message error: {s}", .{msg});
                    c.lua_pop(L, 1);
                }
                c.lua_pop(L, 1);
            } else {
                c.lua_pop(L, 2);
            }
        }
    }
}

pub fn callFinal() void {
    if (!g_inited) return;
    if (g_L) |L| {
        if (g_script_ref != c.LUA_NOREF) {
            _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, g_script_ref);
            _ = c.lua_getfield(L, -1, "final");
            if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
                c.lua_pushvalue(L, -2); // self
                if (c.lua_pcallk(L, 1, 0, 0, 0, null) != 0) {
                    var l4: usize = 0;
                    const msg = c.lua_tolstring(L, -1, &l4);
                    std.log.err("lua_vm: final error: {s}", .{msg});
                    c.lua_pop(L, 1);
                }
                c.lua_pop(L, 1);
            } else {
                c.lua_pop(L, 2);
            }
        }
    }
}

pub fn init() void {
    if (g_inited) return;
    g_inited = true;
    const L_opt = c.luaL_newstate();
    if (L_opt == null) {
        std.log.err("lua_vm: failed to create Lua state", .{});
        return;
    }
    const L = L_opt.?;
    c.luaL_openlibs(L);
    g_L = L;

    registerBindings(L);

    std.log.info("lua_vm: init", .{});
}

pub fn shutdown() void {
    if (!g_inited) return;
    if (g_L) |L| {
        // release script ref if any
        if (g_script_ref != c.LUA_NOREF) {
            c.luaL_unref(L, c.LUA_REGISTRYINDEX, g_script_ref);
            g_script_ref = c.LUA_NOREF;
        }
        c.lua_close(L);
    }
    g_L = null;
    // batches removed
    g_inited = false;
    g_ctx = null;
    std.log.info("lua_vm: shutdown", .{});
}

pub fn loadScript(path: []const u8) void {
    if (!g_inited) return;
    if (g_L) |L| {
        // Read file into memory and load as chunk
        const file_buf = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 10 * 1024 * 1024) catch |e| {
            std.log.err("lua_vm: failed to read script '{s}': {s}", .{ path, @errorName(e) });
            return;
        };
        defer std.heap.page_allocator.free(file_buf);
        // name (chunkname) for errors: must be NUL-terminated for C API
        const namez_opt: ?[]u8 = std.heap.page_allocator.dupeZ(u8, path) catch null;
        defer if (namez_opt) |nz| std.heap.page_allocator.free(nz);
        const name_cstr: [*c]const u8 = if (namez_opt) |nz| nz.ptr else "script";
        if (c.luaL_loadbufferx(L, file_buf.ptr, @intCast(file_buf.len), name_cstr, null) != 0) {
            // error on stack
            var l: usize = 0;
            const msg = c.lua_tolstring(L, -1, &l);
            std.log.err("lua_vm: load error: {s}", .{msg});
            c.lua_pop(L, 1);
            return;
        }
        // call chunk expecting it to return a table (the module/self)
        if (c.lua_pcallk(L, 0, 1, 0, 0, null) != 0) {
            var l2: usize = 0;
            const msg2 = c.lua_tolstring(L, -1, &l2);
            std.log.err("lua_vm: runtime error: {s}", .{msg2});
            c.lua_pop(L, 1);
            return;
        }
        // Replace previous script ref
        if (g_script_ref != c.LUA_NOREF) {
            c.luaL_unref(L, c.LUA_REGISTRYINDEX, g_script_ref);
            g_script_ref = c.LUA_NOREF;
        }
        g_script_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
        std.log.info("lua_vm: loaded script {s}", .{path});

        // Call init(self) if present
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, g_script_ref); // push self table
        _ = c.lua_getfield(L, -1, "init");
        if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
            c.lua_pushvalue(L, -2); // self
            if (c.lua_pcallk(L, 1, 0, 0, 0, null) != 0) {
                var l3: usize = 0;
                const msg3 = c.lua_tolstring(L, -1, &l3);
                std.log.err("lua_vm: init error: {s}", .{msg3});
                c.lua_pop(L, 1);
            }
            // pop self table
            c.lua_pop(L, 1);
        } else {
            // pop non-function and self table
            c.lua_pop(L, 2);
        }
    }
}

pub fn callUpdate(dt: f32) void {
    if (!g_inited) return;
    if (g_L) |L| {
        if (g_script_ref != c.LUA_NOREF) {
            _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, g_script_ref); // self
            _ = c.lua_getfield(L, -1, "update");
            if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
                c.lua_pushvalue(L, -2); // self
                c.lua_pushnumber(L, dt);
                if (c.lua_pcallk(L, 2, 0, 0, 0, null) != 0) {
                    var l3: usize = 0;
                    const msg = c.lua_tolstring(L, -1, &l3);
                    std.log.err("lua_vm: update error: {s}", .{msg});
                    c.lua_pop(L, 1);
                }
                // pop self table
                c.lua_pop(L, 1);
            } else {
                // pop non-function and self
                c.lua_pop(L, 2);
            }
        }
    }
    if (g_debug_example) {
        if (dbg_id == 0) {
            // spawn once
            dbg_id = go_create();
            // default position
            go_add_transform(dbg_id, 120, 90, 0, 1, 1);
            // try a known frame name from the atlas
            go_add_sprite(dbg_id, "_0001_Layer-2.png", 0xFFFFFFFF);
        }
        // animate in a small circle
        dbg_t += dt;
        const r: f32 = 20.0;
        const x: f32 = 120.0 + @cos(dbg_t) * r;
        const y: f32 = 90.0 + @sin(dbg_t) * r;
        go_set(dbg_id, "transform", "x", x);
        go_set(dbg_id, "transform", "y", y);
    }
}

pub fn callOnInput(action: Action) void {
    if (!g_inited) return;
    if (g_L) |L| {
        if (g_script_ref != c.LUA_NOREF) {
            _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, g_script_ref); // self
            _ = c.lua_getfield(L, -1, "on_input");
            if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
                // arguments: (self, t_str, x, y, key_code, mouse_button)
                const t_str = switch (action.t) {
                    .mouse_down => "mouse_down",
                    .mouse_move => "mouse_move",
                    .mouse_up => "mouse_up",
                    .key_down => "key_down",
                    .key_up => "key_up",
                };
                c.lua_pushvalue(L, -2); // self
                _ = c.lua_pushlstring(L, t_str, t_str.len);
                c.lua_pushnumber(L, action.x);
                c.lua_pushnumber(L, action.y);
                c.lua_pushinteger(L, @as(c.lua_Integer, action.key_code));
                c.lua_pushinteger(L, @as(c.lua_Integer, action.mouse_button));
                if (c.lua_pcallk(L, 6, 0, 0, 0, null) != 0) {
                    var l4: usize = 0;
                    const msg = c.lua_tolstring(L, -1, &l4);
                    std.log.err("lua_vm: on_input error: {s}", .{msg});
                    c.lua_pop(L, 1);
                }
                // pop self table
                c.lua_pop(L, 1);
            } else {
                // pop non-function and self
                c.lua_pop(L, 2);
            }
        }
    }
}

// --- Lua native binding registration ---
fn registerBindings(L: *c.lua_State) void {
    // go table
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_go_create);
    c.lua_setfield(L, -2, "create");
    c.lua_pushcfunction(L, l_go_delete);
    c.lua_setfield(L, -2, "delete");
    c.lua_pushcfunction(L, l_go_add_transform);
    c.lua_setfield(L, -2, "add_transform");
    c.lua_pushcfunction(L, l_go_add_sprite);
    c.lua_setfield(L, -2, "add_sprite");
    c.lua_pushcfunction(L, l_go_set);
    c.lua_setfield(L, -2, "set");
    c.lua_pushcfunction(L, l_go_set_xy);
    c.lua_setfield(L, -2, "set_xy");
    c.lua_pushcfunction(L, l_go_set_z);
    c.lua_setfield(L, -2, "set_z");
    c.lua_pushcfunction(L, l_go_get_z);
    c.lua_setfield(L, -2, "get_z");
    // batch-related bindings removed
    c.lua_setglobal(L, "go");

    // msg table
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_msg_post);
    c.lua_setfield(L, -2, "post");
    c.lua_setglobal(L, "msg");

    // display table
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_display_set_virtual_resolution);
    c.lua_setfield(L, -2, "set_virtual_resolution");
    c.lua_pushcfunction(L, l_display_set_aspect_mode);
    c.lua_setfield(L, -2, "set_aspect_mode");
    c.lua_setglobal(L, "display");
}

// Helpers to read Lua args safely (minimal checks for now)
fn expectNumber(L: *c.lua_State, idx: c_int) f64 {
    return c.lua_tonumberx(L, idx, null);
}
fn expectInteger(L: *c.lua_State, idx: c_int) u32 {
    return @intCast(c.lua_tointegerx(L, idx, null));
}
fn expectString(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const p = c.lua_tolstring(L, idx, &len);
    if (p == null) return &[_]u8{};
    return p[0..len];
}

// C callbacks
fn l_go_create(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id: u32 = go_create();
    c.lua_pushinteger(st, @as(c.lua_Integer, id));
    return 1;
}

fn l_go_add_transform(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id = expectInteger(st, 1);
    const x = @as(f32, @floatCast(expectNumber(st, 2)));
    const y = @as(f32, @floatCast(expectNumber(st, 3)));
    const rot = @as(f32, @floatCast(expectNumber(st, 4)));
    const sx = @as(f32, @floatCast(expectNumber(st, 5)));
    const sy = @as(f32, @floatCast(expectNumber(st, 6)));
    go_add_transform(id, x, y, rot, sx, sy);
    return 0;
}

fn l_go_add_sprite(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id = expectInteger(st, 1);
    const frame_name = expectString(st, 2);
    const color: u32 = @intCast(expectInteger(st, 3));
    go_add_sprite(id, frame_name, color);
    return 0;
}

// batch API removed

// batch API removed

fn l_go_set(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id = expectInteger(st, 1);
    const component = expectString(st, 2);
    const field = expectString(st, 3);
    const value = @as(f32, @floatCast(expectNumber(st, 4)));
    go_set(id, component, field, value);
    return 0;
}

fn l_msg_post(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const id = expectInteger(st, 1);
    const msg_id = expectString(st, 2);
    const data = expectString(st, 3);
    msg_post(id, msg_id, data);
    return 0;
}

// display.* bindings: control virtual canvas and aspect
fn l_display_set_virtual_resolution(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const w = @as(i32, @intCast(expectInteger(st, 1)));
    const h = @as(i32, @intCast(expectInteger(st, 2)));
    engine.setVirtualResolution(w, h);
    return 0;
}

fn l_display_set_aspect_mode(L: ?*c.lua_State) callconv(.C) c_int {
    const st = L.?;
    const mode_str = expectString(st, 1);
    var mode: engine.AspectMode = .letterbox;
    if (std.mem.eql(u8, mode_str, "letterbox")) {
        mode = .letterbox;
    } else if (std.mem.eql(u8, mode_str, "stretch")) {
        mode = .stretch;
    } else if (std.mem.eql(u8, mode_str, "crop")) {
        mode = .crop;
    } else if (std.mem.eql(u8, mode_str, "fit_width")) {
        mode = .fit_width;
    } else if (std.mem.eql(u8, mode_str, "fit_height")) {
        mode = .fit_height;
    } else {
        // unknown string: keep current
        return 0;
    }
    engine.setAspectMode(mode);
    return 0;
}

// go.* bindings operating on ECS via Context
pub fn go_create() u32 {
    if (!g_inited) return 0;
    if (g_ctx) |ctx| {
        return ctx.world.createObject();
    }
    return 0;
}

pub fn go_delete(id: u32) void {
    if (!g_inited) return;
    if (g_ctx) |ctx| ctx.world.destroyObject(id);
}

pub fn go_add_transform(id: u32, x: f32, y: f32, rot: f32, sx: f32, sy: f32) void {
    if (!g_inited) return;
    if (g_ctx) |ctx| {
        ctx.world.addTransform(id, .{ .x = x, .y = y, .rot = rot, .sx = sx, .sy = sy });
    }
}

pub fn go_add_sprite(id: u32, frame_name: []const u8, color_rgba: u32) void {
    if (!g_inited) return;
    if (g_ctx) |ctx| {
        const frame_id: usize = ctx.renderer.getIdByName(frame_name) orelse 0;
        ctx.world.addSprite(id, .{ .frame_id = frame_id, .color = color_rgba });
    }
}

// Minimal setter for transform fields
pub fn go_set(id: u32, component: []const u8, field: []const u8, value: f32) void {
    if (!g_inited) return;
    if (g_ctx) |ctx| {
        if (std.mem.eql(u8, component, "transform")) {
            if (ctx.world.getTransform(id)) |t| {
                if (std.mem.eql(u8, field, "x")) t.x = value else if (std.mem.eql(u8, field, "y")) t.y = value else if (std.mem.eql(u8, field, "rot") or std.mem.eql(u8, field, "rotation")) t.rot = value else if (std.mem.eql(u8, field, "sx")) t.sx = value else if (std.mem.eql(u8, field, "sy")) t.sy = value else {}
            }
        } else if (std.mem.eql(u8, component, "sprite")) {
            if (ctx.world.getSprite(id)) |s| {
                if (std.mem.eql(u8, field, "z")) s.z = value;
            }
        }
    }
}

pub fn go_set_xy(id: u32, x: f32, y: f32) void {
    if (!g_inited) return;
    if (g_ctx) |ctx| {
        if (ctx.world.getTransform(id)) |t| {
            t.x = x;
            t.y = y;
        }
    }
}

pub fn go_set_z(id: u32, z: f32) void {
    if (!g_inited) return;
    if (g_ctx) |ctx| {
        if (ctx.world.getSprite(id)) |s| {
            s.z = z;
        }
    }
}

pub fn go_get_z(id: u32) f32 {
    if (!g_inited) return 0;
    if (g_ctx) |ctx| {
        if (ctx.world.getSprite(id)) |s| {
            return s.z;
        }
    }
    return 0;
}

pub fn msg_post(id: u32, message_id: []const u8, data_json: []const u8) void {
    _ = id; // entity routing TBD; for now deliver to the single loaded script
    callOnMessage(message_id, data_json);
}
