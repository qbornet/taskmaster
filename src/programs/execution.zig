const std = @import("std");
const parser = @import("../parser/parser.zig");
const posix = std.posix;
const c = std.c;

const Program = parser.Program;
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

/// Needed because `startExecution()` error cannot be infered
const StartExecutionError = error{} || std.fmt.ParseIntError ||  std.Thread.SpawnError || std.fs.File.OpenError || Allocator.Error || Child.SpawnError || Child.WaitError;


//var exited_pid: std.AutoArrayHashMap(Child.Id, bool) = undefined;
//var process_list: std.ArrayList(Child.Id) = .empty;
//var child_map: std.StringArrayHashMap(*Child) = undefined;
var finished_execution: bool = undefined;


fn setupWorkingDir(child: *Child, program: *Program) !void {
    const dir = try std.fs.openDirAbsolute(program.workingdir, .{ .iterate = true });
    child.cwd = program.workingdir;
    child.cwd_dir = dir;
}

fn checkExitCode(to_check: u8, program: *Program) !bool {
    var iter = std.mem.splitScalar(u8, program.exitcodes, ',');

    while (iter.next()) |code| {
        const exit_code = try std.fmt.parseInt(u8, code, 10);
        std.debug.print("checking: {d} exit_code: {d}\n", .{to_check, exit_code});
        if (to_check == exit_code) return true;
    }
    return false;
}

fn handleEndOfProcess(allocator: Allocator, term: Child.Term, program: *Program) !void {
    return switch (term) {
        .Exited  => |exit| {
            std.debug.print("Exit result: {d}\n", .{exit});
            if (try checkExitCode(exit, program) 
                and std.mem.eql(u8, program.autorestart, "unexpected")) {
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
    while (!finished_execution) {}

    while (true) {
        for (0..process_list.items.len, process_list.items) |i, pid| {
            const opt_val = exited_pid.get(pid);
            if (opt_val != null and opt_val.?) {
                _ = process_list.orderedRemove(i);
                _ = exited_pid.orderedRemove(pid);
                continue;
            }
            posix.kill(pid, 0) catch |err| switch (err) {
                error.PermissionDenied => std.debug.print("unsufficient permision to check process\n", .{}),
                error.ProcessNotFound => {
                    _ = process_list.orderedRemove(i);
                    _ = exited_pid.orderedRemove(pid);
                    try startExecutionOne(allocator, program);
                },
                else => std.debug.print("Thread check process received unknown: {s}\n", .{@errorName(err)}),
            };
        }
    }
}

/// Used only by thread to execute missing procc
fn startExecutionOne(allocator: Allocator, program: *Program) !void {
    const valid = try std.fmt.parseInt(u16, program.umask, 8);
    const old_mask = c.umask(valid);
    defer _ = c.umask(old_mask);

    const command = try std.fmt.allocPrint(
        allocator,
        "{s} >> {s} 2>> {s}",
        .{"envs", program.stdout, program.stderr}
    );

    var child: *Child = try allocator.create(Child);
    errdefer allocator.destroy(child);
    child.* = Child.init(&[_][]const u8{
        "/usr/bin/env",
        "bash",
        "-c",
        command
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    try setupWorkingDir(child, program);

    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                "error in service '{s}': invalid command use proper path.\n",
                .{program.name}
            );
        } else {
            std.debug.print(
                "error in service '{s}': {s}\n",
                .{program.name, @errorName(err)}
            );
        }
        return;
    };
    if (child.id != 0) {
        try process_list.append(allocator, child.id);
        try exited_pid.put(child.id, true);
    }
}

pub fn freeThreadExecution(allocator: Allocator, thread_pool: []*std.Thread) void {
    for (0..thread_pool.len) |index| {
        allocator.destroy(thread_pool[index]);
    }
    allocator.free(thread_pool);

}

// this will handle all the file until the execution of the program.
pub fn startExecution(allocator: Allocator, program: *Program) StartExecutionError!*std.Thread {
    const valid = try std.fmt.parseInt(u16, program.umask, 8);
    const old_mask = c.umask(valid);
    defer _ = c.umask(old_mask);

    // To handle the stdout, stderr as file we need a fix in the stdlib,
    // https://github.com/ziglang/zig/issues/22504
    // https://github.com/ziglang/zig/issues/23955
    const command = try std.fmt.allocPrint(
        allocator, 
        "{s} >> {s} 2>> {s}", 
        .{"envs", program.stdout, program.stderr}
    );
    defer allocator.free(command);

    std.debug.print("umask: {s}\n", .{program.umask});
    var child = Child.init(&[_][]const u8{
        "/usr/bin/env",
        "bash",
        "-c",
        command
    }, allocator);

    finished_execution = false;
    child.stdin_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    try setupWorkingDir(&child, program);

    var i: u16 = 0;
    const thread: *std.Thread = try allocator.create(std.Thread);
    errdefer allocator.destroy(thread);
    thread.* = try std.Thread.spawn(.{ .allocator = allocator }, checkUpProcess, .{allocator, program});

    while (i < program.numprocs) : (i += 1) {
        child.spawn() catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print(
                    "error in service '{s}': invalid command use proper path.\n",
                    .{program.name}
                );
            } else {
                std.debug.print(
                    "error in service '{s}': {s}\n",
                    .{program.name, @errorName(err)}
                );
            }
            continue;
        };
        if (child.id != 0) try process_list.append(allocator, child.id);
    }
    finished_execution = true;
    return thread;
}
