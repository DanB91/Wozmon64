const std = @import("std");
const kernel_memory = @import("kernel_memory.zig");
const w64 = @import("wozmon64_kernel.zig");
const kernel = @import("kernel.zig");
const toolbox = @import("toolbox");

const SimpleNetwork = std.os.uefi.protocol.SimpleNetwork;
pub fn init(
    simple_network_protocol_physical_address: u64,
    mapped_memory: []w64.VirtualMemoryMapping,
) void {
    const snp_vaddr = find_virtual_address(
        simple_network_protocol_physical_address,
        mapped_memory,
    );
    toolbox.println("SNP vaddr: 0x{X}, paddr: 0x{X}", .{
        snp_vaddr,
        simple_network_protocol_physical_address,
    });

    const snp: *std.os.uefi.protocol.SimpleNetwork = @ptrFromInt(snp_vaddr);
    {
        const ti = @typeInfo(std.os.uefi.protocol.SimpleNetwork);
        inline for (ti.Struct.fields) |field| {
            //NOTE: this only works for pointers one layer deep.
            //as of this writing, this is sufficient for SimpleNetwork
            if (@typeInfo(field.type) == .Pointer) {
                const paddr = @intFromPtr(@field(snp, field.name));

                const field_vaddr = find_virtual_address(
                    paddr,
                    mapped_memory,
                );
                toolbox.println(
                    "SNP Field {s} field_vaddr: 0x{X}, paddr: 0x{X}",
                    .{ field.name, field_vaddr, paddr },
                );
                @field(snp, field.name) = @ptrFromInt(field_vaddr);
            }
        }
    }
    {
        const status = snp.initialize(0, 0);
        if (status != std.os.uefi.Status.Success) {
            toolbox.panic("Could not initialize network: {}", .{status});
        }
    }
    // toolbox.println("State: {}", .{snp.mode.state});
    // echo_mac_address(snp);
}

fn echo_mac_address(snp: *SimpleNetwork) void {
    kernel.echo_fmt("MAC Address: ", .{});
    for (snp.mode.current_address[0..5]) |byte| {
        kernel.echo_fmt("{X}:", .{byte});
    }
    kernel.echo_fmt("{X}\n", .{snp.mode.current_address[5]});
}

fn find_virtual_address(physical_address: u64, mapped_memory: []w64.VirtualMemoryMapping) u64 {
    for (mapped_memory) |desc| {
        if (!(desc.memory_type == .UEFIMemory and
            physical_address >= desc.physical_address and
            physical_address < desc.physical_address + desc.size))
        {
            continue;
        }
        return desc.virtual_address +
            (physical_address - desc.physical_address);
    }

    toolbox.panic(
        "Expected physical address: {X} to be mapped, but wasn't.",
        .{physical_address},
    );
}
