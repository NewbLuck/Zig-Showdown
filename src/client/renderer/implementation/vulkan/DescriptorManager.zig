const std = @import("std");
const zwl = @import("zwl");
const vk = @import("vulkan");
const util = @import("util.zig");

const Context = @import("Context.zig");
const SmallBuf = util.SmallBuf;
const asManyPtr = util.asManyPtr;

const Self = @This();

//! TODO: Document this file better

// Maximum of 1024 texture descriptors.
// This needs to be kept in sync with all Vulkan shaders!
const texture_pool_size = 1024;

/// The bindings used by the entire renderer.
/// These bindings must be kept in sync with all Vulkan shaders!
// TODO: Make the texture pool size dynamic and update it through a specialization constant?
const bindings = [_]vk.DescriptorSetLayoutBinding{
    .{ // layout(binding = 0) uniform sampler texture_sampler;
        .binding = 0,
        .descriptor_type = .sampler,
        .descriptor_count = 1,
        .stage_flags = .{.vertex_bit = true, .fragment_bit = true, .compute_bit = true},
        .p_immutable_samplers = null,
    },
    .{ // layout(binding = 1) uniform texture2D textures[texture_pool_size];
        .binding = 1,
        .descriptor_type = .sampled_image,
        .descriptor_count = texture_pool_size,
        .stage_flags = .{.vertex_bit = true, .fragment_bit = true, .compute_bit = true},
        .p_immutable_samplers = null,
    },
};

const PendingUpdate = struct {
    index: u32,
    image_view: vk.ImageView,
};

const PendingUpdateQueue = std.ArrayListUnmanaged(PendingUpdate);

pool: vk.DescriptorPool,
set_layout: vk.DescriptorSetLayout,
sets: [Context.frame_overlap]vk.DescriptorSet,
pipeline_layout: vk.PipelineLayout,

free_textures: std.ArrayListUnmanaged(u32),

pending_updates: [Context.frame_overlap]PendingUpdateQueue,

// These two are stored in the struct so that we don't need to reallocate them every time
image_infos: std.ArrayListUnmanaged(vk.DescriptorImageInfo),
writes: std.ArrayListUnmanaged(vk.WriteDescriptorSet),

pub fn init(ctx: *Context) !Self {
    var self = Self{
        .pool = .null_handle,
        .set_layout = .null_handle,
        .sets = [_]vk.DescriptorSet{ .null_handle } ** Context.frame_overlap,
        .pipeline_layout = .null_handle,
        .free_textures = .{},
        .pending_updates = [_]PendingUpdateQueue{.{}} ** Context.frame_overlap,
        .image_infos = .{},
        .writes = .{},
    };
    errdefer self.deinit(ctx);

    try self.initDescriptorPool(ctx);
    try self.initDescriptorSets(ctx);
    try self.initPipelineLayout(ctx);

    try self.free_textures.resize(ctx.allocator, texture_pool_size);
    for (self.free_textures.items) |*x, i| x.* = @intCast(u32, i);

    return self;
}

pub fn deinit(self: *Self, ctx: *Context) void {
    self.image_infos.deinit(ctx.allocator);
    self.writes.deinit(ctx.allocator);

    for (self.pending_updates) |*puq| {
        puq.deinit(ctx.allocator);
    }

    ctx.device.vkd.destroyPipelineLayout(ctx.device.handle, self.pipeline_layout, null);
    // Destroying the pool frees any associated descriptor sets
    ctx.device.vkd.destroyDescriptorPool(ctx.device.handle, self.pool, null);
    self.free_textures.deinit(ctx.allocator);
    ctx.device.vkd.destroyDescriptorSetLayout(ctx.device.handle, self.set_layout, null);
}

pub fn allocateTextureDescriptor(self: *Self, ctx: *Context, image_view: vk.ImageView) !u32 {
    const index = self.free_textures.popOrNull() orelse return error.OutOfDescriptors;

    // Schedule the write for future frames
    // If the image view is destroyed in the mean time, it needs to be removed from here!
    for (self.pending_updates) |*puq| {
        try puq.append(.{.index = index, .image_view = image_view});
    }
    return index;
}

pub fn freeTextureDescriptor(self: *Self, ctx: *Context, index: u32) void {
    if (std.builtin.mode == .Debug) {
        // Make sure that the texture is not already in there
        if (std.mem.indexOfScalar(u32, self.free_textures.items, index) != null) {
            Context.log.err("Duplicate free of texture index {}", .{ index });
            return;
        } else if (index >= texture_pool_size) {
            Context.log.err("Free of invalid texture index {}", .{ index });
            return;
        }
    }

    // Remove the index if it is currently scheduled for update.
    // TODO: Do we need to remove the update for the current frame? We might need to defer
    // destruction of frame buffers until the end of the frame if the frame buffer is rendered
    // and then deleted right after.
    for (self.pending_updates) |*puq| {
        const i = for (puq.items) |pu, i| {
                if (pu.index == index) break i;
            } else continue;

        puq.swapRemove(i);
    }

    self.free_textures.appendAssumeCapacity(index);
}

pub fn bindDescriptorSet(self: *Self, ctx: *Context, cmd_buf: vk.CommandBuffer) void {
    ctx.device.vkd.cmdBindDescriptorSets(
        cmd_buf,
        .graphics,
        self.pipeline_layout,
        0,
        1,
        asManyPtr(&self.sets[ctx.frameIndex()]),
        0,
        undefined,
    );
}

pub fn processPendingUpdates(self: *Self, ctx: *Context) !void {
    const puq = &self.pending_updates[ctx.frameIndex()];
    const set = self.sets[ctx.frameIndex()];

    try self.image_infos.resize(ctx.allocator, puq.items.len);
    try self.writes.resize(ctx.allocator, puq.items.len);

    const image_infos = self.image_infos.items;
    const writes = self.writes.items;

    // TODO: Don't hardcode this
    const texture_binding = bindings[1];

    for (puq.items) |pu, i| {
        image_infos[i] = .{
            .sampler = .null_handle,
            .image_view = pu.image_view,
            // TODO: This needs to be in sync with the global render pass in ctx.
            .image_layout = .shader_read_only_optimal,
        };

        writes[i] = .{
            .dst_set = set,
            .dst_binding = texture_binding.binding,
            .dst_array_element = pu.index,
            .descriptor_count = 1,
            .descriptor_type = texture_binding.descriptor_type,
            .p_image_info = asManyPtr(&image_infos[i]),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };
    }

    ctx.device.vkd.updateDescriptorSets(
        ctx.device.handle,
        @intCast(u32, writes.len),
        writes.ptr,
        0,
        undefined,
    );

    puq.shrinkRetainingCapacity(0);
}

fn initDescriptorPool(self: *Self, ctx: *Context) !void {
    var pool_sizes = SmallBuf(bindings.len, vk.DescriptorPoolSize){};
    for (bindings) |binding| {
        for (pool_sizes.asSlice()) |*pool_size| {
            if (pool_size.@"type" == binding.descriptor_type) {
                pool_size.descriptor_count += binding.descriptor_count * Context.frame_overlap;
                break;
            }
        } else {
            pool_sizes.appendAssumeCapacity(.{
                .@"type" = binding.descriptor_type,
                .descriptor_count = binding.descriptor_count * Context.frame_overlap,
            });
        }
    }

    self.pool = try ctx.device.vkd.createDescriptorPool(ctx.device.handle, .{
        .flags = .{},
        .max_sets = Context.frame_overlap,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = &pool_sizes.items,
    }, null);
}

fn initDescriptorSets(self: *Self, ctx: *Context) !void {
    self.set_layout = try ctx.device.vkd.createDescriptorSetLayout(ctx.device.handle, .{
        .flags = .{},
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    }, null);

    var layouts: [Context.frame_overlap]vk.DescriptorSetLayout = undefined;
    std.mem.set(vk.DescriptorSetLayout, &layouts, self.set_layout);

    try ctx.device.vkd.allocateDescriptorSets(ctx.device.handle, .{
        .descriptor_pool = self.pool,
        .descriptor_set_count = layouts.len,
        .p_set_layouts = &layouts,
    }, &self.sets);
}

fn initPipelineLayout(self: *Self, ctx: *Context) !void {
    self.pipeline_layout = try ctx.device.vkd.createPipelineLayout(ctx.device.handle, .{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = asManyPtr(&self.set_layout),
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
}