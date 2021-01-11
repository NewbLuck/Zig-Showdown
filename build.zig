const std = @import("std");
const vkgen = @import("deps/vulkan-zig/generator/index.zig");
const AssetStep = @import("src/build/AssetStep.zig");

const pkgs = struct {
    const network = std.build.Pkg{
        .name = "network",
        .path = "./deps/zig-network/network.zig",
    };

    const args = std.build.Pkg{
        .name = "args",
        .path = "./deps/zig-args/args.zig",
    };

    const pixel_draw = std.build.Pkg{
        .name = "pixel_draw",
        .path = "./deps/pixel_draw/src/pixel_draw_module.zig",
    };

    const zwl = std.build.Pkg{
        .name = "zwl",
        .path = "./deps/zwl/src/zwl.zig",
    };

    const painterz = std.build.Pkg{
        .name = "painterz",
        .path = "./deps/painterz/painterz.zig",
    };

    const zlm = std.build.Pkg{
        .name = "zlm",
        .path = "./deps/zlm/zlm.zig",
    };

    const wavefront_obj = std.build.Pkg{
        .name = "wavefront-obj",
        .path = "./deps/wavefront-obj/wavefront-obj.zig",
        .dependencies = &[_]std.build.Pkg{
            zlm,
        },
    };

    const zzz = std.build.Pkg{
        .name = "zzz",
        .path = "./deps/zzz/src/main.zig",
    };

    const gl = std.build.Pkg{
        .name = "gl",
        .path = "./deps/opengl/gl_3v3_with_exts.zig",
    };

    const zigimg = std.build.Pkg{
        .name = "zigimg",
        .path = "./deps/zigimg/zigimg.zig",
    };

    const soundio = std.build.Pkg{
        .name = "soundio",
        .path = "./deps/soundio.zig/soundio.zig",
    };
};

const vk_xml_path = "deps/Vulkan-Docs/xml/vk.xml";

const State = enum {
    create_server,
    create_sp_game,
    credits,
    gameplay,
    join_game,
    main_menu,
    options,
    pause_menu,
    splash,
    demo_pause,
};

const RenderBackend = enum {
    /// basic software rendering
    software,

    /// high-performance desktop rendering
    vulkan,

    /// OpenGL based rendering backend
    opengl,

    /// basic rendering backend for mobile devices and embedded stuff like Raspberry PI
    opengl_es,
};

const AudioConfig = struct {
    jack: bool = false,
    pulseaudio: bool,
    alsa: bool,
    coreaudio: bool,
    wasapi: bool,
};

fn addClientPackages(
    exe: *std.build.LibExeObjStep,
    target: std.zig.CrossTarget,
    render_backend: RenderBackend,
    gen_vk: *vkgen.VkGenerateStep,
    resources: std.build.Pkg,
) void {
    exe.addPackage(pkgs.network);
    exe.addPackage(pkgs.args);
    exe.addPackage(pkgs.zwl);
    exe.addPackage(pkgs.zlm);
    exe.addPackage(pkgs.zzz);
    exe.addPackage(resources);
    exe.addPackage(pkgs.soundio);

    switch (render_backend) {
        .vulkan => {
            exe.step.dependOn(&gen_vk.step);
            exe.addPackage(gen_vk.package);
            exe.linkLibC();

            if (target.isLinux()) {
                exe.linkSystemLibrary("X11");
            } else {
                @panic("vulkan not yet implemented yet for this target");
            }
        },
        .software => {
            exe.addPackage(pkgs.pixel_draw);
            exe.addPackage(pkgs.painterz);
        },
        .opengl_es => {
            // TODO
            @panic("opengl_es is not implementated yet");
        },
        .opengl => {
            exe.addPackage(pkgs.gl);
            if (target.isWindows()) {
                exe.linkSystemLibrary("opengl32");
            } else {
                exe.linkLibC();
                exe.linkSystemLibrary("X11");
                exe.linkSystemLibrary("GL");
            }
        },
    }
}

pub fn build(b: *std.build.Builder) !void {
    // workaround for windows not having visual studio installed
    // (makes .gnu the default target)
    const native_target = if (std.builtin.os.tag != .windows)
        std.zig.CrossTarget{}
    else
        std.zig.CrossTarget{ .abi = .gnu };

    const target = b.standardTargetOptions(.{
        .default_target = native_target,
    });
    const mode = b.standardReleaseOptions();

    const default_port = b.option(
        u16,
        "default-port",
        "The port the game will use as its default port",
    ) orelse 3315;
    const initial_state = b.option(
        State,
        "initial-state",
        "The initial state of the game. This is only relevant for debugging.",
    ) orelse .splash;
    const enable_frame_counter = b.option(
        bool,
        "enable-fps-counter",
        "Enables the FPS counter as an overlay.",
    ) orelse (mode == .Debug);
    const render_backend = b.option(
        RenderBackend,
        "renderer",
        "Selects the rendering backend which the game should use to render",
    ) orelse .software;
    const embed_resources = b.option(
        bool,
        "embed-resources",
        "When set, the resources will be embedded into the binary.",
    ) orelse false;

    const debug_tools = b.option(
        bool,
        "debug-tools",
        "When set, the tools will be compiled in Debug mode, ReleaseSafe otherwise.",
    ) orelse false;

    const tool_mode: std.builtin.Mode = if (debug_tools)
        .Debug
    else
        .ReleaseSafe;

    var audio_config = AudioConfig{
        .jack = b.option(bool, "jack", "Enables/disables the JACK backend.") orelse false,
        .pulseaudio = b.option(bool, "pulseaudio", "Enables/disables the pulseaudio backend.") orelse target.isLinux(),
        .alsa = b.option(bool, "alsa", "Enables/disables the alsa backend.") orelse target.isLinux(),
        .coreaudio = b.option(bool, "coreaudio", "Enables/disables the CoreAudio backend.") orelse target.isDarwin(),
        .wasapi = b.option(bool, "wasapi", "Enables/disables the WASAPI backend.") orelse target.isWindows(),
    };

    if (target.isLinux() and !target.isGnuLibC() and (render_backend == .vulkan or render_backend == .opengl or render_backend == .opengl_es)) {
        @panic("OpenGL, Vulkan and OpenGL ES require linking against glibc, musl is not supported!");
    }

    const test_step = b.step("test", "Runs the test suite for all source filess");

    const gen_vk = vkgen.VkGenerateStep.init(b, vk_xml_path, "vk.zig");

    const asset_gen_step = blk: {
        const obj_conv = b.addExecutable("obj-conv", "src/tools/obj-conv.zig");
        obj_conv.addPackage(pkgs.args);
        obj_conv.addPackage(pkgs.zlm);
        obj_conv.addPackage(pkgs.wavefront_obj);
        obj_conv.setTarget(native_target);
        obj_conv.setBuildMode(tool_mode);

        const tex_conv = b.addExecutable("tex-conv", "src/tools/tex-conv.zig");
        tex_conv.addPackage(pkgs.args);
        tex_conv.addPackage(pkgs.zigimg);
        tex_conv.setTarget(native_target);
        tex_conv.setBuildMode(tool_mode);
        tex_conv.linkLibC();

        const snd_conv = b.addExecutable("snd-conv", "src/tools/snd-conv.zig");
        snd_conv.addPackage(pkgs.args);
        snd_conv.setTarget(native_target);
        snd_conv.setBuildMode(tool_mode);
        snd_conv.linkLibC();

        const tools_step = b.step("tools", "Compiles all tools required in the build process");
        tools_step.dependOn(&obj_conv.step);
        tools_step.dependOn(&tex_conv.step);
        tools_step.dependOn(&snd_conv.step);

        const asset_gen_step = try AssetStep.create(b, embed_resources, .{
            .obj_conv = obj_conv,
            .tex_conv = tex_conv,
            .snd_conv = snd_conv,
        });

        try asset_gen_step.addResources("assets-in");

        const assets_step = b.step("assets", "Compiles all assets to their final format");
        assets_step.dependOn(&asset_gen_step.step);

        break :blk asset_gen_step;
    };

    const libsoundio = blk: {
        const root = "./deps/libsoundio";

        const lib = b.addStaticLibrary("soundio", null);
        lib.setBuildMode(mode);
        lib.setTarget(target);

        const cflags = [_][]const u8{
            "-std=c11",
            "-fvisibility=hidden",
            "-Wall",
            "-Werror=strict-prototypes",
            "-Werror=old-style-definition",
            "-Werror=missing-prototypes",
            "-Wno-missing-braces",
        };

        lib.defineCMacro("_REENTRANT");
        lib.defineCMacro("_POSIX_C_SOURCE=200809L");

        lib.defineCMacro("SOUNDIO_VERSION_MAJOR=2");
        lib.defineCMacro("SOUNDIO_VERSION_MINOR=0");
        lib.defineCMacro("SOUNDIO_VERSION_PATCH=0");
        lib.defineCMacro("SOUNDIO_VERSION_STRING=\"2.0.0\"");

        var sources = [_][]const u8{
            root ++ "/src/soundio.c",
            root ++ "/src/util.c",
            root ++ "/src/os.c",
            root ++ "/src/dummy.c",
            root ++ "/src/channel_layout.c",
            root ++ "/src/ring_buffer.c",
        };

        for (sources) |src| {
            lib.addCSourceFile(src, &cflags);
        }

        if (audio_config.jack) lib.addCSourceFile(root ++ "/src/jack.c", &cflags);
        if (audio_config.pulseaudio) lib.addCSourceFile(root ++ "/src/pulseaudio.c", &cflags);
        if (audio_config.alsa) lib.addCSourceFile(root ++ "/src/alsa.c", &cflags);
        if (audio_config.coreaudio) lib.addCSourceFile(root ++ "/src/coreaudio.c", &cflags);
        if (audio_config.wasapi) lib.addCSourceFile(root ++ "/src/wasapi.c", &cflags);

        if (audio_config.jack) lib.defineCMacro("SOUNDIO_HAVE_JACK");
        if (audio_config.pulseaudio) lib.defineCMacro("SOUNDIO_HAVE_PULSEAUDIO");
        if (audio_config.alsa) lib.defineCMacro("SOUNDIO_HAVE_ALSA");
        if (audio_config.coreaudio) lib.defineCMacro("SOUNDIO_HAVE_COREAUDIO");
        if (audio_config.wasapi) lib.defineCMacro("SOUNDIO_HAVE_WASAPI");

        if (audio_config.jack) lib.linkSystemLibrary("jack");

        if (audio_config.pulseaudio) lib.linkSystemLibrary("libpulse");

        if (audio_config.alsa) lib.linkSystemLibrary("alsa");

        if (audio_config.coreaudio) @panic("Audio for MacOS not implemented. Please find the correct libraries and stuff.");

        // if (audio_config.wasapi) lib.linkSystemLibrary("");

        lib.linkLibC();
        lib.linkSystemLibrary("m");

        lib.addIncludeDir(root);
        lib.addIncludeDir("src/soundio");

        break :blk lib;
    };

    {
        const client = b.addExecutable("showdown", "src/client/main.zig");
        addClientPackages(client, target, render_backend, gen_vk, asset_gen_step.package);

        client.addBuildOption(State, "initial_state", initial_state);
        client.addBuildOption(bool, "enable_frame_counter", enable_frame_counter);
        client.addBuildOption(u16, "default_port", default_port);
        client.addBuildOption(RenderBackend, "render_backend", render_backend);

        client.linkLibrary(libsoundio);

        client.setTarget(target);
        client.setBuildMode(mode);

        // Needed for libsoundio:
        client.linkLibC();
        client.linkSystemLibrary("m");

        if (audio_config.jack) {
            client.linkSystemLibrary("jack");
        }
        if (audio_config.pulseaudio) {
            client.linkSystemLibrary("libpulse");
        }
        if (audio_config.alsa) {
            client.linkSystemLibrary("alsa");
        }
        if (audio_config.coreaudio) {
            @panic("Audio for MacOS not implemented. Please find the correct libraries and stuff.");
        }
        if (audio_config.wasapi) {
            // this is required for soundio
            client.linkSystemLibrary("uuid");
            client.linkSystemLibrary("ole32");
        }

        client.install();

        const run_client_cmd = client.run();
        run_client_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_client_cmd.addArgs(args);
        }

        const run_client_step = b.step("run", "Run the app");
        run_client_step.dependOn(&run_client_cmd.step);
    }

    {
        const server = b.addExecutable("showdown-server", "src/server/main.zig");
        server.addPackage(pkgs.network);
        server.setTarget(target);
        server.setBuildMode(mode);
        server.addBuildOption(u16, "default_port", default_port);
        server.install();

        const run_server_cmd = server.run();
        run_server_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_server_cmd.addArgs(args);
        }

        const run_server_step = b.step("run-server", "Run the app");
        run_server_step.dependOn(&run_server_cmd.step);
    }

    {
        const test_client = b.addTest("src/client/main.zig");
        addClientPackages(test_client, target, render_backend, gen_vk, asset_gen_step.package);

        test_client.addBuildOption(State, "initial_state", initial_state);
        test_client.addBuildOption(bool, "enable_frame_counter", enable_frame_counter);
        test_client.addBuildOption(u16, "default_port", default_port);
        test_client.addBuildOption(RenderBackend, "render_backend", render_backend);

        test_client.setTarget(target);
        test_client.setBuildMode(mode);

        if (mode != .Debug) {
            // TODO: Workaround for
            test_client.linkLibC();
            test_client.linkSystemLibrary("m");
        }

        const test_server = b.addTest("src/server/main.zig");
        test_server.setTarget(target);
        test_server.setBuildMode(mode);

        test_step.dependOn(&test_client.step);
        test_step.dependOn(&test_server.step);
    }

    // collision development stuff
    {
        const exe = b.addExecutable("collision", "src/development/collision.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addPackage(pkgs.zlm);

        const exe_step = b.step("collision", "Compiles the collider dev environment.");
        exe_step.dependOn(&exe.step);

        const run = exe.run();

        const run_step = b.step("run-collision", "Runs the collider dev environment.");
        run_step.dependOn(&run.step);

        const tst = b.addTest("src/development/collision.zig");
        tst.addPackage(pkgs.zlm);

        test_step.dependOn(&tst.step);
    }
}
