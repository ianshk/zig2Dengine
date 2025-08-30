const std = @import("std");
const tcomp = @import("components/transform.zig");
const scomp = @import("components/sprite.zig");

pub const ObjectId = u32;

pub const World = struct {
    allocator: std.mem.Allocator,

    // Simple ID generator
    next_id: ObjectId = 1,

    // Component stores
    transforms: tcomp.Store,
    sprites: scomp.Store,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .transforms = tcomp.Store.init(allocator),
            .sprites = scomp.Store.init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        self.transforms.deinit();
        self.sprites.deinit();
    }

    // Objects
    pub fn createObject(self: *World) ObjectId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn destroyObject(self: *World, id: ObjectId) void {
        // remove attached components if any
        self.transforms.remove(id);
        self.sprites.remove(id);
    }

    // Components: Transform
    pub fn addTransform(self: *World, id: ObjectId, t: tcomp.Transform) void {
        self.transforms.add(id, t);
    }

    pub fn getTransform(self: *World, id: ObjectId) ?*tcomp.Transform {
        return self.transforms.getPtr(id);
    }

    pub fn removeTransform(self: *World, id: ObjectId) void {
        self.transforms.remove(id);
    }

    // Components: Sprite
    pub fn addSprite(self: *World, id: ObjectId, s: scomp.Sprite) void {
        self.sprites.add(id, s);
    }

    pub fn getSprite(self: *World, id: ObjectId) ?*scomp.Sprite {
        return self.sprites.getPtr(id);
    }

    pub fn removeSprite(self: *World, id: ObjectId) void {
        self.sprites.remove(id);
    }
};
