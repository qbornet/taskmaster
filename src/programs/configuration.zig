const std = @import("std");
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const programs_map = @import("../parser/parser.zig").programs_map;

fn setupWorkingDir(allocator: Allocator, working_dir: []const u8, program_name: []const u8) !void {
    const path = try std.fs.realpathAlloc(allocator, working_dir);
    std.debug.print("for '{s}' realpath={s}\n", .{program_name, path});
}

pub fn reloadConfiguration(allocator: Allocator, start_boot: bool) void {
    if (start_boot) {
        var iter = programs_map.iterator();
        while (iter.next()) |entry| {
            try setupWorkingDir(allocator, entry.value_ptr.content.workingdir, entry.key_ptr.*);
        }
    } else {
        std.debug.print("realoding config\n", .{});
    }
}
