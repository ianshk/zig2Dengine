const std = @import("std");

pub const Transform = struct {
    x: f32 = 0,
    y: f32 = 0,
    rot: f32 = 0, // radians
    sx: f32 = 1,
    sy: f32 = 1,
    z: i16 = 0, // draw order hint (optional)
    enabled: bool = true,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    ids: std.ArrayList(u32),
    items: std.ArrayList(Transform),
    index_of_id: std.AutoHashMap(u32, usize),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .ids = std.ArrayList(u32).init(allocator),
            .items = std.ArrayList(Transform).init(allocator),
            .index_of_id = std.AutoHashMap(u32, usize).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        self.ids.deinit();
        self.items.deinit();
        self.index_of_id.deinit();
    }

    pub fn add(self: *Store, id: u32, t: Transform) void {
        // Append and index
        self.ids.append(id) catch {};
        self.items.append(t) catch {};
        const idx: usize = self.items.items.len - 1;
        self.index_of_id.put(id, idx) catch {};
    }

    pub fn remove(self: *Store, id: u32) void {
        if (self.index_of_id.get(id)) |idx| {
            const last_index: usize = self.items.items.len - 1;
            if (idx != last_index) {
                // Move last into idx slot
                const moved_id = self.ids.items[last_index];
                self.ids.items[idx] = moved_id;
                self.items.items[idx] = self.items.items[last_index];
                // Update index for moved id
                self.index_of_id.put(moved_id, idx) catch {};
            }
            _ = self.ids.pop();
            _ = self.items.pop();
            _ = self.index_of_id.remove(id);
        }
    }

    pub fn getPtr(self: *Store, id: u32) ?*Transform {
        if (self.index_of_id.get(id)) |idx| {
            return &self.items.items[idx];
        }
        return null;
    }

    pub const Iter = struct {
        ids: []const u32,
        items: []Transform,
        i: usize = 0,
        pub fn next(it: *Iter) ?struct { u32, *Transform } {
            if (it.i >= it.items.len) return null;
            const idx = it.i;
            it.i += 1;
            return .{ it.ids[idx], &it.items[idx] };
        }
    };

    pub fn iter(self: *Store) Iter {
        return .{ .ids = self.ids.items, .items = self.items.items, .i = 0 };
    }
};
