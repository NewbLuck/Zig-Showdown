const std = @import("std");
const res = @import("resource_pool.zig");

const Model = @import("resources/Model.zig");
const Texture = @import("resources/Texture.zig");

const Self = @This();

pub const usage = struct {
    pub const generic_render: u32 = 1;
    pub const menu_render: u32 = 2;
    pub const level_render: u32 = 4;
    pub const debug_draw: u32 = 0x80000000;
};

pub const TexturePool = res.ResourcePool(Texture, Texture.loadFromMemory, Texture.deinit);
pub const ModelPool = res.ResourcePool(Model, Model.loadFromMemory, Model.deinit);

textures: TexturePool,
models: ModelPool,

pub fn init(allocator: *std.mem.Allocator) Self {
    return Self{
        .textures = TexturePool.init(allocator),
        .models = ModelPool.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.textures.deinit();
    self.models.deinit();
    self.* = undefined;
}