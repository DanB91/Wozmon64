const toolbox = @import("toolbox.zig");
const std = @import("std");
const root = @import("root");

const ENABLE_PROFILER = if (@hasDecl(root, "ENABLE_PROFILER"))
    @field(root, "ENABLE_PROFILER")
else
    @compileError("Root module must have ENABLE_PROFILER flag!");

pub const State = struct {
    section_store: [MAX_SECTIONS]Section = [_]Section{.{}} ** MAX_SECTIONS,
    sections_used: usize = 0,

    start: toolbox.Duration = .{},
    end: toolbox.Duration = .{},

    current_section_index: usize = 0,
    block_stack: toolbox.FixedStack(TimedBlock, MAX_SECTIONS) = .{},

    const MAX_SECTIONS = 4096;
};

pub const Section = struct {
    time_elapsed_with_children: toolbox.Duration = .{},
    time_elapsed_without_children: toolbox.Duration = .{},
    hit_count: u64 = 0,
    label_store: [MAX_LABEL_LEN]u8 = [_]u8{0} ** MAX_LABEL_LEN,
    label_len: usize = 0,

    index_address: usize = 0,

    const MAX_LABEL_LEN = 64;
};

pub const TimedBlock = struct {
    start: toolbox.Duration = .{},

    previous_time_elapsed_with_children: toolbox.Duration = .{},
    section_index: usize = 0,
    parent_section_index: usize = 0,
};

var g_state: State = .{};

pub fn start_profiler() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    g_state = .{};
    g_state.start = toolbox.now();
}

pub fn begin(comptime label: []const u8) void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    const StaticVars = struct {
        //index 0 is always unused, since it is the "root parent"
        var section_index: usize = 0;
    };

    //this will give us a different index per label since we have a different
    //static-var pool per comptime argument
    var section_index = StaticVars.section_index;
    var section = &g_state.section_store[section_index];
    if (section.index_address != @intFromPtr(&StaticVars.section_index)) {

        //assign new section index
        g_state.sections_used += 1;
        StaticVars.section_index = g_state.sections_used;
        section_index = StaticVars.section_index;

        g_state.section_store[section_index] = .{
            .label_len = label.len,
            .index_address = @intFromPtr(&StaticVars.section_index),
        };
        section = &g_state.section_store[section_index];
        @memcpy(section.label_store[0..label.len], label);
    }

    const block = g_state.block_stack.push(.{
        .section_index = section_index,
        .parent_section_index = g_state.current_section_index,
        .previous_time_elapsed_with_children = section.time_elapsed_with_children,
    });
    g_state.current_section_index = section_index;
    block.start = toolbox.now();
}

pub fn end() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    const end_time = toolbox.now();
    const block = g_state.block_stack.pop();
    const elapsed = end_time.subtract(block.start);

    const parent = &g_state.section_store[block.parent_section_index];
    parent.time_elapsed_without_children.ticks -= elapsed.ticks;

    const section = &g_state.section_store[block.section_index];
    section.hit_count += 1;
    section.time_elapsed_without_children.ticks += elapsed.ticks;
    section.time_elapsed_with_children = elapsed.add(block.previous_time_elapsed_with_children);

    g_state.current_section_index = block.parent_section_index;
}

pub fn end_profiler() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    g_state.end = toolbox.now();
}

pub fn line_iterator(snapshot: State, arena: *toolbox.Arena) PrintLineIterator {
    if (comptime !ENABLE_PROFILER) {
        return .{};
    }

    const total_elapsed = snapshot.end.subtract(snapshot.start);
    return PrintLineIterator{
        .snapshot = snapshot,
        .total_elapsed = total_elapsed,
        .arena = arena,
    };
}

pub fn save() State {
    return g_state;
}

pub fn restore(profiler: State) void {
    g_state = profiler;
}

pub const PrintLineIterator = struct {
    snapshot: State = .{},
    total_elapsed: toolbox.Duration = .{},
    arena: ?*toolbox.Arena = null,
    did_print_title: bool = false,
    //first section is unused
    cursor: usize = 1,

    pub fn next(self: *PrintLineIterator) ?toolbox.String8 {
        if (comptime !ENABLE_PROFILER) {
            return null;
        }
        if (self.cursor >= self.snapshot.sections_used + 1) {
            return null;
        }
        if (self.arena) |arena| {
            if (!self.did_print_title) {
                self.did_print_title = true;
                const total_elapsed_ms = self.total_elapsed.milliseconds();
                return toolbox.str8fmt("Total time: {}ms", .{total_elapsed_ms}, arena);
            }
            const section = self.snapshot.section_store[self.cursor];
            defer self.cursor += 1;

            const percent = 100 *
                @as(f32, @floatFromInt(section.time_elapsed_without_children.ticks)) /
                @as(f32, @floatFromInt(self.total_elapsed.ticks));
            const has_children =
                section.time_elapsed_without_children.ticks != section.time_elapsed_with_children.ticks;
            if (has_children) {
                const percent_with_children = 100 *
                    @as(f32, @floatFromInt(section.time_elapsed_with_children.ticks)) /
                    @as(f32, @floatFromInt(self.total_elapsed.ticks));
                return toolbox.str8fmt(
                    "{s}: {} hits, Total: {}mcs, {d:.2}%, {d:.2}% w/children",
                    .{
                        section.label_store[0..section.label_len],
                        section.hit_count,
                        section.time_elapsed_without_children.microseconds(),
                        percent,
                        percent_with_children,
                    },
                    arena,
                );
            } else {
                return toolbox.str8fmt("{s}: {} hits, Total: {}mcs, {d:.2}%", .{
                    section.label_store[0..section.label_len],
                    section.hit_count,
                    section.time_elapsed_without_children.microseconds(),
                    percent,
                }, arena);
            }
        }

        return null;
    }
};
