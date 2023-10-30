const toolbox = @import("toolbox");
const std = @import("std");
const w64 = @import("wozmon64.zig");
const kernel_memory = @import("kernel_memory.zig");

pub const ACPI2RSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
    length: u32,
    xsdt_address_low: u32,
    xsdt_address_high: u32,
    extended_checksum: u8,
    reserved: [3]u8,
};
//System Descriptor Table
pub const XSDT = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_rev: u32,
    creator_id: u32,
    creator_rev: u32,
};

pub fn root_xsdt_entries(xsdt: *const XSDT) []align(4) u64 {
    const len = (xsdt.length - @sizeOf(XSDT)) / 8;
    const ret = @as(
        [*]align(4) u64,
        @ptrFromInt(@intFromPtr(xsdt) + @sizeOf(XSDT)),
    )[0..len];
    return ret;
}

pub fn find_acpi_table(
    root_xsdt: *const XSDT,
    comptime name: []const u8,
    comptime Table: type,
) !*align(4) const Table {
    const entries = root_xsdt_entries(root_xsdt);
    const table_xsdt = b: {
        for (entries) |physical_address| {
            const entry: *const XSDT = @ptrFromInt(
                kernel_memory.physical_to_virtual(physical_address) catch
                    toolbox.panic(
                    "Could not find mapping for ACPI physical address: {X}",
                    .{physical_address},
                ),
            );
            if (std.mem.eql(u8, name, entry.signature[0..])) {
                if (!is_xsdt_checksum_valid(entry)) {
                    return error.ACPITableBadChecksum;
                }
                break :b entry;
            }
        } else {
            return error.ACPITableNotFound;
        }
    };

    return @ptrCast(table_xsdt);
}

pub fn is_xsdt_checksum_valid(xsdt: *const XSDT) bool {
    var sum: u8 = 0;
    const bytes = @as([*]const u8, @ptrCast(xsdt))[0..xsdt.length];

    for (bytes) |b| {
        sum +%= b;
    }

    return sum == 0;
}

//CPU Core strctures
pub const MADT = extern struct {
    xsdt: XSDT,
    local_controller_address: u32,
    flags: u32,
};

pub const APICType = enum(u8) {
    LocalAPIC = 0,
    IOAPIC = 1,
    InterruptSourceOverride = 2,
    NMISource = 3,
    LocalAPICNMIStructure = 4,
    LocalAPICAddressOverrideStructure = 5,
    PlatformInterruptSources = 8,
    x2APIC = 9,
    x2APICNMIStructure = 10,
    _,
};
pub const MADTEntryHeader = packed struct(u16) {
    apic_type: APICType,
    length: u8,
};

pub const MADTLocalAPIC = packed struct(u64) {
    madt_header: MADTEntryHeader,
    processor_uid: u8,
    id: u8,
    is_enabled: bool,
    is_online_capable: bool,
    padding: u30,
};

//HPET structures
pub const HPET = extern struct {
    xsdt: XSDT align(1),
    hardware_rev_id: u8 align(1),
    counter_comparator_info: packed struct(u8) {
        number_of_comaprators: u5,
        counter_size: enum(u1) {
            //I don't see what counter size is documented in osdev wiki.  Just guessing...
            Bits32,
            Bits64,
        },
        reserved: u1,
        legacy_replacement: bool,
    } align(1),
    pci_vendor_id: u16 align(1),
    address_space_id: u8 align(1), // 0 - system memory, 1 - system I/O
    register_bit_width: u8 align(1),
    register_bit_offset: u8 align(1),
    reserved: u8 align(1),
    address: u64 align(1),
    hpet_number: u8 align(1),
    minimum_tick: u16 align(1),
    page_protection: u8 align(1),

    pub const CapabilitiesAndID = packed struct(u64) {
        rev_id: u8,
        number_of_timers_minus_one: u5,
        counter_size: enum(u1) {
            //I don't see what counter size is documented in osdev wiki.  Just guessing...
            Bits32,
            Bits64,
        },
        reserved: u1,
        legacy_replacement: bool,
        pci_vendor_id: u16,
        counter_clock_period: u32,
    };

    pub const ConfigurationRegister = packed struct(u64) {
        enable_counter: bool,
        enable_legacy_replacement: bool,
        reserved: u62,
    };

    pub fn capabilities_and_id(self: *const HPET) *volatile CapabilitiesAndID {
        return @ptrFromInt(self.address + 0);
    }

    pub fn configruation_register(self: *const HPET) *volatile ConfigurationRegister {
        return @ptrFromInt(self.address + 0x10);
    }

    pub fn main_counter(self: *const HPET) *u64 {
        return @ptrFromInt(self.address + 0xF0);
    }
};

pub const VirtualAddress2MBPage = packed struct(u64) {
    page_offset: u21,
    pd_offset: u9,
    pdp_offset: u9,
    pml4t_offset: u9,
    signed_bits: u16,

    pub fn make_canonical(self: *VirtualAddress2MBPage) void {
        self.signed_bits = if (self.pml4t_offset & 0x100 != 0) 0xFFFF_FFFF else 0;
    }

    pub fn to(self: VirtualAddress2MBPage, comptime T: type) T {
        if (comptime @typeInfo(T) != .Pointer) {
            @compileError("Cannot convert an address into a non pointer value!");
        }
        return self.to(T);
    }
};

pub const VirtualAddress4KBPage = packed struct(u64) {
    page_offset: u12,
    pt_offset: u9,
    pd_offset: u9,
    pdp_offset: u9,
    pml4t_offset: u9,
    signed_bits: u16,

    pub fn make_canonical(self: *VirtualAddress4KBPage) void {
        self.signed_bits = if (self.pml4t_offset & 0x100 != 0) 0xFFFF_FFFF else 0;
    }

    pub fn to(self: VirtualAddress4KBPage, comptime T: type) T {
        if (comptime @typeInfo(T) != .Pointer) {
            @compileError("Cannot convert an address into a non pointer value!");
        }
        const address_number: u64 = @bitCast(self);
        return @ptrFromInt(address_number);
    }
};

pub const PageMappingLevel4Table = struct {
    entries: [512]PageMappingLevel4Entry align(toolbox.kb(4)),
};
pub const PageDirectoryPointer = struct {
    entries: [512]PageDirectoryPointerEntry align(toolbox.kb(4)),
};
pub const PageDirectory2MB = struct {
    entries: [512]PageDirectoryEntry2MB align(toolbox.kb(4)),
};
pub const PageDirectory4KB = struct {
    entries: [512]PageDirectoryEntry4KB align(toolbox.kb(4)),
};
pub const PageTable = struct {
    entries: [512]PageTableEntry align(toolbox.kb(4)),
};

comptime {
    toolbox.static_assert(
        @alignOf(PageMappingLevel4Table) == toolbox.kb(4),
        "Wrong alignment for PageMappingLevel4Table",
    );
    toolbox.static_assert(
        @sizeOf(PageMappingLevel4Table) == toolbox.kb(4),
        "Wrong size for PageMappingLevel4Table",
    );
    toolbox.static_assert(
        @alignOf(PageDirectoryPointer) == toolbox.kb(4),
        "Wrong alignment for PageDirectoryPointer",
    );
    toolbox.static_assert(
        @sizeOf(PageDirectoryPointer) == toolbox.kb(4),
        "Wrong size for PageDirectoryPointer",
    );
    toolbox.static_assert(
        @alignOf(PageDirectory2MB) == toolbox.kb(4),
        "Wrong alignment for PageDirectory2MB",
    );
    toolbox.static_assert(
        @sizeOf(PageDirectory2MB) == toolbox.kb(4),
        "Wrong size for PageDirectory2MB",
    );
    toolbox.static_assert(
        @alignOf(PageDirectory4KB) == toolbox.kb(4),
        "Wrong alignment for PageDirectory4KB",
    );
    toolbox.static_assert(
        @sizeOf(PageDirectory4KB) == toolbox.kb(4),
        "Wrong size for PageDirectory4KB",
    );
    toolbox.static_assert(
        @alignOf(PageDirectory4KB) == toolbox.kb(4),
        "Wrong alignment for PageDirectory4KB",
    );
    toolbox.static_assert(
        @sizeOf(PageTable) == toolbox.kb(4),
        "Wrong size for PageTable",
    );
}

pub const PageMappingLevel4Entry = packed struct(u64) {
    present: bool, //P bit
    write_enable: bool, //R/W bit
    ring3_accessible: bool, //U/S bit
    //TODO look into if these bits are used at all
    writethrough: bool, //PWT bit
    cache_disable: bool, //PCD bit
    accessed: bool = false, //A bit -- was this page accessed? must by manually reset
    ignored: u1 = 0,
    must_be_zero1: u1 = 0,
    must_be_zero2: u1 = 0,
    free_bits1: u3 = 0, //AVL bits
    pdp_base_address: u40,
    free_bits2: u11 = 0, //AVL bits
    no_execute: bool, //NX bit
};

pub const PageDirectoryPointerEntry = packed struct(u64) {
    present: bool, //P bit
    write_enable: bool, //R/W bit
    ring3_accessible: bool, //U/S bit
    writethrough: bool, //PWT bit
    cache_disable: bool, //PCD bit
    accessed: bool = false, //A bit
    ignored1: u1 = 0,
    must_be_zero: u1 = 0,
    ignored2: u1 = 0,
    free_bits1: u3 = 0, //AVL bits
    pd_base_address: u40,
    free_bits2: u11 = 0, //AVL bits
    no_execute: bool, //NX bit
};

pub const PageDirectoryEntry2MB = packed struct(u64) {
    present: bool, //P bit
    write_enable: bool, //R/W bit
    ring3_accessible: bool, //U/S bit
    pat_bit_0: u1, //PWT bit
    pat_bit_1: u1, //PCD bit
    accessed: bool = false, //A bit
    dirty: bool = false, //D bit -- was this page written to? must be manually reset
    must_be_one: u1 = 1,
    global: bool, //G bit -- always resident in TLB
    free_bits1: u3 = 0, //AVL bits
    pat_bit_2: u1, //PAT bit
    must_be_zero: u8 = 0,
    physical_page_base_address: u31,
    free_bits2: u7 = 0, //AVL bits
    memory_protection_key: u4, //MPK bits
    no_execute: bool, //NX bit

};

pub const PageDirectoryEntry4KB = packed struct(u64) {
    present: bool, //P bit
    write_enable: bool, //R/W bit
    ring3_accessible: bool, //U/S bit
    writethrough: bool, //PWT bit
    cache_disable: bool, //PCD bit
    accessed: bool = false, //A bit
    ignored1: u1 = 0,
    must_be_zero: u1 = 0,
    ignored2: u1 = 0,
    free_bits1: u3 = 0, //AVL bits
    pt_base_address: u40,
    free_bits2: u11 = 0, //AVL bits
    no_execute: bool, //NX bit
};

pub const PageTableEntry = packed struct(u64) {
    present: bool, //P bit
    write_enable: bool, //R/W bit
    ring3_accessible: bool, //U/S bit
    pat_bit_0: u1, //PWT bit
    pat_bit_1: u1, //PCD bit
    accessed: bool = false, //A bit
    dirty: bool = false, //D bit -- was this page written to? must be manually reset
    pat_bit_2: u1, //PAT bit
    global: bool, //G bit -- always resident in TLB
    free_bits1: u3 = 0, //AVL bits
    physical_page_base_address: u40,
    free_bits2: u7 = 0, //AVL bits
    memory_protection_key: u4, //MPK bits
    no_execute: bool, //NX bit
};

pub const PageAttributeTableEncodings = enum(u3) {
    Uncachable = 0, //Disable cache completely. Good for MMIO
    WriteCombining = 1,
    WriteThrough = 4, //Writes always hit both memory and cache. Reads can hit just cache. Good for SMP
    WriteProtect = 5,
    Writeback = 6,
    UncachableMinus = 7,
};

pub const PageAttributeTableEntry = packed struct(u8) {
    cache_policy: PageAttributeTableEncodings,
    reserved: u5 = 0,
};

pub const PageAttributeTable = [8]PageAttributeTableEntry;

pub const CPUIDResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};
pub inline fn cpuid(input_eax: u32) CPUIDResult {
    var eax: u32 = 0;
    var ebx: u32 = 0;
    var ecx: u32 = 0;
    var edx: u32 = 0;

    asm volatile (
        \\cpuid
        : [_eax] "={eax}" (eax),
          [_ebx] "={ebx}" (ebx),
          [_ecx] "={ecx}" (ecx),
          [_edx] "={edx}" (edx),
        : [eax] "{eax}" (input_eax),
    );
    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}
pub const IA32_APIC_BASE_MSR = 0x1B;
pub const PAT_MSR = 0x277; //Page attribute table MSR;
pub const IA32_TSC_AUX_MSR = 0xC0000103; //Used for storing processor id

pub inline fn rdmsr(msr: u32) u64 {
    var eax: u64 = 0;
    var edx: u64 = 0;
    asm volatile (
        \\rdmsr
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [msr] "{ecx}" (msr),
    );
    return (edx << 32) | eax;
}

pub inline fn wrmsr(msr: u32, value: u64) void {
    var eax: u32 = @intCast(value & 0xFFFF_FFFF);
    var edx: u32 = @intCast(value >> 32);
    asm volatile (
        \\wrmsr
        :
        : [msr] "{ecx}" (msr),
          [eax] "{eax}" (eax),
          [edx] "{edx}" (edx),
    );
}
pub inline fn rdtsc() u64 {
    var top: u64 = 0;
    var bottom: u64 = 0;
    asm volatile (
        \\rdtsc
        : [top] "={edx}" (top),
          [bottom] "={eax}" (bottom),
    );
    return (top << 32) | bottom;
}

pub const RDTSCPResult = struct {
    timestamp: u64,
    processor_id: u32,
};
pub inline fn rdtscp() RDTSCPResult {
    var top: u64 = 0;
    var bottom: u64 = 0;
    var pid: u32 = 0;
    asm volatile (
        \\rdtscp
        : [top] "={edx}" (top),
          [bottom] "={eax}" (bottom),
          [pid] "={ecx}" (pid),
    );
    return .{
        .timestamp = (top << 32) | bottom,
        .processor_id = pid,
    };
}
//descriptor functions
pub const GDTRegister = extern struct {
    limit: u16 align(1),
    gdt: [*]volatile GDTDescriptor align(1),
};
pub const GDTDescriptorType = enum(u4) {
    ReadOnly,
    ReadOnlyAccessed,
    ReadWrite,
    ReadWriteAccessed,
    ReadOnlyExpandDown,
    ReadOnlyExpandDownAccessed,
    ReadWriteExpandDown,
    ReadWriteExpandDownAccessed,
    ExecuteOnly,
    ExecuteOnlyAccessed,
    ExecuteRead,
    ExecuteReadAccessed,
    ExcecuteOnlyConforming,
    ExecuteOnlyConformingAccessed,
    ExecuteReadConforming,
    ExecuteReadConformingAccessed,
};

pub const GDTSystemDescriptorType32 = enum(u4) {
    InvalidA = 0,
    TSS16BitAvailable = 1,
    LDT = 2,
    TSS16BitBusy = 3,
    CallGate16Bit = 4,
    TaskGate = 5,
    InterruptGate16Bit = 6,
    TrapGate16Bit = 7,
    InvalidB = 8,
    TSS32BitAvailable = 9,
    InvalidC = 10,
    TSS32BitBusy = 11,
    CallGate32Bit = 12,
    InvalidD = 13,
    InterruptGate32Bit = 14,
    TrapGate32Bit = 15,
};

pub const GDTSystemDescriptorType64 = enum(u4) {
    PartOfUpper8Bytes = 0,
    Invalid1 = 1,
    LDT = 2,
    InvalidA,
    InvalidB,
    InvalidC,
    InvalidD,
    InvalidE,
    InvalidF,
    TSS64BitAvailable = 9,
    InvalidG,
    TSS64BitBusy = 11,
    CallGate64Bit = 12,
    InvalidH,
    InterruptGate64Bit = 14,
    TrapGate64Bit = 15,
};

pub const GDTTypeBits = packed union {
    system_type_bits64: GDTSystemDescriptorType64, //when is_not_system_segment is false and is_for_long_mode is true
    system_type_bits32: GDTSystemDescriptorType32, //when is_not_system_segment is false and is_for_long_mode is false
    normal_type_bits: GDTDescriptorType, //when is_not_system_segment is true
};

pub const GDTDescriptor = packed struct(u64) {
    segment_limit_bits_0_to_15: u16, //bits 0-15
    base_addr_bits_0_to_23: u24, //bits 16-39
    //TODO file bug with zig since this you cannot set this union properly
    //type_bits: GDTTypeBits, //bits 40 - 43
    type_bits: u4, //bits 40 - 43
    is_not_system_segment: bool, //bit 44
    privilege_bits: u2, //maximum ring level //bits 45-46
    is_present: bool, //bit 47
    segment_limit_bits_16_to_19: u4, //bits 48 - 51
    unused: u1 = 0, //bit 52
    is_for_long_mode_code: bool, //bit 53
    is_big: bool, //must be false if is_for_long_mode is true //bit 54
    is_granular: bool, //bit 55 //means limit is multiplied by 4096
    base_addr_bits_24_to_31: u8, //bits 56-63
};

pub inline fn get_gdt_register() GDTRegister {
    var ret: GDTRegister = undefined;
    asm volatile ("sgdt %[ret]"
        : [ret] "=m" (ret),
    );
    return ret;
}
pub fn set_gdt_register(gdtr: GDTRegister) void {
    asm volatile ("lgdt %[gdtr]"
        : [gdtr] "=m" (gdtr),
    );
}

pub fn get_gdt() []volatile GDTDescriptor {
    const gdtr = get_gdt_register();
    return gdtr.gdt[0 .. (gdtr.limit + 1) / @sizeOf(GDTDescriptor)];
}
pub const IDTRegister = extern struct {
    limit: u16 align(1),
    idt: [*]volatile IDTDescriptor align(1),
};
pub const IDTTypeBits = enum(u4) {
    InvalidA = 0,
    InvalidB = 1,
    InvalidC = 2,
    InvalidD = 3,
    InvalidE = 4,
    TaskGate32Bit = 5, //invalid in long mode
    TaskGate16Bit = 6, //invalid in long mode
    TrapGate16Bit = 7, //invalid in long mode
    InvalidF = 8,
    InvalidG = 9,
    InvalidH = 0xA,
    InvalidI = 0xB,

    CallGate64Bit = 0xC, //also 32-bit
    InvalidJ = 0xD,
    InterruptGate64Bit = 0xE, //also 32-bit
    TrapGate64Bit = 0xF, //also 32 bit
};

pub const IDTDescriptor = packed struct {
    //The offset is a 64 bit value, split in three parts. It represents the address of the entry point of the ISR.
    offset_bits_0_to_15: u16, //bits 0-15
    selector: u16, //bits 16-31 //a code segment selector in GDT or LDT
    ist: u8, //bits 32-39       // bits 0-2 of this field hold Interrupt Stack Table offset, rest of bits zero.
    type_attr: IDTTypeBits, //bits 40-43 // type and attributes
    zeroA: u1, //should be zero bit 44
    privilege_bits: u2, //maximum ring level //bits 45-46
    is_present: bool, //bit 47
    offset_bits_16_to_31: u16, //bits 48-63 // offset bits 16..31
    offset_bits_32_to_63: u32, //bits 64-95 // offset bits 32..63
    zeroB: u32, //bits 96-127 // reserved
};

pub const ExceptionCode = enum(usize) {
    DivisionError = 0,
    Debug = 1,
    NMI = 2,
    Breakpoint = 3,
    Overflow = 4,
    BoundRangeExceeded = 5,
    InvalidOpcode = 6,
    DeviceNotAvailable = 7,
    DoubleFault = 8,

    InvalidTSS = 10,

    GeneralProtectionFault = 13,
    PageFault = 14,
};

pub inline fn get_idt_register() IDTRegister {
    var ret: IDTRegister = undefined;
    asm volatile ("sidt %[ret]"
        : [ret] "=m" (ret),
    );
    return ret;
}

pub fn get_idt() []volatile IDTDescriptor {
    const idtr = get_idt_register();
    return idtr.idt[0 .. (idtr.limit + 1) / @sizeOf(IDTDescriptor)];
}

pub fn register_exception_handler(
    comptime handler: anytype,
    comptime exception: ExceptionCode,
    idt: []volatile IDTDescriptor,
) void {
    const handler_addr = @intFromPtr(handler);
    idt[@intFromEnum(exception)] = .{
        .offset_bits_0_to_15 = @as(u16, @truncate(handler_addr)),
        .selector = asm volatile ("mov %%cs, %[ret]"
            : [ret] "=r" (-> u16),
            :
            : "cs"
        ),
        .ist = 0,
        .type_attr = .TrapGate64Bit,
        .zeroA = 0,
        .privilege_bits = 0,
        .is_present = true,
        .offset_bits_16_to_31 = @as(u16, @truncate(handler_addr >> 16)),
        .offset_bits_32_to_63 = @as(u32, @truncate(handler_addr >> 32)),
        .zeroB = 0,
    };
}

//interprocessor interrupts (IPI)
pub const InterruptControlRegisterLow = packed struct(u32) {
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
        PhysicalAPICID = 0,
        LogicalAPICID = 1,
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
pub const InterruptControlRegisterHigh = packed struct(u32) {
    reserved: u24 = 0,
    destination: u8,
};
pub fn send_interprocessor_interrupt(
    apic_base_address: u64,
    interrupt_command_register_low: InterruptControlRegisterLow,
    interrupt_command_register_high: InterruptControlRegisterHigh,
) void {
    const icr = @as([*]u32, @ptrFromInt(
        apic_base_address + 0x300,
    ))[0..5];
    icr[4] = @bitCast(interrupt_command_register_high);
    @fence(.SeqCst);
    icr[0] = @bitCast(interrupt_command_register_low);

    // const apic_base_address = rdmsr(IA32_APIC_BASE_MSR) &
    //     toolbox.mask_for_bit_range(12, 63, u64);
    // const interrupt_command_register_low_ptr = @as(
    //     *volatile InterruptControlRegisterLow,
    //     @ptrFromInt(
    //         apic_base_address + 0x300,
    //     ),
    // );
    // const interrupt_command_register_high_ptr = @as(
    //     *volatile InterruptControlRegisterHigh,
    //     @ptrFromInt(
    //         apic_base_address + 0x300 + @sizeOf(InterruptControlRegisterLow),
    //     ),
    // );

    // interrupt_command_register_high_ptr.* = interrupt_command_register_high;
    // @fence(.SeqCst);
    // interrupt_command_register_low_ptr.* = interrupt_command_register_low;
}
