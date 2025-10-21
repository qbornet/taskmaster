const std = @import("std");
const optimize = @import("builtin").mode;

pub fn main() !void {
    switch (optimize) {
        .Debug => std.debug.print("You are in debug mode: '{s}'\n", .{@tagName(optimize)}),
        else => std.debug.print("You are in {s} mode.\n", .{@tagName(optimize)}),
    }
}
