const toolbox = @import("toolbox.zig");
const builtin = @import("builtin");
const std = @import("std");

comptime {
    switch (toolbox.THIS_PLATFORM) {
        .MacOS, .Playdate => {},
        else => {
            if (builtin.target.cpu.arch != .x86_64) {
                @compileError("We only support AMD64 if platform isn't macOS or Playdate");
            }
        },
    }
}

pub const Duration = struct {
    ticks: Ticks = 0,

    pub const Ticks = switch (toolbox.THIS_PLATFORM) {
        .MacOS => i64,
        .Playdate => f32,
        else => i64,
    };

    const PlatformDuration = switch (toolbox.THIS_PLATFORM) {
        .MacOS => MacOSDuration,
        .Playdate => PlaydateDuration,
        else => AMD64Duration,
    };

    pub inline fn add(lhs: Duration, rhs: Duration) Duration {
        return .{ .ticks = lhs.ticks + rhs.ticks };
    }
    pub inline fn subtract(lhs: Duration, rhs: Duration) Duration {
        return .{ .ticks = lhs.ticks - rhs.ticks };
    }

    pub const nanoseconds = @field(PlatformDuration, "nanoseconds");
    pub const microseconds = @field(PlatformDuration, "microseconds");
    pub const milliseconds = @field(PlatformDuration, "milliseconds");
    pub const seconds = @field(PlatformDuration, "seconds");
};

pub var amd64_ticks_to_microseconds: i64 = 0;

pub const Nanoseconds = Milliseconds;
pub const Microseconds = Milliseconds;
pub const Milliseconds = switch (toolbox.THIS_PLATFORM) {
    .Playdate => i32,
    else => i64,
};
pub const Seconds = switch (toolbox.THIS_PLATFORM) {
    .Playdate => f32,
    else => f64,
};
pub fn now() Duration {
    switch (comptime toolbox.THIS_PLATFORM) {
        .MacOS => {
            const ctime = @cImport(@cInclude("time.h"));
            const nanos = ctime.clock_gettime_nsec_np(ctime.CLOCK_MONOTONIC);
            toolbox.assert(nanos != 0, "nanotime call failed!", .{});
            return .{ .ticks = @intCast(nanos) };
        },
        .Playdate => {
            return .{ .ticks = toolbox.playdate_get_seconds() };
        },
        else => {
            var top: u64 = 0;
            var bottom: u64 = 0;
            asm volatile (
                \\rdtsc
                : [top] "={edx}" (top),
                  [bottom] "={eax}" (bottom),
            );
            const tsc = (top << 32) | bottom;
            return .{ .ticks = @intCast(tsc) };
        },
    }
}

const AMD64Duration = struct {
    pub inline fn nanoseconds(self: Duration) Nanoseconds {
        return self.microseconds() * 1000;
    }
    pub inline fn microseconds(self: Duration) Microseconds {
        toolbox.assert(amd64_ticks_to_microseconds > 0, "TSC calibration was not performed", .{});
        return @divTrunc(
            self.ticks,
            amd64_ticks_to_microseconds,
        );
    }
    pub inline fn milliseconds(self: Duration) Milliseconds {
        return @divTrunc(self.microseconds(), 1000);
    }
    pub inline fn seconds(self: Duration) Seconds {
        const floating_point_mcs: Seconds = @floatFromInt(self.microseconds());
        return floating_point_mcs / 1_000_000.0;
    }
};

const MacOSDuration = struct {
    pub inline fn nanoseconds(self: Duration) Nanoseconds {
        return self.ticks;
    }
    pub inline fn microseconds(self: Duration) Microseconds {
        return @divTrunc(self.ticks, 1000);
    }
    pub inline fn milliseconds(self: Duration) Milliseconds {
        return @divTrunc(self.ticks, 1_000_000);
    }
    pub inline fn seconds(self: Duration) Seconds {
        const floating_point_ns: Seconds = @floatFromInt(self.ticks);
        return floating_point_ns / 1_000_000_000.0;
    }
};
const PlaydateDuration = struct {
    pub inline fn nanoseconds(self: Duration) Nanoseconds {
        return @intFromFloat(self.ticks * 1_000_000_000.0);
    }
    pub inline fn microseconds(self: Duration) Microseconds {
        return @intFromFloat(self.ticks * 1_000_000.0);
    }
    pub inline fn milliseconds(self: Duration) Milliseconds {
        return @intFromFloat(self.ticks * 1000.0);
    }
    pub inline fn seconds(self: Duration) Seconds {
        return self.ticks;
    }
};
