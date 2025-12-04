const std = @import("std");
const parser = @import("../parser/parser.zig");
const posix = std.posix;
const c = std.c;

const ProcessRunner = @import("../lib/ProcessRunner.zig");
const ProcessProgram = @import("../lib/ProcessProgram.zig");
const Worker = @import("../lib/Worker.zig");
const Atomic = std.atomic.Value;
const Program = parser.Program;
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

/// Needed because `startExecution()` error cannot be infered
const StartExecutionError = error{} || std.fmt.ParseIntError || std.Thread.SpawnError || std.fs.File.OpenError || Allocator.Error || Child.SpawnError || Child.WaitError;

pub const ExecutionResult = struct {
    worker: *Worker,
    validity_thread: *std.Thread,
};

var process_program_map: std.StringArrayHashMap(*ProcessProgram) = undefined;

fn setupWorkingDir(child: *Child, program: *Program) !void {
    const dir = try std.fs.openDirAbsolute(program.workingdir, .{ .iterate = true });
    child.cwd = program.workingdir;
    child.cwd_dir = dir;
}

fn checkExitCode(to_check: u8, program: *Program) !bool {
    var iter = std.mem.splitScalar(u8, program.exitcodes, ',');

    while (iter.next()) |code| {
        const exit_code = try std.fmt.parseInt(u8, code, 10);
        std.debug.print("checking: {d} exit_code: {d}\n", .{ to_check, exit_code });
        if (to_check == exit_code) return true;
    }
    return false;
}

fn handleEndOfProcess(allocator: Allocator, term: Child.Term, program: *Program) !void {
    return switch (term) {
        .Exited => |exit| {
            std.debug.print("Exit result: {d}\n", .{exit});
            if (try checkExitCode(exit, program) and std.mem.eql(u8, program.autorestart, "unexpected")) {
                var retries: u16 = 0;
                while (retries < program.startretries) : (retries += 1) {
                    startExecution(allocator, program) catch {
                        std.debug.print("service '{s}' trying to restart...", .{program.name});
                    };
                }
            }
        },
        .Signal => |sig| std.debug.print("Signal received: {d}\n", .{sig}),
        .Stopped => |stop| std.debug.print("Stopped: {d}\n", .{stop}),
        .Unknown => |unknown| std.debug.print("Unknown: {d}\n", .{unknown}),
    };
}

fn checkUpProcess(allocator: Allocator, program: *Program) !void {
    var index: usize = 0;
    const opt_pp: ?*ProcessProgram = null;
    while (index < program.numprocs) : (index += 1) {
        if (opt_pp) |pp| {
            for (0..pp.getSizeProcessList(), pp.getProcessListItems()) |idx, pid| {
                posix.kill(pid, 0) catch |err| switch (err) {
                    error.PermissionDenied => std.debug.print("error: permission not allowed for process '{s}'\n", .{program.name}),
                    error.ProcessNotFound => {
                        pp.removePid(pid, idx);
                        try startExecutionOne(allocator, program);
                    },
                    else => std.debug.print("error: unknown '{s}'", .{@errorName(err)}),
                };
            }
        }
    }
}

/// Used only by thread to execute missing procc
fn startExecutionOne(allocator: Allocator, program: *Program) !void {
    _ = allocator;
    const valid = try std.fmt.parseInt(u16, program.umask, 8);
    const old_mask = c.umask(valid);
    defer _ = c.umask(old_mask);
    std.debug.print("in executionOne", .{});
}

pub fn freeProcessProgram() void {
    var iter = process_program_map.iterator();
    while (iter.next()) |pp_to_free| {
        pp_to_free.value_ptr.*.deinit();
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

/// Handle the execution of the program create the process and worker (thread) to,
/// check if number of process are correct.
pub fn startExecution(allocator: Allocator, program: *Program) StartExecutionError!*ExecutionResult {
    const execution_result: *ExecutionResult = try allocator.create(ExecutionResult);
    errdefer allocator.destroy(execution_result);

    var tmp_array: std.ArrayList([]const u8) = .empty;
    const runner: *ProcessRunner = try .init(allocator, program.stdout, program.stderr);
    errdefer runner.deinit();

    var iter = std.mem.splitScalar(u8, program.cmd, ' ');
    while (iter.next()) |line| {
        try tmp_array.append(allocator, line);
    }
    defer tmp_array.deinit(allocator);

    const runner_thread = try runner.start(program, tmp_array.items);
    std.debug.print("Creating thread...\n", .{});
    execution_result.validity_thread = runner_thread;
    execution_result.worker = try .init(allocator, program.name, checkUpProcess, .{ allocator, program });
    std.debug.print("Worker init: {*}\n", .{execution_result.worker});
    return execution_result;
}
