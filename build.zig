const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const toolbox_module = b.addModule("toolbox", .{
        .source_file = .{ .path = "src/toolbox/src/toolbox.zig" },
    });

    const w64_module = b.addModule("wozmon64", .{
        .source_file = .{ .path = "src/wozmon64_user.zig" },
    });
    try w64_module.dependencies.put("toolbox", toolbox_module);

    var woz_and_jobs_step: *std.Build.Step.Compile = undefined;
    var woz_and_jobs_install_step: *std.Build.Step.InstallFile = undefined;
    {
        const target = try std.zig.CrossTarget.parse(.{
            .arch_os_abi = "x86_64-freestanding-gnu",
        });
        const exe = b.addExecutable(.{
            .name = "woz_and_jobs",
            .root_source_file = .{ .path = "sample_programs/woz_and_jobs.zig" },
            .target = target,
            .optimize = b.standardOptimizeOption(.{
                .preferred_optimize_mode = .ReleaseFast,
            }),
            .main_pkg_path = .{ .path = "sample_programs" },
        });

        exe.linker_script = .{ .path = "sample_programs/linker.ld" };
        exe.addModule("wozmon64", w64_module);
        exe.addModule("toolbox", toolbox_module);
        exe.force_pic = true;
        exe.red_zone = false;

        woz_and_jobs_step = exe;
        const install_elf =
            b.addInstallArtifact(exe, .{});
        //const install_step = b.addInstallArtifact(exe, .{});
        const objcopy = exe.addObjCopy(.{
            .format = .bin,
        });

        woz_and_jobs_install_step =
            b.addInstallBinFile(objcopy.getOutput(), "woz_and_jobs.bin");

        //woz_and_jobs_install_step.step.dependOn(&install_step.step);
        install_elf.step.dependOn(&exe.step);
        objcopy.step.dependOn(&install_elf.step);
        woz_and_jobs_install_step.step.dependOn(&objcopy.step);
    }

    var kernel_step: *std.Build.Step.Compile = undefined;
    var kernel_install_step: *std.Build.Step.InstallArtifact = undefined;
    {
        const kernel_target = try std.zig.CrossTarget.parse(.{
            .arch_os_abi = "x86_64-freestanding-gnu",
        });
        const exe = b.addExecutable(.{
            .name = "kernel.elf",
            .root_source_file = .{ .path = "src/kernel.zig" },
            .target = kernel_target,
            .optimize = optimize,
            .main_pkg_path = .{ .path = "." },
        });
        exe.linker_script = .{ .path = "src/linker.ld" };
        exe.code_model = .kernel;

        exe.addModule("toolbox", toolbox_module);
        exe.force_pic = true;
        exe.red_zone = false;

        exe.step.dependOn(&woz_and_jobs_step.step);

        kernel_step = exe;
        kernel_install_step = b.addInstallArtifact(exe, .{});

        kernel_install_step.step.dependOn(&woz_and_jobs_install_step.step);
    }

    //compile bootloader
    const bootloader_install_step = b: {
        const uefi_target = try std.zig.CrossTarget.parse(.{
            .arch_os_abi = "x86_64-uefi-gnu",
        });
        const exe = b.addExecutable(.{
            .name = "bootx64",
            .root_source_file = .{ .path = "src/bootloader.zig" },
            .target = uefi_target,
            .optimize = optimize,
            .main_pkg_path = .{ .path = "." },
        });
        exe.addModule("toolbox", toolbox_module);
        exe.force_pic = true;
        exe.red_zone = false;

        exe.step.dependOn(&kernel_step.step);

        const bootloader_install_step = b.addInstallArtifact(exe, .{});
        bootloader_install_step.dest_dir = .{ .custom = "img/EFI/BOOT/" };
        bootloader_install_step.step.dependOn(&kernel_install_step.step);

        break :b bootloader_install_step;
    };
    b.getInstallStep().dependOn(&bootloader_install_step.step);

    //run bootloader in qemu
    {
        const args_array = [_][]const u8{
            "qemu-system-x86_64",
            "-smp",
            "cores=16",
            "-m",
            "2G",
            "-no-reboot",
            "-cpu",
            "Skylake-Client-v3",
            "-d",
            "int,cpu_reset,trace:pic_interrupt,trace:pci_nvme_err_*,trace:usb_*,trace:apic_*",
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
            "-device",
            "qemu-xhci,id=xhci",
            "-device",
            "usb-kbd,bus=xhci.0",
            "-device",
            "usb-mouse,bus=xhci.0",
        };
        const run_step = b.step("run", "Run Wozmon64 in qemu");
        const qemu_command = b.addSystemCommand(&args_array);
        qemu_command.step.dependOn(b.getInstallStep());

        run_step.dependOn(&qemu_command.step);

        const debug_step = b.step("debug", "Debug Wozmon64 in qemu");
        const debug_qemu_command = b.addSystemCommand(&(args_array ++ [_][]const u8{ "-S", "-s" }));
        debug_qemu_command.step.dependOn(b.getInstallStep());

        debug_step.dependOn(&debug_qemu_command.step);
    }

    //clean step
    {
        const clean_step = b.step("clean", "Clean all artifacts");
        const rm_zig_cache = b.addRemoveDirTree("zig-cache");
        clean_step.dependOn(&rm_zig_cache.step);
        const rm_zig_out = b.addRemoveDirTree("zig-out");
        clean_step.dependOn(&rm_zig_out.step);
    }

    //unit test step
    {
        const target = b.standardTargetOptions(.{});
        // Creates a step for unit testing. This only builds the test executable
        // but does not run it.
        const unit_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/commands.zig" },
            .target = target,
            .optimize = optimize,
        });
        unit_tests.addModule("toolbox", toolbox_module);

        const run_unit_tests = b.addRunArtifact(unit_tests);

        // Similar to creating the run step earlier, this exposes a `test` step to
        // the `zig build --help` menu, providing a way for the user to request
        // running the unit tests.
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}
