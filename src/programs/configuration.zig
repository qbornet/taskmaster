const std = @import("std");
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const parser = @import("../parser/parser.zig");

fn setupWorkingDir(allocator: Allocator, working_dir: []const u8, program_name: []const u8) !void {
    const path = try std.fs.cwd().realpathAlloc(allocator, working_dir);
    std.debug.print("for '{s}' realpath={s}\n", .{program_name, path});
}

pub fn loadConfiguration(allocator: Allocator, start_boot: bool) !void {
    var iter = parser.programs_map.iterator();
    if (start_boot) {
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            std.debug.print("name={s}\n", .{value.name});
        }
    } else {
        std.debug.print("reloading config\n", .{});
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            try setupWorkingDir(allocator, value.workingdir, value.name);
        }
    }
}
