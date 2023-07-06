const toolbox = @import("toolbox");

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

pub fn root_xsdt_entries(xsdt: *const XSDT) []align(4) *const XSDT {
    const len = (xsdt.length - @sizeOf(XSDT)) / 8;
    const ret = @as(
        [*]align(4) *const XSDT,
        @ptrFromInt(@intFromPtr(xsdt) + @sizeOf(XSDT)),
    )[0..len];
    return ret;
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
