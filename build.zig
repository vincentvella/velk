const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
/// Resolves an absolute install dir for `zig build install-local`.
/// Honors `$XDG_BIN_HOME` then `$HOME/.local/bin`. Returns null when
/// neither env var is available so the caller can surface a friendly
/// diagnostic at step-run time. The returned slice is owned by `b`'s
/// allocator; the build runner outlives the slice.
fn resolveLocalBinDir(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("XDG_BIN_HOME")) |v| {
        if (v.len > 0) return b.allocator.dupe(u8, v) catch null;
    }
    const home = b.graph.environ_map.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.allocPrint(b.allocator, "{s}/.local/bin", .{home}) catch null;
}

pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("velk", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const mvzr_dep = b.dependency("mvzr", .{ .target = target, .optimize = optimize });
    const mvzr_mod = mvzr_dep.module("mvzr");

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_mod = vaxis_dep.module("vaxis");

    // cmark-gfm — vendored C library, full CommonMark + GFM. We link
    // it statically; the Zig wrapper exposes the standard cmark.h
    // header which we @cImport from src/markdown.zig.
    const cmark_dep = b.dependency("cmark_gfm", .{ .target = target, .optimize = optimize });
    const cmark_lib = cmark_dep.artifact("cmark-gfm");
    const cmark_extensions_lib = cmark_dep.artifact("cmark-gfm-extensions");

    const exe = b.addExecutable(.{
        .name = "velk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "velk", .module = mod },
                .{ .name = "mvzr", .module = mvzr_mod },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    exe.root_module.linkLibrary(cmark_lib);
    exe.root_module.linkLibrary(cmark_extensions_lib);

    // We pull in std.c.write / _exit / kill for the SIGINT handler and
    // the bash process-group killer. macOS links libc implicitly, but
    // Linux cross-builds need it spelled out.
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // `zig build smoke` builds the binary then runs scripts/smoke.sh
    // against it. Asserts arg parsing, exit codes, env-var error messages
    // — no API calls. Runs in <2s.
    const smoke_cmd = b.addSystemCommand(&.{ "bash", "scripts/smoke.sh" });
    smoke_cmd.step.dependOn(b.getInstallStep());
    const smoke_step = b.step("smoke", "Run CLI smoke tests (no API)");
    smoke_step.dependOn(&smoke_cmd.step);

    // `zig build codename-check` greps the source tree against a
    // deny-list of internal codenames (scripts/codename-denylist.txt).
    // The deny-list ships empty so this is a no-op for fresh checkouts;
    // a maintainer fills it in when they need to gate a release. The
    // step is fast (single-digit ms on this tree), so we wire it into
    // `check` unconditionally — the overhead is negligible.
    const codename_cmd = b.addSystemCommand(&.{ "bash", "scripts/codename-check.sh" });
    const codename_step = b.step("codename-check", "Grep source tree against the codename deny-list");
    codename_step.dependOn(&codename_cmd.step);

    // `zig build check` runs both unit tests and smoke tests.
    const check_step = b.step("check", "Run unit tests + smoke tests");
    check_step.dependOn(test_step);
    check_step.dependOn(smoke_step);
    check_step.dependOn(codename_step);

    // `zig build tui-test` drives the TUI under a python pty harness
    // (scripts/tui-test.py) and asserts on ANSI-stripped output. Lets
    // us cover slash commands and other interactive behaviour without
    // a real terminal.
    const tui_cmd = b.addSystemCommand(&.{ "python3", "scripts/tui-test.py" });
    tui_cmd.step.dependOn(b.getInstallStep());
    const tui_test_step = b.step("tui-test", "Run TUI pty harness");
    tui_test_step.dependOn(&tui_cmd.step);
    check_step.dependOn(tui_test_step);

    // `zig build mock` starts the python mock model server. Use to
    // develop / demo velk without burning real API tokens. Point velk
    // at it via ANTHROPIC_BASE_URL or OPENAI_BASE_URL.
    const mock_cmd = b.addSystemCommand(&.{ "python3", "scripts/mock-server.py" });
    if (b.args) |args| mock_cmd.addArgs(args);
    const mock_step = b.step("mock", "Run the mock model server (Ctrl-C to stop)");
    mock_step.dependOn(&mock_cmd.step);

    // `zig build install-local` installs the binary into the user's
    // PATH without needing a tap or root. Honors `$XDG_BIN_HOME` (the
    // XDG-formal home for user binaries), then `$HOME/.local/bin`, in
    // that order. Implementation: build the binary via the standard
    // install step, then `install` it (mkdir -p + cp) into the
    // resolved absolute directory. The standard `zig build install`
    // remains the no-op default.
    const install_local_step = b.step("install-local", "Install velk into $XDG_BIN_HOME or ~/.local/bin");
    if (resolveLocalBinDir(b)) |dest_dir| {
        const dest_path = std.fmt.allocPrint(b.allocator, "{s}/velk", .{dest_dir}) catch dest_dir;
        const cp_cmd = b.addSystemCommand(&.{ "install", "-d", dest_dir });
        cp_cmd.step.dependOn(b.getInstallStep());
        const cp_bin = b.addSystemCommand(&.{ "install", "-m", "0755" });
        cp_bin.addArtifactArg(exe);
        cp_bin.addArg(dest_path);
        cp_bin.step.dependOn(&cp_cmd.step);
        install_local_step.dependOn(&cp_bin.step);
    } else {
        // Defer the friendly diagnostic until the step actually runs;
        // we don't want to spam the default-step build with it.
        const fail = b.addSystemCommand(&.{
            "sh", "-c",
            "echo 'install-local: neither $XDG_BIN_HOME nor $HOME is set' >&2 && exit 1",
        });
        install_local_step.dependOn(&fail.step);
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
