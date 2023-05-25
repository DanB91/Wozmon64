const uefi = @import("std").os.uefi;
const Guid = uefi.Guid;
const Status = uefi.Status;
const Event = uefi.Event;

pub const MPServiceProtocol = extern struct {
    _mp_services_get_number_of_processors: *const fn (*const MPServiceProtocol, *usize, *usize) callconv(.C) Status,
    _mp_services_get_processor_info: *const fn (*const MPServiceProtocol, usize, *ProcessorInformation) callconv(.C) Status,
    _mp_services_startup_all_aps: *const fn (*const MPServiceProtocol, *const fn (?*anyopaque) callconv(.C) void, bool, ?Event, usize, ?*anyopaque, ?*[*]usize) callconv(.C) Status,
    _mp_services_startup_this_ap: *const fn (*const MPServiceProtocol, *const fn (?*anyopaque) callconv(.C) void, usize, ?Event, usize, ?*anyopaque, ?*bool) callconv(.C) Status,
    _mp_services_switch_bsp: *const fn (*const MPServiceProtocol, usize, bool) callconv(.C) Status,
    _mp_services_enabledisableap: *const fn (*const MPServiceProtocol, usize, bool, ?*u32) callconv(.C) Status,
    _mp_services_whoami: *const fn (self: *const MPServiceProtocol, processor_number: *usize) callconv(.C) Status,

    pub fn mp_services_get_number_of_processors(self: *const MPServiceProtocol, number_of_processors: *usize, number_of_enabled_processors: *usize) Status {
        return self._mp_services_get_number_of_processors(self, number_of_processors, number_of_enabled_processors);
    }

    pub fn mp_services_get_processor_info(self: *const MPServiceProtocol, processor_number: usize, processor_info_buffer: *ProcessorInformation) Status {
        return self._mp_services_get_processor_info(self, processor_number, processor_info_buffer);
    }

    pub fn mp_services_startup_all_aps(
        self: *const MPServiceProtocol,
        procedure: *const fn (?*anyopaque) callconv(.C) void,
        single_thread: bool,
        wait_event: ?Event,
        timeout_in_microseconds: usize,
        procedure_argument: ?*anyopaque,
        failed_cpu_list: ?*[*]usize,
    ) Status {
        return self._mp_services_startup_all_aps(self, procedure, single_thread, wait_event, timeout_in_microseconds, procedure_argument, failed_cpu_list);
    }

    pub fn mp_services_startup_this_ap(
        self: *const MPServiceProtocol,
        procedure: *const fn (?*anyopaque) callconv(.C) void,
        processor_number: usize,
        wait_event: ?Event,
        timeout_in_microseconds: usize,
        procedure_argument: ?*anyopaque,
        finished: ?*bool,
    ) Status {
        return self._mp_services_startup_this_ap(self, procedure, processor_number, wait_event, timeout_in_microseconds, procedure_argument, finished);
    }

    pub fn mp_services_switch_bsp(self: *const MPServiceProtocol, processor_number: usize, enable_old_bsp: bool) Status {
        return self._mp_services_switch_bsp(self, processor_number, enable_old_bsp);
    }

    pub fn mp_services_enabledisableap(self: *const MPServiceProtocol, processor_number: usize, enable_ap: bool, health_flag: ?u32) Status {
        return self._mp_services_enabledisableap(self, processor_number, enable_ap, health_flag);
    }

    pub fn mp_services_whoami(self: *const MPServiceProtocol, processor_number: *usize) Status {
        return self._mp_services_whoami(self, processor_number);
    }

    pub const end_of_cpu_list: u32 = 0xffffffff;
    pub const processor_as_bsp_bit: u32 = 0x00000001;
    pub const processor_enabled_bit: u32 = 0x00000002;
    pub const processor_health_status_bit: u32 = 0x00000004;

    pub const guid align(8) = Guid{
        .time_low = 0x3fdda605,
        .time_mid = 0xa76e,
        .time_high_and_version = 0x4f46,
        .clock_seq_high_and_reserved = 0xad,
        .clock_seq_low = 0x29,
        .node = [_]u8{ 0x12, 0xf4, 0x53, 0x1b, 0x3d, 0x08 },
    };
};

pub const CPUPhysicalLocation = extern struct {
    package: u32,
    core: u32,
    thread: u32,
};

pub const CPUPhysicalLocation2 = extern struct {
    package: u32,
    module: u32,
    tile: u32,
    die: u32,
    core: u32,
    thread: u32,
};

pub const ExtendedProcessorInformation = extern union {
    location2: CPUPhysicalLocation2,
};

pub const ProcessorInformation = extern struct {
    processor_id: u64,
    status_flag: u32,
    location: CPUPhysicalLocation,
    extended_information: ExtendedProcessorInformation,
};
