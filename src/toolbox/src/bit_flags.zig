pub fn BitFlags(comptime T: type) type {
    if (comptime @typeInfo(T) != .Enum) {
        @compileError("BitFlags must take an enum type");
    }

    const Underlying = @typeInfo(T).Enum.Child;
    return packed struct(Underlying) {
        value: Underlying,

        const Self = @This();

        pub fn set(self: *Self, value: T) void {
            self.value |= @intFromEnum(value);
        }

        pub fn reset(self: *Self, value: T) void {
            self.value &= ~@intFromEnum(value);
        }

        pub fn in(self: *Self, value: T) bool {
            return (self.value & @intFromEnum(value)) == 0;
        }
    };
}
