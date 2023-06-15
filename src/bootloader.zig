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

        const frame_buffer = @intToPtr([*]w64.Pixel, gop.mode.frame_buffer_base)[0 .. gop.mode.frame_buffer_size / @sizeOf(w64.Pixel)];
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
        const size = toolbox.mb(64); //64 MB should be big enough!!!
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
                        const ret = @intToPtr([*]u8, target_address)[0..size];
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
            @ptrToInt(pml4_table) >> 12,
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
            @ptrToInt(kernel_start_context_bytes.ptr),
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
            @ptrToInt(screen.frame_buffer.ptr),
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
            var virtual_address = @ptrToInt(&start_kernel);
            map_virtual_memory(
                @ptrToInt(&start_kernel),
                &virtual_address,
                1,
                .MMIOMemory,
                &mapped_memory,
                pml4_table,
                &global_arena,
            );
        }

        //map kernel itself
        for (kernel_parse_result.page_table_data.items()) |data| {
            var virtual_address = data.destination_virtual_address;
            map_virtual_memory(
                @ptrToInt(data.data.ptr),
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
                .ACPIMemoryNVS, .ACPIReclaimMemory => {
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
            @ptrToInt(kernel_start_context_bytes.ptr),
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

    var kernel_start_context = global_arena.push(w64.KernelStartContext);
    kernel_start_context.* = .{
        .rsdp = physical_to_virtual_pointer(rsdp, mapped_memory.items()),
        .screen = screen,
        .mapped_memory = physical_to_virtual_pointer(mapped_memory.items(), mapped_memory.items()),
        .free_conventional_memory = physical_to_virtual_pointer(free_conventional_memory.items(), mapped_memory.items()),
        .global_arena = global_arena,
        .bootstrap_address_to_unmap = @ptrToInt(&start_kernel),
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
        : [cr3_data] "r" (@ptrToInt(pml4_table)),
          [stack_virtual_address] "r" (KERNEL_STACK_BOTTOM_ADDRESS),
          [ksc_addr] "r" (@ptrToInt(physical_to_virtual_pointer(
            kernel_start_context,
            mapped_memory,
          ))),
          [entry_point] "r" (entry_point),
        : "rdi", "rsp", "cr3"
    );
    toolbox.hang();
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
        .MMIOMemory => w64.MMIO_PAGE_SIZE,
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
            const pdp_address = @ptrToInt(pdp);
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

        var pdp = @intToPtr(
            *amd64.PageDirectoryPointer,
            @as(u64, pml4e.pdp_base_address) << 12,
        );
        const pdp_index = (vaddr >> 30) & 0b1_1111_1111;
        var pdpe = &pdp.entries[pdp_index];
        if (!pdpe.present) {
            //NOTE: it doesn't matter if it's PageDirectory2MB or PageDirectory4KB
            //      since they are the same size and we are not accessing them here
            const pd = arena.push_clear(amd64.PageDirectory2MB);
            const pd_address = @ptrToInt(pd);
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
                var pd = @intToPtr(
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
            .MMIOMemory => {
                var pd = @intToPtr(
                    *amd64.PageDirectory4KB,
                    @as(u64, pdpe.pd_base_address) << 12,
                );
                var pde = &pd.entries[pd_index];
                if (!pde.present) {
                    const pt = arena.push_clear(amd64.PageTable);

                    const pt_address = @ptrToInt(pt);
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
                var pt = @intToPtr(
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
        @ptrToInt(physical.ptr)
    else
        @ptrToInt(physical);

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
        return @intToPtr([*]Child, virtual_address)[0..physical.len];
    }
    return @intToPtr(T, virtual_address);
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
