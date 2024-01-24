const toolbox = @import("toolbox.zig");
const root = @import("root");

const ENABLE_PROFILER = if (@hasDecl(root, "ENABLE_PROFILER"))
    @field(root, "ENABLE_PROFILER")
else
    false;

pub const State = struct {
    categories: toolbox.PointerStableHashMap([]const u8, Section) = .{},

    start: toolbox.Duration = .{},
    end: toolbox.Duration = .{},

    current_section: ?*Section = null,
    block_stack: toolbox.Stack(TimedBlock) = .{},

    arena: ?*toolbox.Arena = null,
};

pub const Section = struct {
    time_elapsed_with_children: toolbox.Duration = .{},
    time_elapsed_without_children: toolbox.Duration = .{},
    hit_count: u64 = 0,
};

pub const TimedBlock = struct {
    label: []const u8 = @as([*]const u8, undefined)[0..0],
    start: toolbox.Duration = .{},

    previous_time_elapsed_with_children: toolbox.Duration = .{},
    section: *Section,
    parent_section: ?*Section = null,
};

pub const PrintLineIterator = struct {
    it: toolbox.PointerStableHashMap([]const u8, Section).Iterator = .{},
    total_elapsed: toolbox.Duration = .{},
    arena: ?*toolbox.Arena = null,
    did_print_title: bool = false,

    pub fn next(self: *PrintLineIterator) ?toolbox.String8 {
        if (comptime !ENABLE_PROFILER) {
            return null;
        }
        if (self.arena) |arena| {
            if (!self.did_print_title) {
                self.did_print_title = true;
                const total_elapsed_ms = self.total_elapsed.milliseconds();
                return toolbox.str8fmt("Total time: {}ms", .{total_elapsed_ms}, arena);
            }
            if (self.it.next()) |kv| {
                const label = kv.k;
                const section = kv.v;
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
                            label,
                            section.hit_count,
                            section.time_elapsed_without_children.microseconds(),
                            percent,
                            percent_with_children,
                        },
                        arena,
                    );
                } else {
                    return toolbox.str8fmt("{s}: {} hits, Total: {}mcs, {d:.2}%", .{
                        label,
                        section.hit_count,
                        section.time_elapsed_without_children.microseconds(),
                        percent,
                    }, arena);
                }
            }
            arena.restore();
        }

        return null;
    }
};

var g_state: State = .{};

pub fn init(parent_arena: *toolbox.Arena) void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    const arena = parent_arena.create_arena_from_arena(toolbox.kb(512));
    g_state = .{
        .categories = toolbox.PointerStableHashMap([]const u8, Section).init(4096, arena),
        .block_stack = toolbox.Stack(TimedBlock).init(arena, 512),
        .arena = arena,
    };
}

pub fn start_profiler() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    g_state.current_section = null;
    g_state.block_stack.clear();
    g_state.categories.clear();
    g_state.start = toolbox.now();
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

        .section = section,
        .parent_section = g_state.current_section,
        .previous_time_elapsed_with_children = section.time_elapsed_with_children,
    });
    g_state.current_section = section;
    block.start = toolbox.now();
}

pub fn end() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    const end_time = toolbox.now();
    const block = g_state.block_stack.pop();
    const elapsed = end_time.subtract(block.start);

    const section = block.section;
    section.hit_count += 1;
    section.time_elapsed_without_children.ticks += elapsed.ticks;
    if (block.parent_section) |parent| {
        parent.time_elapsed_without_children.ticks -= elapsed.ticks;
    }
    section.time_elapsed_with_children = elapsed.add(block.previous_time_elapsed_with_children);

    g_state.current_section = block.parent_section;
}

pub fn end_profiler() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }
    g_state.end = toolbox.now();
}

pub fn line_iterator() PrintLineIterator {
    if (comptime !ENABLE_PROFILER) {
        return .{};
    }

    if (g_state.arena) |arena| arena.save();

    const total_elapsed = g_state.end.subtract(g_state.start);
    return PrintLineIterator{
        .total_elapsed = total_elapsed,
        .it = g_state.categories.iterator(),
        .arena = g_state.arena,
    };
}

pub fn save(arena: *toolbox.Arena) State {
    return .{
        .start = g_state.start,
        .end = g_state.end,
        .categories = g_state.categories.clone(arena),
        .block_stack = g_state.block_stack.clone(arena),
        .current_section = g_state.current_section,
        .arena = arena,
    };
}

pub fn restore(profiler: State) void {
    g_state = profiler;
}
