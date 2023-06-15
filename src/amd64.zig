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
    writethrough: bool, //PWT bit --  Writes always hit both memory and cache. Reads can hit just cache. Good for SMP
    cache_disable: bool, //PCD bit -- Disable cache completely. Good for MMIO
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
    writethrough: bool, //PWT bit
    cache_disable: bool, //PCD bit
    accessed: bool = false, //A bit
    dirty: bool = false, //D bit -- was this page written to? must be manually reset
    must_be_one: u1 = 1,
    global: bool, //G bit -- always resident in TLB
    free_bits1: u3 = 0, //AVL bits
    page_attribute_table_bit: u1, //PAT bit
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
    writethrough: bool, //PWT bit
    cache_disable: bool, //PCD bit
    accessed: bool = false, //A bit
    dirty: bool = false, //D bit -- was this page written to? must be manually reset
    page_attribute_table_bit: u1, //PAT bit
    global: bool, //G bit -- always resident in TLB
    free_bits1: u3 = 0, //AVL bits
    physical_page_base_address: u40,
    free_bits2: u7 = 0, //AVL bits
    memory_protection_key: u4, //MPK bits
    no_execute: bool, //NX bit
};
