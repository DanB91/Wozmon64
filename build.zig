const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    _ = target;

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const toolbox_module = b.addModule("toolbox", .{
        .source_file = .{ .path = "src/toolbox/src/toolbox.zig" },
    });

    //compile bootloader
    const bootloader_install_step = b: {
        const uefi_target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = "x86_64-uefi-gnu" });
        const exe = b.addExecutable(.{
            .name = "bootx64",
            // In this case the main source file is merely a path, however, in more
            // complicated build scripts, this could be a generated file.
            .root_source_file = .{ .path = "src/bootloader.zig" },
            .target = uefi_target,
            .optimize = optimize,
        });
        exe.addModule("toolbox", toolbox_module);
        exe.force_pic = true;
        exe.red_zone = false;
        const install_step = b.addInstallArtifact(exe);
        install_step.dest_dir = .{ .custom = "img/EFI/BOOT/" };

        break :b install_step;
    };
    b.getInstallStep().dependOn(&bootloader_install_step.step);

    //run bootloader in qemu
    {
        const run_step = b.step("run", "Run Wozmon64 in qemu");
        const qemu_command = b.addSystemCommand(&[_][]const u8{
            "qemu-system-x86_64",
            "-smp",
            "cores=3",
            "-m",
            "1G",
            "-no-reboot",
            "-cpu",
            "Skylake-Client-v3",
            "-d",
            "int,cpu_reset,trace:pic_interrupt,trace:pci_nvme_err_*,trace:usb_*",
            "-D",
            "zig-out/qemu.log",
            "-serial",
            "stdio",
            "-bios",
            "3rdparty/OVMF.fd",
            "-machine",
            "q35",
            "-device",
            "nvme,drive=nvme0,serial=deadbeaf1",
            "-drive",
            "format=raw,file=fat:rw:zig-out/img/,if=none,id=nvme0",
        });
        qemu_command.step.dependOn(b.getInstallStep());

        run_step.dependOn(&qemu_command.step);
    }

    //clean step
    {
        const clean_step = b.step("clean", "Clean all artifacts");
        const rm_zig_cache = b.addRemoveDirTree("zig-cache");
        clean_step.dependOn(&rm_zig_cache.step);
        const rm_zig_out = b.addRemoveDirTree("zig-out");
        clean_step.dependOn(&rm_zig_out.step);
    }
}
