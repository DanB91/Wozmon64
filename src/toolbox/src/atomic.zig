const std = @import("std");
pub const TicketLock = struct {
    serving: u64 = 0,
    taken: u64 = 0,

    pub fn lock(self: *TicketLock) void {
        const ticket = @atomicRmw(u64, &self.taken, .Add, 1, .seq_cst);
        while (true) {
            if (@cmpxchgWeak(
                u64,
                &self.serving,
                ticket,
                ticket,
                .acq_rel,
                .acquire,
            ) == null) {
                return;
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn release(self: *TicketLock) void {
        _ = @atomicRmw(u64, &self.serving, .Add, 1, .seq_cst);
    }
};
