const std = @import("std");
const parser = @import("../parser/parser.zig");
const posix = std.posix;
const c = std.c;

const ProcessRunner = @import("../lib/ProcessRunner.zig");
const ProcessProgram = @import("../lib/ProcessProgram.zig");
const Printer = @import("../lib/Printer.zig");
const Worker = @import("../lib/Worker.zig");
const Atomic = std.atomic.Value;
const Program = parser.Program;
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

/// Needed because `startExecution()` error cannot be infered

pub const ExecutionResult = struct {
    worker: *Worker,
    validity_thread: *std.Thread,
    program: *Program,
    process_runner: *ProcessRunner,
};

pub var mutex: std.Thread.Mutex = .{};
pub var process_program_map: std.StringArrayHashMap(*ProcessProgram) = .init(std.heap.page_allocator);

fn getMapSafe(prog_name: []const u8) ?*ProcessProgram {
    mutex.lock();
    defer mutex.unlock();
    return process_program_map.get(prog_name);
}

fn checkExitCodes(status: u32, program: *Program, pp: *ProcessProgram) !void {
    const restart_policies_never = std.mem.eql(u8, program.autorestart, "never");
    const restart_policies_always = std.mem.eql(u8, program.autorestart, "always");
    if (restart_policies_always) {
        return;
    } else if (pp.getRestarting() and restart_policies_never) {
        pp.stopRestarting();
        return;
    } else if (restart_policies_never) return;

    var iter = std.mem.splitScalar(u8, program.exitcodes, ',');
    while (iter.next()) |exit_code_ascii| {
        const exit_code = try std.fmt.parseInt(u8, exit_code_ascii, 10);
        if (exit_code == status) {
            pp.stopRestarting();
        }
    }
}

/// Use to check process if they are alive and start new one if they are not.
pub fn checkUpProcess(allocator: Allocator, program: *Program) !void {
    const opt_pp: ?*ProcessProgram = getMapSafe(program.name);
    if (opt_pp) |pp| {
        for (0.., pp.getProcessList().items) |idx, pid| {
            const ret = posix.waitpid(pid, 1);
            if (ret.pid > 0) _ = try checkExitCodes(ret.status, program, pp);
            posix.kill(pid, 0) catch |err| switch (err) {
                error.PermissionDenied => std.debug.print("error: permission not allowed for process '{s}'\n", .{program.name}),
                error.ProcessNotFound => {
                    pp.pidListRemove(idx, null);
                    if (pp.getRestarting()) {
                        _ = pp.pidMapRemove(pid);
                        var i: usize = 0;
                        var execution_result: *ExecutionResult = undefined;
                        while (i < program.startretries) : (i += 1) {
                            execution_result = try startExecution(allocator, program);
                            execution_result.validity_thread.join();
                            if (!execution_result.process_runner.getProcessValidity()) {
                                execution_result.process_runner.deinit();
                                allocator.destroy(execution_result.validity_thread);
                                allocator.destroy(execution_result);
                                continue;
                            } else break;
                        }
                        execution_result.process_runner.deinit();
                        allocator.destroy(execution_result.validity_thread);
                        allocator.destroy(execution_result);
                        if (i == program.startretries) pp.stopRestarting();
                    }
                    continue;
                },
                else => std.debug.print("error: unknown '{s}'", .{@errorName(err)}),
            };
        }
    }
}

/// Check if process is alive all the available process are alive.
fn checkAlive(program: *Program) !usize {
    var count: usize = 0;
    const opt_pp = getMapSafe(program.name);
    if (opt_pp) |process_program| {
        var to_remove: std.ArrayList(usize) = .empty;
        const allocator = process_program.allocator;
        errdefer to_remove.deinit(allocator);


        const process_list = process_program.getProcessList();
        const slices = process_list.items;
        for (0..process_program.getSizeProcessList(), slices) |i, pid| {
            process_program.mutex.lock();
            posix.kill(pid, 0) catch |err| switch (err) {
                error.PermissionDenied => std.debug.print("Unsufficent Permission not allowed to check process\n", .{}),
                error.ProcessNotFound => {
                    try to_remove.append(allocator, i);
                    process_program.mutex.unlock();
                    const opt_exited = process_program.pidCheck(pid);
                    process_program.mutex.lock();
                    if (opt_exited != null and opt_exited.?) {
                        process_program.mutex.unlock();
                        _ = process_program.pidMapRemove(pid);
                        process_program.mutex.lock();
                    }
                },
                else => {
                    const error_string = try std.fmt.allocPrint(std.heap.page_allocator, "error unknown: {s}\n", .{@errorName(err)});
                    @panic(error_string);
                }
            };
            process_program.mutex.unlock();
        }
        count += to_remove.items.len;
        process_program.pidListRemove(null, to_remove.items);
        to_remove.deinit(allocator);
    }
    return count;
}

/// Send the signal link to the `program.stopsignal`
fn sendSignal(program: *Program) !void {
    mutex.lock();
    const opt_pp = process_program_map.get(program.name);
    mutex.unlock();
    const sig = try parser.getSignal(program.stopsignal);
    if (opt_pp) |process_program| {
        const process_list = process_program.getProcessList();
        const slices = process_list.items;
        for (0..process_program.getSizeProcessList(), slices) |_, pid| {
            process_program.mutex.lock();
            posix.kill(pid, sig) catch |err| switch (err) {
                error.PermissionDenied => std.debug.print("Unsufficent Permission", .{}),
                error.ProcessNotFound => {
                    process_program.mutex.unlock();
                    continue;
                },
                else => @panic("unknown error when communicating to process")
            };
            process_program.mutex.unlock();
            try process_program.pidExit(pid);
            _ = posix.waitpid(pid, 0);
        }
    }
}

pub fn checkStatusSafe() !void {
    var printer: *Printer = undefined;
    var buffer: [65535]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    printer = try .init(allocator, .Stdout, null);
    defer printer.deinit();

    var count: usize = 0;
    mutex.lock();
    var it = process_program_map.iterator();
    while (it.next()) |entry| : (count += 1){
        var i: usize = 0;
        const program_name = entry.key_ptr.*;
        const process_program = entry.value_ptr.*;
        const process_list = process_program.getProcessList();
        process_program.mutex.lock();
        const len = process_list.items.len;
        while (i < len) : (i += 1) {
            const pid = process_list.items[i];
            std.posix.kill(pid, 0) catch |err| switch (err) {
                error.PermissionDenied => break,
                error.ProcessNotFound => break,
                else => @panic("unknown error when communicating to process")
            };
        }
        if (count+1 == it.len) try printer.print("└── ", .{}) else try printer.print("├── ", .{});
        if (process_list.items.len != 0 and i == process_list.items.len) {
            try printer.print("{s} ✓\n", .{program_name});
        } else {
            try printer.print("{s} 𐄂\n", .{program_name});
        }
        process_program.mutex.unlock();
    }
    mutex.unlock();
}

/// Exit properly the process running if the process didn't exit then,
/// force terminating with SIGKILL.
pub fn exitCleanly(program: *Program) !void {
    const time_sleep: usize = std.time.ns_per_s*@as(usize, @intCast(program.stoptime));
    _ = try checkAlive(program);
    try sendSignal(program);
    std.Thread.sleep(time_sleep);

    std.debug.print("start checkAlive again\n", .{});
    const dead_process = try checkAlive(program);
    if ((program.numprocs - dead_process) == 0) {
        return;
    }
    mutex.lock();
    defer mutex.unlock();
    const opt_pp = process_program_map.get(program.name);
    if (opt_pp) |process_program| {
        const allocator = std.heap.page_allocator;
        var pids_removes = std.ArrayListUnmanaged(usize){};
        defer pids_removes.deinit(allocator);

        for (0.., process_program.getProcessList().items) |i, pid| {
            process_program.mutex.lock();
            posix.kill(pid, 9) catch |err| switch (err) {
                error.PermissionDenied => std.debug.print("Unsufficent Permission", .{}),
                error.ProcessNotFound =>  @panic("error: Process Not Found"),
                else => @panic("unknown error when communicating to process")
            };
            try pids_removes.append(allocator, i);
            process_program.mutex.unlock();
            _ = process_program.pidMapRemove(pid);
            _ = posix.waitpid(pid, 0);
        }
        process_program.pidListRemove(null, pids_removes.items);
    }
}

/// Free the `process_program_map` and is content
pub fn freeProcessProgram() void {
    mutex.lock();
    defer mutex.unlock();
    var iter = process_program_map.iterator();
    while (iter.next()) |pp_to_free| {
        const process_program = pp_to_free.value_ptr.*;
        process_program.deinit();
    }
    process_program_map.deinit();
}

/// Free the `execution_pool` this will clear the worker and the validity thread.
pub fn freeExecutionPool(allocator: Allocator, execution_pool: []*ExecutionResult) void {
    for (0..execution_pool.len) |index| {
        const execution = execution_pool[index];
        execution.worker.deinit();
        allocator.destroy(execution.validity_thread);
        allocator.destroy(execution);
    }
    allocator.free(execution_pool);
}

const StartExecutionError = error{
    NoProcessProgramFound
} || std.fmt.ParseIntError || std.Thread.SpawnError || std.fs.File.OpenError 
  || Allocator.Error || Child.SpawnError || Child.WaitError;

/// Handle the execution of the program create the process and worker (thread) to,
/// check if number of process are correct.
pub fn startExecution(allocator: Allocator, program: *Program) StartExecutionError!*ExecutionResult {
    const execution_result = try allocator.create(ExecutionResult);
    var process_program: *ProcessProgram = undefined; 

    mutex.lock();
    const opt_pp = process_program_map.get(program.name);
    mutex.unlock();
    process_program = if (opt_pp) |pp| pp else try .init(allocator, program.name);

    mutex.lock();
    try process_program_map.put(program.name, process_program);
    mutex.unlock();
    var tmp_array: std.ArrayList([]const u8) = .empty;
    const runner: *ProcessRunner = try .init(allocator, program.stdout, program.stderr);

    var iter_split = std.mem.splitScalar(u8, program.cmd, ' ');
    while (iter_split.next()) |line| {
        try tmp_array.append(allocator, line);
    }
    defer tmp_array.deinit(allocator);

    const runner_thread = try runner.start(program, tmp_array.items, process_program);
    execution_result.program = program;
    execution_result.validity_thread = runner_thread;
    execution_result.process_runner = runner;
    return execution_result;
}
