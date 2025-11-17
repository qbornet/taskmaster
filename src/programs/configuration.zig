const std = @import("std");
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const parser = @import("../parser/parser.zig");

fn setupWorkingDir(allocator: Allocator, working_dir: []const u8, program_name: []const u8) !void {
    const path = try std.fs.cwd().realpathAlloc(allocator, working_dir);
    defer allocator.free(path);
    std.debug.print("for '{s}' realpath={s}\n", .{program_name, path});
}

pub fn loadConfiguration(allocator: Allocator, start_boot: bool) !void {
    if (start_boot) {
        var iter = parser.autostart_map.iterator();
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            std.debug.print("program.name: {s}\n", .{value.name});
            try setupWorkingDir(allocator, value.workingdir, value.name);
        }
    } else {
        std.debug.print("reloading config\n", .{});
        // should modif the behavior to have a comparaison done and change the programs, 
        // according to the modification done so if for example autostart is set to false,
        // we need to remove the configuration that as the new autostart set to false by,
        // removing it from the autostart_map variable and setting it to the programs_map.
        //
        // Not sure if it need to be restarted or not in that case because the running process doesn't change (maybe ?)
    }
}
