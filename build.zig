const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const toolbox_module = b.addModule("toolbox", .{
        .source_file = .{ .path = "src/toolbox/src/toolbox.zig" },
    });

    const kernel_step = b: {
        const kernel_target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = "x86_64-freestanding-gnu" });
        const exe = b.addExecutable(.{
            .name = "kernel.elf",
            .root_source_file = .{ .path = "src/kernel.zig" },
            .target = kernel_target,
            .optimize = optimize,
        });
        exe.linker_script = .{ .path = "src/linker.ld" };
        exe.code_model = .kernel;

        exe.addModule("toolbox", toolbox_module);
        exe.force_pic = true;
        exe.red_zone = false;
        _ = b.addInstallArtifact(exe);
        break :b exe;
    };

    //compile bootloader
    const bootloader_install_step = b: {
        const uefi_target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = "x86_64-uefi-gnu" });
        const exe = b.addExecutable(.{
            .name = "bootx64",
            .root_source_file = .{ .path = "src/bootloader.zig" },
            .target = uefi_target,
            .optimize = optimize,
        });
        exe.addModule("toolbox", toolbox_module);
        exe.force_pic = true;
        exe.red_zone = false;

        //allows @embedFile("../zig-out/bin/kernel.elf") to work
        exe.setMainPkgPath(".");

        const install_step = b.addInstallArtifact(exe);
        install_step.dest_dir = .{ .custom = "img/EFI/BOOT/" };
        install_step.step.dependOn(&kernel_step.step);

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
