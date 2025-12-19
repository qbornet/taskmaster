const std = @import("std");
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const Worker = @import("../lib/Worker.zig");
const parser = @import("../parser/parser.zig");
const exec = @import("execution.zig");

pub fn loadConfiguration(allocator: Allocator, start_boot: bool) ![]exec.ExecutionResult {
    if (start_boot) {
        var iter = parser.autostart_map.iterator();
        var index: usize = 0;
        var execution_pool = try allocator.alloc(exec.ExecutionResult, iter.hm.size);
        errdefer {
            var i: usize = 0;
            while (i < execution_pool.len) : (i += 1) {
                execution_pool[i].worker.deinit();
                allocator.destroy(execution_pool[i].worker);
            }
            allocator.free(execution_pool);
        }

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
            execution_pool[index] = .{ 
                .worker = try .init(allocator, value.name, exec.checkUpProcess, .{ allocator, value }),
                .validity_thread = undefined,
                .process_runner = undefined,
                .program = value
            };
            index += 1;
        }
        return execution_pool;
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
