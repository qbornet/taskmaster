const std = @import("std");
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const parser = @import("../parser/parser.zig");

fn setupWorkingDir(allocator: Allocator, working_dir: []const u8, program_name: []const u8) !void {
    const path = try std.fs.realpathAlloc(allocator, working_dir);
    std.debug.print("for '{s}' realpath={s}\n", .{program_name, path});
}

pub fn loadConfiguration(allocator: Allocator, start_boot: bool) !void {
    if (start_boot) {
        _ = allocator;
        var testMap = parser.programs_map;
        var iter = testMap.iterator();
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            std.debug.print("name={s}\n", .{value.name});
        }
    } else {
        std.debug.print("reloading config\n", .{});
    }
}
