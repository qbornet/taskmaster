const std = @import("std");
const optimize = @import("builtin").mode;

pub fn main() !void {
    std.debug.print("Optimization mode: '{s}'\n", .{@tagName(optimize)});
}
