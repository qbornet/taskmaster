const std = @import("std");
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const Worker = @import("../lib/Worker.zig");
const parser = @import("../parser/parser.zig");
const exec = @import("execution.zig");

pub fn loadConfiguration(allocator: Allocator, start_boot: bool) !?std.ArrayList(exec.ExecutionResult) {
    if (start_boot) {
        var iter = parser.autostart_map.iterator();
        var execution_pool: std.ArrayList(exec.ExecutionResult) = .empty;
        errdefer execution_pool.deinit(allocator);

        std.debug.print("execution_pool.len: {d}\n", .{iter.hm.size});
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            std.debug.print("program.name: {s}\n", .{value.name});
            var execution_result: *exec.ExecutionResult = undefined;
            errdefer allocator.destroy(execution_result);
            var validity_pool: []*std.Thread = try allocator.alloc(*std.Thread, value.numprocs);
            defer {
                var i: usize = 0;
                while (i < validity_pool.len) : (i += 1) {
                    validity_pool[i].join();
                    allocator.destroy(validity_pool[i]);
                }
                allocator.free(validity_pool);
            }

            for (0..value.numprocs) |i| {
                execution_result = exec.startExecution(allocator, value) catch |err| {
                    switch (err) {
                        error.NoProcessProgramFound => std.debug.print("process_program not found\n", .{}),
                        else => std.debug.print("error for execution: {s}\n", .{@errorName(err)}),
                    }
                    std.debug.print("error found execution done\n", .{});
                    return err;
                };
                validity_pool[i] = execution_result.validity_thread;

                // This is only usefull for restartretries so we dont keep the object.
                execution_result.process_runner.deinit();
                allocator.destroy(execution_result);
            }
            try execution_pool.append(allocator, .{
                .worker = try .init(allocator, value.name, exec.checkUpProcess, .{ allocator, value }),
                .validity_thread = undefined,
                .process_runner = undefined,
                .program = value
            });
        }
        return execution_pool;
    } else {
        std.debug.print("reloading config\n", .{});
        const end_index = std.mem.indexOfSentinel(u8, 0, std.os.argv[1]);
        const arg = std.os.argv[1][0..end_index];
        const realpath = try std.fs.cwd().realpathAlloc(allocator, arg);
        defer allocator.free(realpath);
        const new_config = try parser.readYamlFile(allocator, realpath);
        if (std.mem.eql(u8, new_config, parser.current_config)) {
            allocator.free(new_config);
            return null;
        }
        try parser.reloadMap(allocator, new_config);
        return null;
    }
}
