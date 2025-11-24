const std = @import("std");
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const parser = @import("../parser/parser.zig");
const exec = @import("execution.zig");


pub fn loadConfiguration(allocator: Allocator, start_boot: bool) ![]*std.Thread {
    if (start_boot) {
        var iter = parser.autostart_map.iterator();
        var index: usize = 0;
        var thread_pool = try allocator.alloc(*std.Thread, iter.hm.capacity());
        errdefer {
            var i: usize = 0;
            while (i < thread_pool.len) : (i += 1) {
                allocator.destroy(thread_pool[i]);
            }
            allocator.free(thread_pool);
        }

        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            std.debug.print("program.name: {s}\n", .{value.name});
            const thread = try exec.startExecution(allocator, value);
            thread_pool[index] = thread;
            index += 1;
        }
        return thread_pool;
    } else {
        std.debug.print("reloading config\n", .{});
        // should modif the behavior to have a comparaison done and change the programs, 
        // according to the modification done so if for example autostart is set to false,
        // we need to remove the configuration that as the new autostart set to false by,
        // removing it from the autostart_map variable and setting it to the programs_map.
        //
        // Not sure if it need to be restarted or not in that case because the running process doesn't change (maybe ?)
        return &.{};
    }
}
