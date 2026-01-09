const std = @import("std");
const exec = @import("execution.zig");
const conf = @import("configuration.zig");
const parser = @import("../parser/parser.zig");
const lev = @import("../reader/levenshtein.zig");
const global = @import("../lib/global_map.zig");
const mem = std.mem;
const fs = std.fs;

const Allocator = mem.Allocator;
const Worker = @import("../lib/Worker.zig");
const Printer = @import("../lib/Printer.zig");
const ExecutionResult = @import("../programs/execution.zig").ExecutionResult;

const ProgramError = error{ HighTokenCount, ProgramNotFound };

pub const ProgramAction = struct {
    allocator: ?Allocator,
    result: bool,
    execution_pool: ?std.ArrayList(ExecutionResult),
    execution_result: ?*ExecutionResult,
};

fn countSizeIterator(iter: *mem.TokenIterator(u8, .scalar)) usize {
    var size: usize = 0;
    while (iter.next()) |_| : (size += 1) {}
    iter.reset();
    return size;
}

const PrintStatusProgramError = error{
    NoProgramName,
    ProcessProgramNotFound,
} || fs.File.SeekError || fs.File.LockError || Allocator.Error || std.Io.Writer.Error;

fn printStatusProgram(opt_program_name: ?[]const u8) PrintStatusProgramError!void {
    if (opt_program_name == null) return PrintStatusProgramError.NoProgramName;
    const program_name = opt_program_name.?;

    if (std.mem.eql(u8, program_name, "file")) {
        std.debug.print("FileConfig:\n\n{s}\n", .{parser.current_config});
        return;
    }
    const opt_pp = exec.process_program_map.get(program_name);
    if (opt_pp == null) return PrintStatusProgramError.ProcessProgramNotFound;
    const process_program = opt_pp.?;


    // Init allocator
    var buffer: [65536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const printer: *Printer = try .init(allocator, .Stdout, null);
    defer printer.deinit();

    var i: usize = 0;
    var count: usize = 0;
    process_program.mutex.lock();
    defer process_program.mutex.unlock();
    const process_list = process_program.getProcessList();
    const slices = process_list.items;
    if (slices.len == 0) {
        try printer.print("{s} as no running process...\n", .{program_name});
        return;
    }
    try printer.print("{s} status of process\n.\n", .{program_name});
    while (i < slices.len) : (i += 1) {
        const pid = slices[i];
        if (i+1 == slices.len) try printer.print("└── ", .{}) else try printer.print("├── ", .{});
        std.posix.kill(pid, 0) catch |err| switch (err) {
            error.PermissionDenied => {
                try printer.print("{d} 𐄂\n", .{pid});
                continue;
            },
            error.ProcessNotFound => {
                try printer.print("{d} 𐄂\n", .{pid});
                continue;
            },
            else => @panic("unknown error when communicating to process"),
        };
        try printer.print("{d} ✓\n", .{pid});
        count += 1;
    }
}

fn printStatusAllProgram() !void {
    try exec.checkStatusSafe();
}

/// Print the current status of all program if no programs is specified or
/// print the status of all process of a specific program.
fn statusPrograms(line: []const u8) !void {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    const size = countSizeIterator(&iter);
    if (size == 1) {
        return try printStatusAllProgram();
    }
    _ = iter.next();
    try printStatusProgram(iter.next());
}

/// Restart program given by it's name,
/// this will do `stopProgram()` and `startProgram()`.
fn restartProgram(allocator: Allocator, line: []const u8) !*ExecutionResult {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    const size = countSizeIterator(&iter);
    if (size > 2) return ProgramError.HighTokenCount;
    var stdout_printer: *Printer = try .init(allocator, .Stdout, null);
    defer stdout_printer.deinit();
    stopProgram(line, false) catch |err| switch (err) {
        error.ProgramNotFound => try stdout_printer.print("Skipping stop process...\n", .{}),
        else => return err,
    };
    return try startProgram(allocator, line, false);
}

/// Stop program given by it's name,
/// this should match any program present in `program_map`.
fn stopProgram(line: []const u8, count: bool) !void {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    if (count) {
        const size = countSizeIterator(&iter);
        if (size > 2) return ProgramError.HighTokenCount;
    }
    // log creation
    var log_file = try std.fs.cwd().createFile("stop_program.log", .{.truncate = true, .read = true });
    defer log_file.close();
    const program_printer: *Printer = try .init(std.heap.page_allocator, .Stdout, &log_file);
    defer program_printer.deinit();

    try program_printer.print("Stop program detected...\n", .{});
    _ = iter.next();
    if (iter.next()) |token| {
        try program_printer.print("Program to stop is '{s}'...\n", .{token});
        const opt_val = parser.programs_map.get(token);
        if (opt_val) |program| {
            const execution_pool = &global.execution_pool;
            for (0..execution_pool.items.len, execution_pool.items) |i, result| {
                const program_name = result.program.name;
                if (mem.eql(u8, program_name, program.name)) { 
                    result.worker.deinit();
                    try exec.exitCleanly(program);
                    _ = execution_pool.orderedRemove(i);
                    return;
                }
            }
        }
    }
    return ProgramError.ProgramNotFound;
}

/// Start program given by it's name, 
/// this should match any program present in `program_map`.
fn startProgram(allocator: Allocator, line: []const u8, count: bool) !*ExecutionResult {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    if (count) {
        const size = countSizeIterator(&iter);
        if (size > 2) return ProgramError.HighTokenCount;
    }
    // log creation
    var log_file = try std.fs.cwd().createFile("program_start.log", .{.truncate = true, .read = true });
    defer log_file.close();
    const program_printer: *Printer = try .init(allocator, .Stdout, &log_file);
    defer program_printer.deinit();

    try program_printer.print("Start program detected...\n", .{});
    _ = iter.next();
    if (iter.next()) |token| {
        try program_printer.print("Program to start is '{s}'...\n", .{token});
        const opt_val = parser.programs_map.get(token);
        if (opt_val) |program| {
            var execution_result: *exec.ExecutionResult = undefined;
            var validity_pool: []*std.Thread = try allocator.alloc(*std.Thread, program.numprocs);
            defer {
                var i: usize = 0;
                while (i < validity_pool.len) : (i += 1) {
                    validity_pool[i].join();
                    allocator.destroy(validity_pool[i]);
                }
                allocator.free(validity_pool);
            }
            for (0..program.numprocs) |i| {
                execution_result = exec.startExecution(allocator, program) catch |err| {
                    switch (err) {
                        error.NoProcessProgramFound => std.debug.print("process_program not found\n", .{}),
                        else => std.debug.print("error for execution: {s}\n", .{@errorName(err)}),
                    }
                    return err;
                };
                validity_pool[i] = execution_result.validity_thread;
                execution_result.process_runner.deinit();
                allocator.destroy(execution_result);
            }

            execution_result = try allocator.create(exec.ExecutionResult);
            errdefer allocator.destroy(execution_result);
            execution_result.* = .{
                .worker = try .init(allocator, program.name, exec.checkUpProcess, .{ allocator, program }),
                .program = program,
                .process_runner = undefined,
                .validity_thread = undefined,
            };
            return execution_result;
        }
        try program_printer.print("error program not found '{s}'...\n", .{token});
    }
    return ProgramError.ProgramNotFound;
}

/// Print information about a specific command.
fn printCommandHelp(printer: *Printer, token: []const u8) !void  {
    if (mem.eql(u8, token, "exit")) {
        try printer.print("usage: 'exit' (quit the program gracefully)\n", .{});
    } else if (mem.eql(u8, token, "stop")) {
        try printer.print("usage: 'stop <program_name>' (stop the program_name provided from runing)\n", .{});
    } else if (mem.eql(u8, token, "start")) {
        try printer.print("usage: 'start <program_name>' (start the program_name provided)\n", .{});
    } else if (mem.eql(u8, token, "status")) {
        try printer.print("usage: 'status <optional_progam_name>|file' (print the process status of a program or all status of all program or 'file' to show current config.)\n", .{});
    } else if (mem.eql(u8, token, "reload")) {
        try printer.print("usage: 'reload' (reload configuration from the same path file provided)\n", .{});
    } else if (mem.eql(u8, token, "restart")) {
        try printer.print("usage: 'restart <program_name>' (restart the program_name provided do a stop first and a start)\n", .{});
    }
}

/// Print an helper about all the commands and how to use them.
fn printHelper(allocator: Allocator, line: []const u8) !void {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    const size = countSizeIterator(&iter);
    if (size > 2) return ProgramError.HighTokenCount;
    const stderr: *Printer = try .init(allocator, .Stderr, null);
    defer stderr.deinit();
    if (size < 2) {
        try stderr.print(
            "Here are the available command:\n"
            ++ "\t- 'exit'\n"
            ++ "\t- 'stop'\n"
            ++ "\t- 'start'\n"
            ++ "\t- 'status'\n"
            ++ "\t- 'reload'\n"
            ++ "\t- 'restart'\n"
            ++ "Type 'help' plus one of the command above to get more information about it.\n"
            , .{});
    } else {
        _ = iter.next();
        if (iter.next()) |token| try printCommandHelp(stderr, token);
    }
}

const ProgramActionError = error{
    EmptyLine
};

pub fn doProgramAction(allocator: Allocator, line: []const u8) !*ProgramAction {
    const program_action = try allocator.create(ProgramAction);
    errdefer allocator.destroy(program_action);
    program_action.*.allocator = allocator;
    program_action.*.execution_pool = null;
    program_action.*.execution_result = null;
    program_action.*.result = false;
    var command: []const u8 = undefined;
    var iter = std.mem.tokenizeScalar(u8, line, ' '); 
    if (iter.next()) |token| command = token else return ProgramActionError.EmptyLine;
    if (mem.eql(u8, command, "exit")) {
        program_action.result = true;
        return program_action;
    } else if (mem.eql(u8, command, "help")) {
        try printHelper(allocator, line);
    } else if (mem.eql(u8, command, "reload")) {
        program_action.*.execution_pool = try conf.loadConfiguration(allocator, false);
    } else if (mem.eql(u8, command, "status")) {
        try statusPrograms(line);
    } else if (mem.eql(u8, command, "start")) {
        program_action.*.execution_result = try startProgram(allocator, line, true);
    } else if (mem.eql(u8, command, "stop")) {
        try stopProgram(line, true);
    } else if (mem.eql(u8, command, "restart")) {
        program_action.*.execution_result = try restartProgram(allocator, line);
    } else {
        try lev.findLevenshteinError(allocator, command);
    }
    return program_action;
}
