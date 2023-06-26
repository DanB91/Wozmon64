//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const mpsp = @import("mp_service_protocol.zig");
const w64 = @import("wozmon64.zig");
const amd64 = @import("amd64.zig");
const console = @import("bootloader_console.zig");

const KERNEL_ELF = @embedFile("../zig-out/bin/kernel.elf");
const UEFI_PAGE_SIZE = toolbox.kb(4);

const ENABLE_CONSOLE = true;

const KERNEL_STACK_BOTTOM_ADDRESS = 0x1_0000_0000_0000_0000 - w64.MEMORY_PAGE_SIZE;

const ZSGraphicsOutputProtocol = std.os.uefi.protocols.GraphicsOutputProtocol;
const ZSGraphicsOutputModeInformation = std.os.uefi.protocols.GraphicsOutputModeInformation;
const ZSUEFIStatus = std.os.uefi.Status;
const ZSMemoryDescriptor = std.os.uefi.tables.MemoryDescriptor;

const SmallUEFIMemoryDescriptor = ZSMemoryDescriptor;

const println = console.println;

comptime {
    toolbox.static_assert(
        @sizeOf(w64.Pixel) == 4,
        "Pixel size incorrect",
    );
}

pub const LargeUEFIMemoryDescriptor = extern struct {
    type: std.os.uefi.tables.MemoryType,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: std.os.uefi.tables.MemoryDescriptorAttribute,
    unknown: u64,
};

const KernelParseResult = struct {
    next_free_virtual_address: u64,
    entry_point: u64,
    top_of_stack_address: u64,
    page_table_data: toolbox.DynamicArray(PageTableData),
};
const PageTableData = struct {
    destination_virtual_address: u64,
    data: []const u8,
    number_of_bytes: usize,
    is_executable: bool,
    is_writable: bool,
};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    //not set in UEFI
    _ = ret_addr;
    _ = error_return_trace;

    println("PANIC: {s}", .{msg});
    toolbox.hang();
}

pub fn main() noreturn {
    //disable interrupts
    asm volatile ("cli");

    const system_table = std.os.uefi.system_table;
    const handle = std.os.uefi.handle;

    const con_out = system_table.con_out.?;
    _ = con_out.reset(false);
    _ = con_out.clearScreen();
    _ = con_out.setCursorPosition(0, 0);

    const bs = system_table.boot_services.?;

    var bootloader_arena_buffer = [_]u8{0} ** toolbox.kb(512);
    var bootloader_arena = toolbox.Arena.init_with_buffer(&bootloader_arena_buffer);

    //graphics

    var gop: *ZSGraphicsOutputProtocol = undefined;
    var found_valid_resolution = false;
    var screen: w64.Screen = b: {
        var status = bs.locateProtocol(&ZSGraphicsOutputProtocol.guid, null, @ptrCast(*?*anyopaque, &gop));
        if (status != ZSUEFIStatus.Success) {
            fatal("Cannot init graphics system! Error locating GOP protocol: {}", .{status});
        }

        //set graphics mode to 0 if NotStarted is returned
        {
            var gop_mode_info: *ZSGraphicsOutputModeInformation = undefined;
            var size_of_info: usize = 0;
            const query_mode_status = gop.queryMode(0, &size_of_info, &gop_mode_info);
            if (query_mode_status == .NotStarted) {
                _ = gop.setMode(0);
            }
        }
        var mode: u32 = 0;
        for (0..gop.mode.max_mode + 1) |i| {
            mode = @intCast(u32, i);
            var gop_mode_info: *ZSGraphicsOutputModeInformation = undefined;
            var size_of_info: usize = 0;
            const query_mode_status = gop.queryMode(mode, &size_of_info, &gop_mode_info);
            if (query_mode_status == .Success) {
                toolbox.assert(
                    @sizeOf(ZSGraphicsOutputModeInformation) == size_of_info,
                    "Wrong size for GOP mode info. Expected: {}, Actual: {}",
                    .{
                        @sizeOf(ZSGraphicsOutputModeInformation),
                        size_of_info,
                    },
                );
                if (gop_mode_info.horizontal_resolution == w64.TARGET_RESOLUTION.width and
                    gop_mode_info.vertical_resolution == w64.TARGET_RESOLUTION.height)
                {
                    found_valid_resolution = true;
                    status = gop.setMode(mode);
                    if (status != ZSUEFIStatus.Success) {
                        fatal("Cannot init graphics system! Error setting mode {}: {}", .{ mode, status });
                    }
                    break;
                }
            }
        }
        if (!found_valid_resolution) {
            fatal(
                "Failed to set screen to required resolution: {}x{}",
                .{
                    w64.TARGET_RESOLUTION.width,
                    w64.TARGET_RESOLUTION.height,
                },
            );
        }

        const frame_buffer = @ptrFromInt([*]w64.Pixel, gop.mode.frame_buffer_base)[0 .. gop.mode.frame_buffer_size / @sizeOf(w64.Pixel)];
        break :b .{
            .frame_buffer = frame_buffer,
            .back_buffer = undefined,
            .width = gop.mode.info.horizontal_resolution,
            .height = gop.mode.info.vertical_resolution,
            .stride = gop.mode.info.pixels_per_scan_line,
        };
    };

    var rsdp = b: {
        for (0..system_table.number_of_table_entries) |i| {
            if (system_table.configuration_table[i].vendor_guid.eql(std.os.uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
                const tmp_rsdp = @ptrCast(*amd64.ACPI2RSDP, @alignCast(
                    @alignOf(amd64.ACPI2RSDP),
                    system_table.configuration_table[i].vendor_table,
                ));
                if (std.mem.eql(u8, &tmp_rsdp.signature, "RSD PTR ")) {
                    break :b tmp_rsdp;
                }
            }
        } else {
            fatal("Cannot find rsdp!", .{});
        }
    };

    var number_of_enabled_processors: usize = 0;
    {
        var mp: *mpsp.MPServiceProtocol = undefined;
        var status = bs.locateProtocol(&mpsp.MPServiceProtocol.guid, null, @ptrCast(*?*anyopaque, &mp));
        if (status != ZSUEFIStatus.Success) {
            fatal("Cannot init multicore support! Error locating MP protocol: {}", .{status});
        }

        var number_of_processors: usize = 0;
        status = mp.mp_services_get_number_of_processors(&number_of_processors, &number_of_enabled_processors);
        if (status != ZSUEFIStatus.Success) {
            fatal("Cannot init multicore support! Error getting number of processors: {}", .{status});
        }
        println("Number of enabled processors: {}", .{number_of_enabled_processors});
    }

    //get memory map
    var memory_map: []LargeUEFIMemoryDescriptor = undefined;
    var map_key: usize = 0;
    {
        const MAX_MEMORY_DESCRIPTORS = 512;
        var mmap_store: [MAX_MEMORY_DESCRIPTORS]LargeUEFIMemoryDescriptor = undefined;
        var mmap_size: usize = @sizeOf(@TypeOf(mmap_store));
        var descriptor_size: usize = 0;
        var descriptor_version: u32 = 0;
        var status = bs.getMemoryMap(&mmap_size, @ptrCast([*]SmallUEFIMemoryDescriptor, &mmap_store), &map_key, &descriptor_size, &descriptor_version);
        if (status != ZSUEFIStatus.Success) {
            fatal("Failed to get memory map! Error: {}", .{status});
        }

        if (descriptor_size != @sizeOf(LargeUEFIMemoryDescriptor)) {
            fatal(
                "Unexpected size of memory descriptor. Expected: {}, Actual {}. Version: {}",
                .{
                    @sizeOf(LargeUEFIMemoryDescriptor),
                    descriptor_size,
                    descriptor_version,
                },
            );
        }

        const num_descriptors = mmap_size / descriptor_size;
        memory_map = bootloader_arena.push_slice(LargeUEFIMemoryDescriptor, num_descriptors);
        @memcpy(memory_map, mmap_store[0..num_descriptors]);
    }

    //NOTE: Do not call println or any UEFI functions here!!!

    //exit boot services
    {
        const status = bs.exitBootServices(handle, map_key);
        if (status != ZSUEFIStatus.Success) {
            fatal(
                "Failed to exit boot services! Error: {}, Handle: {}, Map key: {X}",
                .{ status, handle, map_key },
            );
        }
        console.exit_boot_services();
    }
    {
        system_table.console_in_handle = null;
        system_table.con_in = null;
        system_table.console_out_handle = null;
        system_table.con_out = null;
        system_table.standard_error_handle = null;
        system_table.std_err = null;
        system_table.boot_services = null;
    }

    //TODO: multicore
    // draw_strip(
    //     0,
    //     cores_detected,
    //     screen,
    // );
    // @atomicStore(bool, &print_strip, true, .SeqCst);

    const kernel_start_context_bytes = b: {
        // const size = toolbox.next_power_of_2(
        //     screen.frame_buffer.len * @sizeOf(w64.Pixel) * 2 + w64.MEMORY_PAGE_SIZE,
        // );
        const size = toolbox.mb(128); //64 MB should be big enough!!!
        for (memory_map) |*desc| {
            switch (desc.type) {
                .ConventionalMemory => case: {
                    //must be aligned on a 2MB boundary
                    const target_address = toolbox.align_up(desc.physical_start, w64.MEMORY_PAGE_SIZE);
                    const padding = target_address - desc.physical_start;
                    const descriptor_size = desc.number_of_pages * UEFI_PAGE_SIZE;
                    if (padding > descriptor_size) {
                        break :case;
                    }

                    if (descriptor_size - padding >= size) {
                        const ret = @ptrFromInt([*]u8, target_address)[0..size];
                        desc.number_of_pages -= size / UEFI_PAGE_SIZE;
                        desc.physical_start += size;
                        break :b ret;
                    }
                },
                else => {},
            }
        } else {
            fatal("Failed to find enough memory for kernel start context.", .{});
        }
    };
    var global_arena = toolbox.Arena.init_with_buffer(kernel_start_context_bytes);

    //allocate back buffer
    screen.back_buffer = global_arena.push_slice_clear(w64.Pixel, screen.frame_buffer.len);
    console.init_graphics_console(screen);
    println("back buffer len: {}, screen len: {}", .{ screen.back_buffer.len, screen.frame_buffer.len });

    var kernel_parse_result = parse_kernel_elf(&global_arena) catch |e| {
        //TODO: proper fatal function
        println("failed to parse kernel elf: {}", .{e});
        toolbox.hang();
    };
    var next_free_virtual_address = kernel_parse_result.next_free_virtual_address;
    const pml4_table = global_arena.push_clear(amd64.PageMappingLevel4Table);

    //map recursive mapping
    //0xFFFFFF00 00000000 - 0xFFFFFF7F FFFFFFFF   Page Mapping Level 1 (Page Tables)
    //0xFFFFFF7F 80000000 - 0xFFFFFF7F BFFFFFFF   Page Mapping Level 2 (Page Directories)
    //0xFFFFFF7F BFC00000 - 0xFFFFFF7F BFDFFFFF   Page Mapping Level 3 (PDPTs / Page-Directory-Pointer Tables)
    //0xFFFFFF7F BFDFE000 - 0xFFFFFF7F BFDFEFFF   Page Mapping Level 4 (PML4)
    pml4_table.entries[510] = .{
        .present = true,
        .write_enable = true,
        .ring3_accessible = false,
        .writethrough = false,
        .cache_disable = false,
        .pdp_base_address = @intCast(
            u40,
            @intFromPtr(pml4_table) >> 12,
        ),
        .no_execute = false,
    };

    var free_conventional_memory = toolbox.DynamicArray(w64.ConventionalMemoryDescriptor)
        .init(&global_arena, memory_map.len);
    var mapped_memory = toolbox.DynamicArray(w64.VirtualMemoryMapping)
        .init(&global_arena, memory_map.len);
    {

        //map kernel global arena
        map_virtual_memory(
            @intFromPtr(kernel_start_context_bytes.ptr),
            &next_free_virtual_address,
            kernel_start_context_bytes.len / w64.MEMORY_PAGE_SIZE,
            .ConventionalMemory,
            &mapped_memory,
            pml4_table,
            &global_arena,
        );

        //map frame buffer
        var frame_buffer_virtual_address: u64 = w64.FRAME_BUFFER_VIRTUAL_ADDRESS;
        map_virtual_memory(
            @intFromPtr(screen.frame_buffer.ptr),
            &frame_buffer_virtual_address,
            //+ 1 just in case
            (screen.frame_buffer.len * @sizeOf(w64.Pixel) / w64.MEMORY_PAGE_SIZE) + 1,
            .FrameBufferMemory,
            &mapped_memory,
            pml4_table,
            &global_arena,
        );

        //need to identity map the start_kernel function since we load CR3 there
        //kernel should unmap this
        {
            var virtual_address = @intFromPtr(&start_kernel);
            map_virtual_memory(
                @intFromPtr(&start_kernel),
                &virtual_address,
                1,
                .ToBeUnmapped,
                &mapped_memory,
                pml4_table,
                &global_arena,
            );
            virtual_address = @intFromPtr(&processor_entry);
            map_virtual_memory(
                @intFromPtr(&processor_entry),
                &virtual_address,
                1,
                .ToBeUnmapped,
                &mapped_memory,
                pml4_table,
                &global_arena,
            );
        }

        //map kernel itself
        for (kernel_parse_result.page_table_data.items()) |data| {
            var virtual_address = data.destination_virtual_address;
            map_virtual_memory(
                @intFromPtr(data.data.ptr),
                &virtual_address,
                (data.data.len / w64.MEMORY_PAGE_SIZE) + 1,
                .ConventionalMemory,
                &mapped_memory,
                pml4_table,
                &global_arena,
            );
        }

        for (memory_map) |desc| {
            const descriptor_size = desc.number_of_pages * UEFI_PAGE_SIZE;
            switch (desc.type) {
                .ConventionalMemory => {
                    if (descriptor_size >= w64.MEMORY_PAGE_SIZE) {
                        const number_of_pages = descriptor_size / w64.MEMORY_PAGE_SIZE;
                        free_conventional_memory.append(.{
                            .physical_address = desc.physical_start,
                            .number_of_pages = number_of_pages,
                        });
                    }
                },
                .ACPIMemoryNVS,
                .ACPIReclaimMemory,
                .MemoryMappedIO,
                .MemoryMappedIOPortSpace,
                => {
                    map_virtual_memory(
                        desc.physical_start,
                        &next_free_virtual_address,
                        desc.number_of_pages,
                        .MMIOMemory,
                        &mapped_memory,
                        pml4_table,
                        &global_arena,
                    );
                },
                else => {
                    //TODO?
                },
            }
        }
    }

    //dump debug memory data
    {
        println("start context address: 0x{X}, len: {}", .{
            @intFromPtr(kernel_start_context_bytes.ptr),
            kernel_start_context_bytes.len,
        });
        {
            for (free_conventional_memory.items()) |desc| {
                println("Conventional Memory:  paddr: {X}, number of pages: {}", .{
                    desc.physical_address,
                    desc.number_of_pages,
                });
            }
        }
        {
            for (mapped_memory.items()) |desc| {
                println("Mapped Memory: vaddr: {X}, paddr: {X}, size: {}, type: {s}", .{
                    desc.virtual_address,
                    desc.physical_address,
                    desc.size,
                    @tagName(desc.memory_type),
                });
            }
        }
        println("Space left in arena: {}", .{global_arena.data.len - global_arena.pos});
    }

    const application_processor_contexts =
        bootstrap_application_processors(&global_arena, number_of_enabled_processors);

    //wait for application processors to come up
    {
        for (application_processor_contexts) |context| {
            while (!@atomicLoad(bool, &context.is_booted, .SeqCst)) {
                std.atomic.spinLoopHint();
            }
        }
    }
    println("APs booted!", .{});

    var kernel_start_context = global_arena.push(w64.KernelStartContext);
    kernel_start_context.* = .{
        .rsdp = physical_to_virtual_pointer(rsdp, mapped_memory.items()),
        .screen = screen,
        .mapped_memory = physical_to_virtual_pointer(mapped_memory.items(), mapped_memory.items()),
        .free_conventional_memory = physical_to_virtual_pointer(free_conventional_memory.items(), mapped_memory.items()),
        .global_arena = global_arena,
        .application_processor_contexts = application_processor_contexts,
    };
    kernel_start_context.screen.back_buffer = physical_to_virtual_pointer(
        kernel_start_context.screen.back_buffer,
        mapped_memory.items(),
    );
    kernel_start_context.screen.frame_buffer = physical_to_virtual_pointer(
        kernel_start_context.screen.frame_buffer,
        mapped_memory.items(),
    );
    kernel_start_context.global_arena.data = physical_to_virtual_pointer(
        kernel_start_context.global_arena.data,
        mapped_memory.items(),
    );

    start_kernel(
        pml4_table,
        kernel_start_context,
        mapped_memory.items(),
        kernel_parse_result.entry_point,
    );
}
fn start_kernel(
    pml4_table: *amd64.PageMappingLevel4Table,
    kernel_start_context: *w64.KernelStartContext,
    mapped_memory: []w64.VirtualMemoryMapping,
    entry_point: u64,
) noreturn {
    asm volatile (
        \\movq %[cr3_data], %%cr3
        \\movq %[stack_virtual_address], %%rsp
        \\movq %[ksc_addr], %%rdi
        \\jmpq *%[entry_point] #here we go!!!!
        \\ud2 #this instruction is for searchability in the disassembly
        :
        : [cr3_data] "r" (@intFromPtr(pml4_table)),
          [stack_virtual_address] "r" (KERNEL_STACK_BOTTOM_ADDRESS),
          [ksc_addr] "r" (@intFromPtr(physical_to_virtual_pointer(
            kernel_start_context,
            mapped_memory,
          ))),
          [entry_point] "r" (entry_point),
        : "rdi", "rsp", "cr3"
    );
    toolbox.hang();
}
extern var processor_bootstrap_program_start: u8;
extern var processor_bootstrap_program_end: u8;

fn bootstrap_application_processors(arena: *toolbox.Arena, number_of_processors: u64) []*w64.BootloaderProcessorContext {
    const IA32_APIC_BASE_MSR = 0x1B;
    const CPUID_FEAT_EDX_APIC = 1 << 9;
    const number_of_aps = number_of_processors - 1;
    var processor_contexts = arena.push_slice(*w64.BootloaderProcessorContext, number_of_aps);
    {
        const cpuid = amd64.cpuid(1);
        if (cpuid.edx & CPUID_FEAT_EDX_APIC == 0) {
            fatal("CPU does not support multicore processing as required!", .{});
        }

        //copy in bootstrapping program
        const PROCESSOR_BOOTSTRAP_PROGRAM_ADDRESS = 0x1000;
        {
            const program_len = @intFromPtr(&processor_bootstrap_program_end) -
                @intFromPtr(&processor_bootstrap_program_start);

            const dest = @ptrFromInt(
                [*]u8,
                PROCESSOR_BOOTSTRAP_PROGRAM_ADDRESS,
            )[0..program_len];
            const src = @ptrFromInt(
                [*]u8,
                @intFromPtr(&processor_bootstrap_program_start),
            )[0..program_len];
            @memcpy(dest, src);

            const cr3 = asm volatile ("mov %%cr3, %[cr3]"
                : [cr3] "=r" (-> u64),
            );

            //allocate stacks and set up context structures
            const stacks =
                arena.push_bytes_aligned(w64.MEMORY_PAGE_SIZE * (number_of_processors - 1), w64.MEMORY_PAGE_SIZE);
            for (0..number_of_aps) |proc| {
                var context = arena.push_clear(w64.BootloaderProcessorContext);
                context.* = .{
                    .is_booted = false,
                    .pml4_table_address = cr3,
                    .application_processor_kernel_entry_data = null,
                };
                const context_data = @bitCast([8]u8, @intFromPtr(context));
                const i = ((proc + 1) * w64.MEMORY_PAGE_SIZE) - @sizeOf(*w64.BootloaderProcessorContext);
                @memcpy(stacks[i .. i + @sizeOf(*w64.BootloaderProcessorContext)], context_data[0..]);

                processor_contexts[proc] = context;
            }

            const stacks_data = @bitCast([8]u8, @intFromPtr(stacks.ptr));
            @memcpy(dest[dest.len - 16 .. dest.len - 8], stacks_data[0..]);

            const cr3_data = @bitCast([8]u8, cr3);
            @memcpy(dest[dest.len - 8 ..], cr3_data[0..]);
        }

        const apic_base_address = amd64.rdmsr(IA32_APIC_BASE_MSR) &
            toolbox.mask_for_bit_range(12, 63, u64);
        const InterruptControlRegisterLow = packed struct(u32) {
            vector: u8, //VEC
            message_type: enum(u3) {
                Fixed = 0b000,
                LowestPriority = 0b001,
                SystemManagementInterrupt = 0b010, //SMI
                RemoteRead = 0b011,
                NonMaskableInterrupt = 0b100, //NMI
                Initialize = 0b101, //INIT
                Startup = 0b110,
                ExternalInterrupt = 0b111,
            }, //MT
            destination_mode: enum(u1) {
                SingleAPIC = 0,
                MultipleAPICs = 1,
            }, //DM
            is_sent: bool, //DS
            reserved1: u1 = 0,
            assert_interrupt: bool, //L
            trigger_mode: enum(u1) {
                EdgeTriggered,
                LevelSensitive,
            },
            remote_read_status: u2 = 0, //RRS. don't really care about this
            destination_shorthand: enum(u2) {
                Destination,
                Self,
                AllIncludingSelf,
                AllExcludingSelf,
            },
            reserved2: u12 = 0,
        };
        const InterruptControlRegisterHigh = packed struct(u32) {
            reserved: u24 = 0,
            destination: u8,
        };
        const interrupt_command_register_low = @ptrFromInt(
            *volatile InterruptControlRegisterLow,
            apic_base_address + 0x300,
        );
        const interrupt_command_register_high = @ptrFromInt(
            *volatile InterruptControlRegisterHigh,
            apic_base_address + 0x300 + @sizeOf(InterruptControlRegisterLow),
        );

        interrupt_command_register_high.* = .{
            .destination = 0xFF,
        };
        interrupt_command_register_low.* = .{
            .vector = 0,
            .message_type = .Initialize,
            .destination_mode = .MultipleAPICs,
            .is_sent = false,
            .assert_interrupt = true,
            .trigger_mode = .EdgeTriggered,
            .destination_shorthand = .AllExcludingSelf,
        };

        toolbox.busy_wait(1000);

        interrupt_command_register_high.* = .{
            .destination = 0xFF,
        };
        interrupt_command_register_low.* = .{
            .vector = PROCESSOR_BOOTSTRAP_PROGRAM_ADDRESS >> 12,
            .message_type = .Startup,
            .destination_mode = .MultipleAPICs,
            .is_sent = false,
            .assert_interrupt = true,
            .trigger_mode = .EdgeTriggered,
            .destination_shorthand = .AllExcludingSelf,
        };
    }
    return processor_contexts;
}

fn draw_test(screen: w64.Screen) noreturn {
    //draw test
    {
        // bounce_demo(screen);

        for (screen.back_buffer) |*p| p.colors = .{
            .r = 0,
            .g = 0,
            .b = 0,
        };
        var cursor_x: usize = 0;
        var cursor_y: usize = 0;
        for (w64.CHARACTERS) |bitmap| {
            for (0..w64.CharacterBitmap.HEIGHT) |y| {
                for (0..w64.CharacterBitmap.WIDTH) |x| {
                    screen.back_buffer[(y + cursor_y) * screen.stride + x + cursor_x] = bitmap.pixels[y * w64.CharacterBitmap.WIDTH + x];
                }
            }
            cursor_x += w64.CharacterBitmap.KERNING;
            if (cursor_x >= screen.width - w64.CharacterBitmap.KERNING) {
                cursor_x = 0;
                cursor_y += w64.CharacterBitmap.HEIGHT + 1;
            }
        }
        @memcpy(screen.frame_buffer, screen.back_buffer);
    }
}
fn bounce_demo(screen: w64.Screen) noreturn {
    //TODO test with back buffer
    var cursor_y: usize = 0;
    var upwards = false;
    while (true) {
        if (upwards) {
            cursor_y -= 1;
        } else {
            cursor_y += 1;
        }
        if (cursor_y >= screen.height - w64.CharacterBitmap.HEIGHT) {
            upwards = true;
        } else if (cursor_y == 0) {
            upwards = false;
        }
        for (screen.back_buffer) |*p| p.colors = .{
            .r = 0,
            .g = 0,
            .b = 0,
        };
        draw_rect(screen, 500, cursor_y);
        {
            var cursor_x: usize = 0;
            for (w64.CHARACTERS) |bitmap| {
                for (0..w64.CharacterBitmap.HEIGHT) |y| {
                    for (0..w64.CharacterBitmap.WIDTH) |x| {
                        screen.back_buffer[(y + cursor_y) * screen.stride + (x + cursor_x)] = bitmap.pixels[y * w64.CharacterBitmap.WIDTH + x];
                    }
                }
                cursor_x += w64.CharacterBitmap.KERNING;
            }
        }
        @memcpy(screen.frame_buffer, screen.back_buffer);
        for (0..100000) |_| {
            std.atomic.spinLoopHint();
        }
    }
}

fn draw_rect(screen: w64.Screen, x: usize, y: usize) void {
    const w = 30;
    const h = 20;

    for (y..y + h) |py| {
        for (x..x + w) |px| {
            screen.back_buffer[py * screen.stride + px] = .{ .colors = .{
                .r = 0xFF,
                .g = 0xFF,
                .b = 0xFF,
            } };
        }
    }
}
fn map_virtual_memory(
    physical_address: u64,
    virtual_address: *u64,
    number_of_pages: usize,
    memory_type: w64.MemoryType,
    mapped_memory: *toolbox.DynamicArray(w64.VirtualMemoryMapping),
    pml4_table: *amd64.PageMappingLevel4Table,
    arena: *toolbox.Arena,
) void {
    const page_size: usize = switch (memory_type) {
        .ConventionalMemory, .FrameBufferMemory => w64.MEMORY_PAGE_SIZE,
        .MMIOMemory, .ToBeUnmapped => w64.MMIO_PAGE_SIZE,
    };
    virtual_address.* = toolbox.align_down(virtual_address.*, page_size);
    const aligned_physical_address = toolbox.align_down(physical_address, page_size);

    const size = number_of_pages * page_size;
    //NOTE proabably unnecessary.  We map the kernel in 2 different virtual addresses and that's fine
    // for (mapped_memory.items()) |*mm| {
    //     if (physical_address >= mm.physical_address and
    //         physical_address < mm.physical_address + mm.size)
    //     {
    //         toolbox.panic("{X} already mapped!", .{physical_address});
    //     }
    // }
    defer {
        mapped_memory.append(.{
            .physical_address = aligned_physical_address,
            .virtual_address = virtual_address.*,
            .size = size,
            .memory_type = memory_type,
        });

        //needs to be +%= for stack memory since it would increment out of 64 bit space
        virtual_address.* +%= size;
    }

    for (0..number_of_pages) |page_number| {
        const vaddr = virtual_address.* + page_number * page_size;
        const paddr = aligned_physical_address + page_number * page_size;
        const pml4t_index = (vaddr >> 39) & 0b1_1111_1111;

        var pml4e = &pml4_table.entries[pml4t_index];
        if (!pml4e.present) {
            const pdp = arena.push_clear(amd64.PageDirectoryPointer);
            const pdp_address = @intFromPtr(pdp);
            toolbox.assert(
                (pdp_address & 0xFFF) == 0,
                "PDP not aligned! Address was: {}",
                .{pdp_address},
            );
            pml4e.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .writethrough = false,
                .cache_disable = false,
                .pdp_base_address = @intCast(
                    u40,
                    pdp_address >> 12,
                ),
                .no_execute = false,
            };
        }

        var pdp = @ptrFromInt(
            *amd64.PageDirectoryPointer,
            @as(u64, pml4e.pdp_base_address) << 12,
        );
        const pdp_index = (vaddr >> 30) & 0b1_1111_1111;
        var pdpe = &pdp.entries[pdp_index];
        if (!pdpe.present) {
            //NOTE: it doesn't matter if it's PageDirectory2MB or PageDirectory4KB
            //      since they are the same size and we are not accessing them here
            const pd = arena.push_clear(amd64.PageDirectory2MB);
            const pd_address = @intFromPtr(pd);
            toolbox.assert(
                (pd_address & 0xFFF) == 0,
                "PD not aligned! Address was: {}",
                .{pd_address},
            );
            pdpe.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .writethrough = false,
                .cache_disable = false,
                .pd_base_address = @intCast(
                    u40,
                    pd_address >> 12,
                ),
                .no_execute = false,
            };
        }

        const pd_index = (vaddr >> 21) & 0b1_1111_1111;
        switch (memory_type) {
            .ConventionalMemory, .FrameBufferMemory => {
                var pd = @ptrFromInt(
                    *amd64.PageDirectory2MB,
                    @as(u64, pdpe.pd_base_address) << 12,
                );
                var pde = &pd.entries[pd_index];
                if (!pde.present) {
                    pde.* = .{
                        .present = true,
                        .write_enable = true,
                        .ring3_accessible = false,
                        .writethrough = false,
                        .cache_disable = false,
                        .page_attribute_table_bit = 0,
                        .global = true,
                        .physical_page_base_address = @intCast(
                            u31,
                            paddr >> 21,
                        ),
                        .memory_protection_key = 0,
                        .no_execute = false,
                    };
                } else {
                    const mapped_paddr = @as(u64, pde.physical_page_base_address) << 21;
                    if (mapped_paddr != aligned_physical_address) {
                        toolbox.panic("Trying to map {X} to {X}, when it is already mapped to {X}!", .{
                            vaddr,
                            paddr,
                            mapped_paddr,
                        });
                    }
                }
            },
            .MMIOMemory, .ToBeUnmapped => {
                var pd = @ptrFromInt(
                    *amd64.PageDirectory4KB,
                    @as(u64, pdpe.pd_base_address) << 12,
                );
                var pde = &pd.entries[pd_index];
                if (!pde.present) {
                    const pt = arena.push_clear(amd64.PageTable);

                    const pt_address = @intFromPtr(pt);
                    toolbox.assert(
                        (pt_address & 0xFFF) == 0,
                        "PT not aligned! Address was: {}",
                        .{pt_address},
                    );
                    pde.* = .{
                        .present = true,
                        .write_enable = true,
                        .ring3_accessible = false,
                        .writethrough = false,
                        .cache_disable = false,
                        .pt_base_address = @intCast(
                            u40,
                            pt_address >> 12,
                        ),
                        .no_execute = false,
                    };
                }
                var pt = @ptrFromInt(
                    *amd64.PageTable,
                    @as(u64, pde.pt_base_address) << 12,
                );
                const pt_index = (vaddr >> 12) & 0b1_1111_1111;
                var pte = &pt.entries[pt_index];
                if (!pte.present) {
                    pte.* = .{
                        .present = true,
                        .write_enable = true,
                        .ring3_accessible = false,
                        .writethrough = false,
                        .cache_disable = true, //disable cache for MMIO
                        .page_attribute_table_bit = 0,
                        .global = true,
                        .physical_page_base_address = @intCast(
                            u40,
                            paddr >> 12,
                        ),
                        .memory_protection_key = 0,
                        .no_execute = false,
                    };
                } else {
                    const mapped_paddr = @as(u64, pte.physical_page_base_address) << 12;
                    if (mapped_paddr != aligned_physical_address) {
                        toolbox.panic("Trying to map {X} to {X}, when it is already mapped to {X}!", .{
                            vaddr,
                            paddr,
                            mapped_paddr,
                        });
                    }
                }
            },
        }
    }
}
fn parse_kernel_elf(arena: *toolbox.Arena) !KernelParseResult {
    var page_table_data = toolbox.DynamicArray(PageTableData).init(arena, 32);
    var kernel_image_byte_stream = std.io.fixedBufferStream(KERNEL_ELF);
    var header = try std.elf.Header.read(&kernel_image_byte_stream);

    var next_free_virtual_address: usize = 0;
    var it = header.program_header_iterator(&kernel_image_byte_stream);
    var top_of_stack_address: usize = 0;
    while (it.next() catch null) |program_header| {
        switch (program_header.p_type) {
            std.elf.PT_LOAD => {
                if (program_header.p_memsz == 0) {
                    continue;
                }
                const is_executable = program_header.p_flags & std.elf.PF_X != 0;
                const is_writable = program_header.p_flags & std.elf.PF_W != 0;
                const data_to_copy = KERNEL_ELF[program_header.p_offset .. program_header.p_offset + program_header.p_filesz];
                var data = arena.push_bytes_aligned(data_to_copy.len, w64.MEMORY_PAGE_SIZE);
                @memcpy(data, data_to_copy);
                const page_table_setup_data = PageTableData{
                    .destination_virtual_address = program_header.p_vaddr,
                    .data = data,
                    .number_of_bytes = toolbox.align_up(program_header.p_memsz, w64.MEMORY_PAGE_SIZE),
                    .is_executable = is_executable,
                    .is_writable = is_writable,
                };
                toolbox.assert(page_table_setup_data.data.len <= page_table_setup_data.number_of_bytes, "number of bytes to copy should be no greater than the number of bytes to allocate", .{});
                page_table_data.append(page_table_setup_data);
                next_free_virtual_address = @max(
                    next_free_virtual_address,
                    toolbox.align_down(program_header.p_vaddr + program_header.p_memsz + w64.MEMORY_PAGE_SIZE, w64.MEMORY_PAGE_SIZE),
                );
                println("ELF vaddr: {X}, size: {X}", .{ program_header.p_vaddr, program_header.p_memsz });
            },
            std.elf.PT_GNU_STACK => {
                const stack_size = toolbox.align_up(program_header.p_memsz, w64.MEMORY_PAGE_SIZE);
                top_of_stack_address = KERNEL_STACK_BOTTOM_ADDRESS - stack_size;
                println("stack size: {}", .{stack_size});
                const page_table_setup_data = PageTableData{
                    .destination_virtual_address = top_of_stack_address,
                    .data = arena.push_bytes_aligned(stack_size, w64.MEMORY_PAGE_SIZE),
                    .number_of_bytes = stack_size,
                    .is_executable = false,
                    .is_writable = true,
                };

                page_table_data.append(page_table_setup_data);
            }, //TODO
            std.elf.PT_GNU_RELRO => {},
            std.elf.PT_PHDR => {},
            //else => toolbox.panic("Unexpected ELF section: {x}", .{program_header.p_type}),
            else => return error.UnexpectedELFSection,
        }
    }
    return .{
        .next_free_virtual_address = next_free_virtual_address,
        .entry_point = header.entry,
        .top_of_stack_address = top_of_stack_address,
        .page_table_data = page_table_data,
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    println(fmt, args);
    toolbox.hang();
}
fn physical_to_virtual_pointer(physical: anytype, mappings: []w64.VirtualMemoryMapping) @TypeOf(physical) {
    const T = @TypeOf(physical);
    const pointer_size = switch (@typeInfo(T)) {
        .Pointer => |ptr| ptr.size,
        else => {
            @compileError("Must be a pointer!");
        },
    };
    const physical_address = if (pointer_size == .Slice)
        @intFromPtr(physical.ptr)
    else
        @intFromPtr(physical);

    const virtual_address = w64.physical_to_virtual(
        physical_address,
        mappings,
    ) catch
        fatal(
        "Failed to find mapping for physical address: {X}",
        .{physical_address},
    );
    if (pointer_size == .Slice) {
        const Child = @typeInfo(T).Pointer.child;
        return @ptrFromInt([*]Child, virtual_address)[0..physical.len];
    }
    return @ptrFromInt(T, virtual_address);
}

//TODO:
//multicore

// const BootstrapCoreContext = struct {
//     cores_started: *usize,
//     mp: *mpsp.MPServiceProtocol,
//     print_strip: *const bool,

//     cores_detected: usize,
//     core_id: usize,
//     screen: Screen,
// };
// fn ap_entry_point(arg: ?*anyopaque) callconv(.C) void {
//     const ctx = @ptrCast(*BootstrapCoreContext, @alignCast(@alignOf(mpsp.MPServiceProtocol), arg.?));

//     _ = @atomicRmw(usize, ctx.cores_started, .Add, 1, .Monotonic);

//     while (!@atomicLoad(bool, ctx.print_strip, .SeqCst)) {
//         std.atomic.spinLoopHint();
//         serialprintln("before ", .{});
//     }
//     serialprintln("yes", .{});

//     draw_strip(ctx.core_id, ctx.cores_detected, ctx.screen);
//     toolbox.hang();
// }
// fn draw_strip(core_id: usize, cores_detected: usize, screen: Screen) void {
//     const height = screen.height / cores_detected;
//     const y0 = core_id * height;
//     serialprintln(
//         "y0: {}, height: {}, screen width: {}, screen height: {}, screen stride: {}",
//         .{ y0, height, screen.width, screen.height, screen.stride },
//     );
//     for (y0..y0 + height) |y| {
//         for (0..screen.width) |x| {
//             screen.frame_buffer[y * screen.stride + x].colors = .{
//                 .r = @intCast(u8, core_id) * 100,
//                 .g = 0,
//                 .b = 0,
//             };
//         }
//     }
// }

// var cores_detected: usize = 1;
// var core_contexts = toolbox.DynamicArray(*BootstrapCoreContext).init(&bootloader_arena, 128);
// var print_strip = false;
// {
//     var cores_started: usize = 1;
//     var core_id: usize = 1;
//     {
//         var mp: *mpsp.MPServiceProtocol = undefined;
//         var status = bs.locateProtocol(&mpsp.MPServiceProtocol.guid, null, @ptrCast(*?*anyopaque, &mp));
//         if (status != ZSUEFIStatus.Success) {
//             fatal("Cannot init multicore support! Error locating MP protocol: {}", .{status});
//         }

//         var number_of_enabled_processors: usize = 0;
//         var number_of_processors: usize = 0;
//         status = mp.mp_services_get_number_of_processors(&number_of_processors, &number_of_enabled_processors);
//         if (status != ZSUEFIStatus.Success) {
//             fatal("Cannot init multicore support! Error getting number of processors: {}", .{status});
//         }

//         var dummy_event: std.os.uefi.Event = undefined;
//         status = bs.createEvent(
//             std.os.uefi.tables.BootServices.event_notify_signal,
//             std.os.uefi.tables.BootServices.tpl_callback,
//             event_notification_callback,
//             null,
//             &dummy_event,
//         );
//         if (status != ZSUEFIStatus.Success) {
//             fatal("Failed to create dummy event to start multicore support! Error: {}", .{status});
//         }

//         //processor 0 is the BSP (main processor)
//         for (1..number_of_enabled_processors) |i| {
//             var processor_info_buffer: mpsp.ProcessorInformation = undefined;
//             status = mp.mp_services_get_processor_info(i, &processor_info_buffer);
//             if (status != ZSUEFIStatus.Success) {
//                 fatal("Failed to start multicore support! Error getting processor info: {}", .{status});
//             }

//             //ignore hyperthreads
//             if (processor_info_buffer.location.thread != 0) {
//                 continue;
//             }
//             var ctx = bootloader_arena.push(BootstrapCoreContext);
//             ctx.* = .{
//                 .mp = mp,
//                 .cores_started = &cores_started,
//                 .core_id = core_id,

//                 .screen = screen,
//                 .cores_detected = number_of_enabled_processors,
//                 .print_strip = &print_strip,
//             };
//             core_contexts.append(ctx);

//             core_id += 1;
//             cores_detected += 1;
//             status = mp.mp_services_startup_this_ap(ap_entry_point, i, dummy_event, 0, ctx, null);
//             if (status != ZSUEFIStatus.Success) {
//                 fatal("Failed to start multicore support! Error: {}", .{status});
//             }
//         }
//     }
//     while (@atomicLoad(usize, &cores_started, .Monotonic) < cores_detected) {
//         std.atomic.spinLoopHint();
//     }
//     uefiprintln("Started {} cores", .{cores_started});
// }

comptime {
    asm (
        \\.extern processor_entry
        \\.macro hang
        \\.hang: jmp .hang
        \\.endm
        \\processor_bootstrap_program_start:
        \\.equ LOAD_ADDRESS, 0x1000
        \\.equ STACK_SIZE, (1 << 21)
        \\.code16
        \\cli
        \\cld
        \\
        \\lgdt (smp_gdt - processor_bootstrap_program_start) + LOAD_ADDRESS
        \\mov %cr0, %eax 
        \\bts $0, %eax
        \\mov %eax, %cr0
        \\ljmp $0x8, $((.mode32 - processor_bootstrap_program_start) + LOAD_ADDRESS)
        \\
        \\.code32
        \\.mode32:
        \\mov $0x10, %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %fs
        \\mov %ax, %gs
        \\mov %ax, %ss
        \\mov %cr0, %eax
        \\#btr $29, %eax  #NW bit probably ignored 
        \\btr $30, %eax  #enable cache
        \\mov %eax, %cr0 
        \\
        \\mov %cr4, %eax 
        \\bts $5, %eax #enable PAE
        \\mov %eax, %cr4 
        \\
        \\mov (cr3_data - processor_bootstrap_program_start) + LOAD_ADDRESS, %eax
        \\mov %eax, %cr3
        \\mov $0xc0000080, %ecx 
        \\rdmsr
        \\bts $8, %eax  #enable long mode
        \\bts $11, %eax #enable no-execute
        \\wrmsr
        \\
        \\mov %cr0, %eax
        \\bts $31, %eax #enable paging
        \\bts $1, %eax #needed for SSE. set coprocessor monitoring  CR0.MP
        \\mov %eax, %cr0 
        \\mov %cr4, %eax 
        \\or $3 << 9, %ax  #needed for SSE. set CR4.OSFXSR and CR4.OSXMMEXCPT at the same time
        \\#TODO do we need to enable any other flags here?
        \\mov %eax, %cr4 
        \\ljmp $0x18, $(.mode64 - processor_bootstrap_program_start) + LOAD_ADDRESS
        \\
        \\.code64
        \\.mode64:
        \\mov $0x20, %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %fs
        \\mov %ax, %gs
        \\mov %ax, %ss
        \\
        \\#get LAPIC base address
        \\mov $0x1B, %ecx 
        \\rdmsr
        \\shl $32, %rdx
        \\or %rax, %rdx
        \\
        \\# Mask off low 12 bits of base address since they misc flags
        \\mov $0xFFFFF000, %rax
        \\and %rax, %rdx
        \\
        \\# put LAPIC ID in %rdi
        \\mov 0x20(%rdx), %edi
        \\shr $24, %rdi
        \\
        \\mov stacks_base_address(%rip), %rbx
        \\mov %rdi, %rax
        \\dec %rax
        \\mov $STACK_SIZE, %r8
        \\mul %r8
        \\lea (%rbx,%rax), %rsp
        \\add %r8, %rsp
        \\
        \\
        \\#bottom 8 bytes contains the context address
        \\sub $8, %rsp
        \\
        \\#Microsoft ABI has first parameter in rcx
        \\mov (%rsp), %rcx
        \\
        \\
        \\#Microsoft ABI has second parameter in rdx
        \\mov %rdi, %rdx
        \\movabs $processor_entry, %rax
        \\jmp *%rax
        \\.loop: jmp .loop
        \\ud2
        \\
        \\
        \\.align 16
        \\smp_gdt:
        \\  .word .size - 1    # GDT size
        \\  .ptr:
        \\     .long (.start - processor_bootstrap_program_start) + LOAD_ADDRESS       # GDT start address
        \\
        \\  .start:
        \\    # Null descriptor (required)
        \\    .word 0x0000       # Limit
        \\    .word 0x0000       # Base (low 16 bits)
        \\    .byte 0x00         # Base (mid 8 bits)
        \\    .byte 0b00000000    # Access
        \\    .byte 0b00000000    # Granularity
        \\    .byte 0x00         # Base (high 8 bits)
        \\
        \\    # 32-bit code
        \\    .word 0xffff       # Limit
        \\    .word 0x0000       # Base (low 16 bits)
        \\    .byte 0x00         # Base (mid 8 bits)
        \\    .byte 0b10011010    # Access
        \\    .byte 0b11001111    # Granularity
        \\    .byte 0x00         # Base (high 8 bits)
        \\
        \\    # 32-bit data
        \\    .word 0xffff       # Limit
        \\    .word 0x0000       # Base (low 16 bits)
        \\    .byte 0x00         # Base (mid 8 bits)
        \\    .byte 0b10010010    # Access
        \\    .byte 0b11001111    # Granularity
        \\    .byte 0x00         # Base (high 8 bits)
        \\
        \\    # 64-bit code
        \\    .word 0x0000       # Limit
        \\    .word 0x0000       # Base (low 16 bits)
        \\    .byte 0x00         # Base (mid 8 bits)
        \\    .byte 0b10011010    # Access
        \\    .byte 0b00100000    # Granularity
        \\    .byte 0x00         # Base (high 8 bits)
        \\
        \\    # 64-bit data
        \\    .word 0x0000       # Limit
        \\    .word 0x0000       # Base (low 16 bits)
        \\    .byte 0x00         # Base (mid 8 bits)
        \\    .byte 0b10010010    # Access
        \\    .byte 0b00000000    # Granularity
        \\    .byte 0x00         # Base (high 8 bits)
        \\
        \\  .end:
        \\
        \\ .equ  .size, (.end - .start)
        \\stacks_base_address:
        \\.space 8, 0
        \\cr3_data:
        \\.space 8, 0
        \\processor_bootstrap_program_end:
        \\
    );
}

export fn processor_entry(
    context: *w64.BootloaderProcessorContext,
    processor_id: u64,
) callconv(.C) noreturn {
    @setAlignStack(256);
    @atomicStore(bool, &context.is_booted, true, .SeqCst);
    println("hello from processor {} ", .{processor_id});
    while (true) {
        if (context.application_processor_kernel_entry_data) |entry_data| {
            asm volatile (
                \\movq %[cr3_data], %%cr3
                \\movq %[stack_virtual_address], %%rsp
                \\movq %[ksc_addr], %%rdi
                \\movq %[processor_id], %%rsi
                \\jmpq *%[entry_point] #here we go!!!!
                \\ud2 #this instruction is for searchability in the disassembly
                :
                : [cr3_data] "r" (entry_data.cr3),
                  [stack_virtual_address] "r" (entry_data.rsp),
                  [ksc_addr] "r" (@intFromPtr(entry_data.start_context_data)),
                  [processor_id] "r" (processor_id),
                  [entry_point] "r" (@intFromPtr(entry_data.entry)),
                : "rdi", "rsp", "cr3"
            );
        }
        std.atomic.spinLoopHint();
    }
}
