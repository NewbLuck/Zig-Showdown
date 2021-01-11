const std = @import("std");
const network = @import("network");
const args = @import("args");
const zwl = @import("zwl");
const zzz = @import("zzz");
const build_options = @import("build_options");

const Game = @import("Game.zig");
const Input = @import("Input.zig");

const Resources = @import("Resources.zig");
const ConfigFile = @import("ConfigFile.zig");
const Audio = @import("Audio.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const global_allocator = &gpa.allocator;

pub const WindowPlatform = zwl.Platform(.{
    .platforms_enabled = .{
        .x11 = (std.builtin.os.tag == .linux and build_options.render_backend == .software),
        .xlib = (std.builtin.os.tag == .linux and build_options.render_backend != .software),
        .wayland = false,
        .windows = (std.builtin.os.tag == .windows),
    },
    .backends_enabled = .{
        // TODO: Extend this checks
        .software = (build_options.render_backend == .software),
        .opengl = (build_options.render_backend == .opengl),
        .vulkan = (build_options.render_backend == .vulkan),
    },
    .single_window = false,
    .x11_use_xcb = false,
});

/// This is a type that abstracts rendering tasks into
/// a platform-independent matter
pub const Renderer = @import("Renderer.zig");

const Config = struct {
    const Self = @This();
    const Tree = zzz.ZTree(10, 100);

    memory: std.heap.ArenaAllocator,
    text: []const u8,
    tree: Tree,
    root: *zzz.ZNode,
    imprint: zzz.Imprint(ConfigFile),

    pub fn get(self: *const Self) *const ConfigFile {
        return &self.imprint.result;
    }

    pub fn deinit(self: *Self) void {
        self.memory.deinit();
        self.* = undefined;
    }
};

pub fn main() anyerror!u8 {
    defer _ = gpa.deinit();

    var boottime_timer: ?std.time.Timer = try std.time.Timer.start();

    try network.init();
    defer network.deinit();

    var cli = args.parseForCurrentProcess(CliArgs, global_allocator) catch |err| switch (err) {
        error.EncounteredUnknownArgument => {
            try printUsage(std.io.getStdErr().writer());
            return 1;
        },
        else => |e| return e,
    };
    defer cli.deinit();

    if (cli.options.help) {
        try printUsage(std.io.getStdOut().writer());
        return 0;
    }

    const config_file_name = cli.options.@"config-file" orelse "showdown.conf";

    var config = Config{
        .memory = std.heap.ArenaAllocator.init(global_allocator),
        .text = undefined,
        .tree = .{},
        .root = undefined,
        .imprint = undefined,
    };
    defer config.deinit();

    {
        config.text = std.fs.cwd().readFileAlloc(&config.memory.allocator, config_file_name, 500_000) catch |err| switch (err) {
            error.FileNotFound => "", // empty config
            else => |e| return e,
        };

        config.root = try config.tree.appendText(config.text);
        config.root.convertStrings();

        // for debugging:
        // config.tree.show();

        config.imprint = try config.root.imprintAlloc(ConfigFile, &config.memory.allocator);
    }

    // Do not init windowing before necessary. We don't need a window
    // for printing a help string.

    var audio = try Audio.init(global_allocator, config.get().audio);
    defer audio.deinit();

    var platform = try WindowPlatform.init(global_allocator, .{});
    defer platform.deinit();

    var window = try platform.createWindow(.{
        .title = "Zig SHOWDOWN",
        .width = config.get().video.resolution[0],
        .height = config.get().video.resolution[1],
        .resizeable = false,
        .track_damage = switch (build_options.render_backend) {
            .opengl => true,
            else => false,
        },
        .visible = true,
        .decorations = true,
        .track_mouse = true,
        .track_keyboard = true,
        .backend = switch (build_options.render_backend) {
            .software => .software,
            .opengl => zwl.Backend{ .opengl = .{ .major = 3, .minor = 3 } },
            // TODO: Change to .vulkan when the ZWL Xlib backend supports vulkan.
            .vulkan => .none,
            else => @compileError("unsupported render backend!"),
        },
    });
    defer window.deinit();

    var renderer = try Renderer.init(global_allocator, window, config.get().graphics);
    defer renderer.deinit();

    var resources = try Resources.init(global_allocator, &renderer, audio);
    defer resources.deinit();

    // TODO: This is a ugly hack in the design and should be resolved
    renderer.resources = &resources;

    var input = Input.init();

    var game = try Game.init(global_allocator, &resources, audio);
    defer game.deinit();

    var update_timer = try std.time.Timer.start();
    var render_timer = try std.time.Timer.start();

    const stretch_factor = 1.0 / cli.options.@"time-stretch";

    try audio.start();

    main_loop: while (game.running) {
        try audio.update();

        const event = try platform.waitForEvent();
        {
            switch (event) {
                .WindowResized => |win| {
                    const size = win.getSize();
                    std.log.debug("*notices size {}x{}* OwO what's this", .{ size[0], size[1] });
                },

                // someone closed the window, just stop the game:
                .WindowDestroyed, .ApplicationTerminated => break :main_loop,

                .WindowDamaged, .WindowVBlank => {

                    // Lockstep updates with renderer for now
                    {
                        const update_delta = @intToFloat(f32, update_timer.lap()) / std.time.ns_per_s;
                        try game.update(input, stretch_factor * update_delta);
                    }

                    input.resetEvents();

                    // After updating, render the game
                    {
                        try renderer.beginFrame();
                        const render_delta = @intToFloat(f32, render_timer.lap()) / std.time.ns_per_s;
                        try game.render(&renderer, stretch_factor * render_delta);
                        try renderer.endFrame();
                    }

                    if (boottime_timer) |timer| {
                        std.log.debug("time to first image: {} µs", .{timer.read() / 1000});
                        boottime_timer = null;
                    }
                },

                .KeyUp, .KeyDown => |ev| {
                    const button: ?Input.Button = blk: inline for (std.meta.fields(Input.Button)) |fld| {
                        // ignore mouse buttons
                        if (!comptime std.mem.eql(u8, fld.name, "left_mouse")) {
                            for (@field(config.get().keymap, fld.name)) |scancode| {
                                if (ev.scancode == scancode)
                                    break :blk @field(Input.Button, fld.name);
                            }
                        }
                    } else null;

                    if (button) |btn| {
                        input.updateButton(btn, event == .KeyDown);
                    } else {
                        std.log.info("unknown button pressed: {}", .{ev.scancode});
                    }

                    if (event == .KeyDown)
                        input.any_button_was_pressed = true;
                    if (event == .KeyUp)
                        input.any_button_was_released = false;
                },

                .MouseButtonDown, .MouseButtonUp => |ev| {
                    switch (ev.button) {
                        .left => input.updateButton(.left_mouse, event == .MouseButtonDown),
                        else => {},
                    }
                },

                .MouseMotion => |ev| {
                    input.mouse_x = ev.x;
                    input.mouse_y = ev.y;
                },
            }
        }
    }

    return 0;
}

const CliArgs = struct {
    // In release mode, run the game in fullscreen by default,
    // otherwise use windowed mode
    fullscreen: bool = if (std.builtin.mode != .Debug)
        true
    else
        false,

    port: u16 = @import("build_options").default_port,

    help: bool = false,

    @"time-stretch": f32 = 1.0,

    @"config-file": ?[]const u8 = null,

    pub const shorthands = .{
        .f = "fullscreen",
        .h = "help",
        .c = "config-file",
    };
};

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: showdown
        \\Starts Zig SHOWDOWN.
        \\
        \\  -h, --help               display this help and exit
        \\      --time-stretch=FAC   Stretches the game speed by FAC. FAC="2.0" means the game
        \\                           will run with half the speed.
        \\  -p, --port=PORT          Changes the port used for the game server to PORT.
        \\  -f, --fullscreen=FULL    Will run the game in fullscreen mode when FULL = true.
        \\  -c, --config-file=CFG    Uses a different config file than the default one (showdown.conf)
        \\
    );
}

test "" {
    _ = @import("resource_pool.zig");
    _ = @import("resources/Model.zig");
    _ = @import("states/gameplay/ec.zig");
    _ = @import("Audio.zig");
}
