const toolbox = @import("toolbox.zig");
const root = @import("root");

const ENABLE_PROFILER = if (@hasDecl(root, "ENABLE_PROFILER"))
    @field(root, "ENABLE_PROFILER")
else
    false;

const Profiler = struct {
    categories: toolbox.PointerStableHashMap([]const u8, Section),

    start: toolbox.Microseconds,
    end: toolbox.Microseconds,

    current_section: ?*Section,
    block_stack: toolbox.Stack(TimedBlock),
};

const Section = struct {
    time_elapsed_with_children: toolbox.Microseconds = 0,
    time_elapsed_without_children: toolbox.Microseconds = 0,
    hit_count: u64 = 0,
};

const TimedBlock = struct {
    label: []const u8,
    start: toolbox.Microseconds,

    previous_time_elapsed_with_children: toolbox.Microseconds,
    section: *Section,
    parent_section: ?*Section,
};

pub const PrintLineIterator = struct {
    it: toolbox.PointerStableHashMap([]const u8, Section).Iterator,
    total_elapsed: toolbox.Microseconds,
    arena: *toolbox.Arena,
    did_print_title: bool = false,

    pub fn next(self: *PrintLineIterator) ?toolbox.String8 {
        if (comptime !ENABLE_PROFILER) {
            return null;
        }
        const arena = self.arena;
        if (!self.did_print_title) {
            self.did_print_title = true;
            const total_elapsed_ms = @divTrunc(self.total_elapsed, 1000);
            return toolbox.str8fmt("Total time: {}ms", .{total_elapsed_ms}, arena);
        }
        if (self.it.next()) |kv| {
            const label = kv.k;
            const section = kv.v;
            const percent = 100 *
                @as(f32, @floatFromInt(section.time_elapsed_without_children)) /
                @as(f32, @floatFromInt(self.total_elapsed));
            const has_children =
                section.time_elapsed_without_children != section.time_elapsed_with_children;
            if (has_children) {
                const percent_with_children = 100 *
                    @as(f32, @floatFromInt(section.time_elapsed_with_children)) /
                    @as(f32, @floatFromInt(self.total_elapsed));
                return toolbox.str8fmt(
                    "{s}: {} hits, Total: {}mcs, {d:.2}%, {d:.2}% w/children",
                    .{
                        label,
                        section.hit_count,
                        section.time_elapsed_without_children,
                        percent,
                        percent_with_children,
                    },
                    arena,
                );
            } else {
                return toolbox.str8fmt("{s}: {} hits, Total: {}mcs, {d:.2}%", .{
                    label,
                    section.hit_count,
                    section.time_elapsed_without_children,
                    percent,
                }, arena);
            }
        }

        return null;
    }
};

var g_state: Profiler = undefined;

pub fn init(parent_arena: *toolbox.Arena) void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    const arena = parent_arena.create_arena_from_arena(toolbox.kb(512));
    g_state = .{
        .categories = toolbox.PointerStableHashMap([]const u8, Section).init(4096, arena),

        .start = undefined,
        .end = undefined,

        .current_section = null,
        .block_stack = toolbox.Stack(TimedBlock).init(arena, 512),
    };
}

pub fn start_profiler() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    g_state.current_section = null;
    g_state.block_stack.clear();
    g_state.categories.clear();
    g_state.start = toolbox.microseconds();
}

pub fn begin(comptime label: []const u8) void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    const section = g_state.categories.get_or_put_ptr(
        label,
        .{},
    );
    const block = g_state.block_stack.push(.{
        .label = label,
        .start = undefined,

        .section = section,
        .parent_section = g_state.current_section,
        .previous_time_elapsed_with_children = section.time_elapsed_with_children,
    });
    g_state.current_section = section;
    block.start = toolbox.microseconds();
}

pub fn end() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    const end_time = toolbox.microseconds();
    const block = g_state.block_stack.pop();
    const elapsed = end_time - block.start;

    const section = block.section;
    section.hit_count += 1;
    section.time_elapsed_without_children += elapsed;
    if (block.parent_section) |parent| {
        parent.time_elapsed_without_children -= elapsed;
    }
    section.time_elapsed_with_children = elapsed + block.previous_time_elapsed_with_children;

    g_state.current_section = block.parent_section;
}

pub fn end_profiler() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    g_state.end = toolbox.microseconds();
}

pub fn line_iterator(arena: *toolbox.Arena) PrintLineIterator {
    if (comptime !ENABLE_PROFILER) {
        return PrintLineIterator{
            .total_elapsed = undefined,
            .it = undefined,
            .arena = undefined,
        };
    }
    const total_elapsed = g_state.end - g_state.start;
    return PrintLineIterator{
        .total_elapsed = total_elapsed,
        .it = g_state.categories.iterator(),
        .arena = arena,
    };
}
