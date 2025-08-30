const std = @import("std");
const sokol = @import("sokol");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_sokol = b.dependency("sokol", .{ .target = target, .optimize = optimize });

    const cwd = std.fs.cwd();
    const sync_alias = b.step("sync-shaders", "Copy shaders from assets/shaders to src/shaders/");
    {
        const mkdir_dst = b.addSystemCommand(&.{ "mkdir", "-p", "src/shaders" });
        sync_alias.dependOn(&mkdir_dst.step);

        if (cwd.openDir("assets/shaders", .{ .iterate = true })) |dir| {
            var it = dir.iterate();
            while (try it.next()) |de| {
                if (de.kind != .file) continue;
                if (!std.mem.endsWith(u8, de.name, ".glsl")) continue;

                const src_path = b.fmt("assets/shaders/{s}", .{de.name});
                const dst_path = b.fmt("src/shaders/{s}", .{de.name});
                const cp = b.addSystemCommand(&.{"cp"});
                cp.addArg(src_path);
                cp.addArg(dst_path);
                sync_alias.dependOn(&cp.step);
            }
        } else |_| {}
    }

    // Create main module so we can add include path for C headers
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
        },
    });

    // C headers include paths (thirdparty and vendored Lua)
    main_mod.addIncludePath(.{ .cwd_relative = "thirdparty" });
    main_mod.addIncludePath(.{ .cwd_relative = "thirdparty/lua-5.4.8/src" });

    const hello = b.addExecutable(.{
        .name = "zengine",
        .root_module = main_mod,
    });
    // Include path for C sources that include thirdparty headers
    hello.addIncludePath(.{ .cwd_relative = "thirdparty" });
    // Compile stb_truetype implementation unit
    hello.addCSourceFiles(.{ .files = &.{
        "src/c/stb_truetype_impl.c",
    } });
    b.installArtifact(hello);
    const run = b.addRunArtifact(hello);
    b.step("run", "Run zengine").dependOn(&run.step);

    // ensure shaders are synced before building
    hello.step.dependOn(sync_alias);

    // --- Lua 5.4 static library (vendored C sources) ---
    const lua_lib = b.addStaticLibrary(.{
        .name = "lua54",
        .target = target,
        .optimize = optimize,
    });
    lua_lib.addIncludePath(.{ .cwd_relative = "thirdparty/lua-5.4.8/src" });
    lua_lib.addCSourceFiles(.{
        .files = &.{
            // core
            "thirdparty/lua-5.4.8/src/lapi.c",
            "thirdparty/lua-5.4.8/src/lcode.c",
            "thirdparty/lua-5.4.8/src/lctype.c",
            "thirdparty/lua-5.4.8/src/ldebug.c",
            "thirdparty/lua-5.4.8/src/ldo.c",
            "thirdparty/lua-5.4.8/src/ldump.c",
            "thirdparty/lua-5.4.8/src/lfunc.c",
            "thirdparty/lua-5.4.8/src/lgc.c",
            "thirdparty/lua-5.4.8/src/llex.c",
            "thirdparty/lua-5.4.8/src/lmem.c",
            "thirdparty/lua-5.4.8/src/lobject.c",
            "thirdparty/lua-5.4.8/src/lopcodes.c",
            "thirdparty/lua-5.4.8/src/lparser.c",
            "thirdparty/lua-5.4.8/src/lstate.c",
            "thirdparty/lua-5.4.8/src/lstring.c",
            "thirdparty/lua-5.4.8/src/ltable.c",
            "thirdparty/lua-5.4.8/src/ltm.c",
            "thirdparty/lua-5.4.8/src/lundump.c",
            "thirdparty/lua-5.4.8/src/lvm.c",
            "thirdparty/lua-5.4.8/src/lzio.c",
            // libs
            "thirdparty/lua-5.4.8/src/lauxlib.c",
            "thirdparty/lua-5.4.8/src/lbaselib.c",
            "thirdparty/lua-5.4.8/src/lcorolib.c",
            "thirdparty/lua-5.4.8/src/ldblib.c",
            "thirdparty/lua-5.4.8/src/liolib.c",
            "thirdparty/lua-5.4.8/src/lmathlib.c",
            "thirdparty/lua-5.4.8/src/loslib.c",
            "thirdparty/lua-5.4.8/src/lstrlib.c",
            "thirdparty/lua-5.4.8/src/ltablib.c",
            "thirdparty/lua-5.4.8/src/lutf8lib.c",
            "thirdparty/lua-5.4.8/src/loadlib.c",
            // init
            "thirdparty/lua-5.4.8/src/linit.c",
        },
        .flags = &.{
            // Enable platform helpers for macOS (dlopen, locale, etc.)
            "-DLUA_USE_MACOSX",
        },
    });
    // Ensure any C runtime headers pick the same include paths
    hello.linkLibrary(lua_lib);

    // For any additional shaders in assets/shaders/*.glsl (excluding the two above), generate to src/shaders/<stem>-shader.zig
    if (cwd.openDir("assets/shaders", .{ .iterate = true })) |dir2| {
        var it2 = dir2.iterate();
        while (try it2.next()) |de| {
            if (de.kind != .file) continue;
            if (!std.mem.endsWith(u8, de.name, ".glsl")) continue;

            const stem = de.name[0 .. de.name.len - ".glsl".len];
            const module_name = b.fmt("{s}", .{stem});
            const input_generic = b.fmt("src/shaders/{s}", .{de.name});
            const out_generic = b.fmt("src/shaders/{s}-shader.zig", .{stem});

            const mod = try createGenericModule(b, dep_sokol, module_name, input_generic);
            if (mod.root_source_file) |gen_lp| {
                const cp_gen = b.addSystemCommand(&.{"cp"});
                cp_gen.addFileArg(gen_lp);
                cp_gen.addArg(out_generic);
                const alias = b.step(b.fmt("export-{s}", .{stem}), b.fmt("Copy generated {s} shader", .{de.name}));
                alias.dependOn(&cp_gen.step);
                // ensure shaders are synced before running shdc for this module
                alias.dependOn(sync_alias);
                hello.step.dependOn(alias);
            }
        }
    } else |_| {}
}

// compile a generic shader via sokol-shdc (module_name used as shdc label)
fn createGenericModule(b: *Build, dep_sokol: *Build.Dependency, module_name: []const u8, input_path: []const u8) !*Build.Module {
    const mod_sokol = dep_sokol.module("sokol");
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});
    return sokol.shdc.createModule(b, module_name, mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = input_path,
        // output is temporary; final copy goes to src/shaders/<stem>-shader.zig
        .output = b.fmt(".zig-cache/{s}.zig", .{module_name}),
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            .hlsl4 = true,
            .metal_macos = true,
            .wgsl = true,
        },
    });
}
