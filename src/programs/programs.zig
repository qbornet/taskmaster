const std = @import("std");
const exec = @import("execution.zig");
const conf = @import("configuration.zig");
const parser = @import("../parser/parser.zig");
const lev = @import("../reader/levenshtein.zig");
const mem = std.mem;

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

/// Restart program given by it's name,
/// this will do `stopProgram()` and `startProgram()`.
fn restartProgram(allocator: Allocator, line: []const u8) !*ExecutionResult {
    std.debug.print("in restart line is '{s}'\n", .{line});
    var iter = mem.tokenizeScalar(u8, line, ' ');
    const size = countSizeIterator(&iter);
    if (size > 2) return ProgramError.HighTokenCount;
    try stopProgram(line, false);
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
    if (iter.next()) |token| {
        std.debug.print("stop program token: '{s}'\n", .{token});
        return ProgramError.ProgramNotFound;
    }
}

/// Start program given by it's name, 
/// this should match any program present in `program_map`.
fn startProgram(allocator: Allocator, line: []const u8, count: bool) !*ExecutionResult {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    if (count) {
        const size = countSizeIterator(&iter);
        if (size > 2) return ProgramError.HighTokenCount;
    }
    if (iter.next()) |token| {
        const opt_val = parser.programs_map.get(token);
        if (opt_val) |program| {
            const execution_result = try exec.startExecution(allocator, program);

            // clear unused ressources and join thread.
            execution_result.process_runner.deinit();
            execution_result.validity_thread.join();
            allocator.destroy(execution_result.validity_thread);

            execution_result.*.validity_thread = undefined;
            execution_result.*.worker = try .init(allocator, program.name, exec.checkUpProcess, .{ allocator, program });
            return execution_result;
        }
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
        try printer.print("usage: 'status' (print the current known configuration passed as parameter)\n", .{});
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

pub fn doProgramAction(allocator: Allocator, line: []const u8) !*ProgramAction {
    const program_action = try allocator.create(ProgramAction);
    errdefer allocator.destroy(program_action);
    program_action.*.allocator = allocator;
    program_action.*.execution_pool = null;
    program_action.*.execution_result = null;
    program_action.*.result = false;
    const arg = std.os.argv[1];
    if (mem.eql(u8, line, "exit")) {
        program_action.result = true;
        return program_action;
    } else if (mem.startsWith(u8, line, "help")) {
        try printHelper(allocator, line);
    } else if (mem.eql(u8, line, "reload")) {
        program_action.*.execution_pool = try conf.loadConfiguration(allocator, false);
    } else if (mem.eql(u8, line, "status")) {
        const end = std.mem.indexOfSentinel(u8, 0, arg);
        const realpath = try std.fs.cwd().realpathAlloc(allocator, arg[0..end]);
        defer allocator.free(realpath);
        const result = try parser.readYamlFile(allocator, realpath);
        defer allocator.free(result);
        std.debug.print("{s}\n", .{result});
    } else if (mem.startsWith(u8, line, "start")) {
        program_action.*.execution_result = try startProgram(allocator, line, true);
    } else if (mem.startsWith(u8, line, "stop")) {
        try stopProgram(line, true);
    } else if (mem.startsWith(u8, line, "restart")) {
        program_action.*.execution_result = try restartProgram(allocator, line);
    } else {
        try lev.findLevenshteinError(allocator, line);
    }
    return program_action;
}
