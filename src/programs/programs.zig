const std = @import("std");
const conf = @import("configuration.zig");
const parser = @import("../parser/parser.zig");
const mem = std.mem;

const Allocator = mem.Allocator;

const ProgramError = error {
    HighTokenCount,
    ProgramNotFound
};

pub const ProgramAction = struct {
    result: bool,
    thread_pool: []*std.Thread,
};

fn countSizeIterator(iter: *mem.TokenIterator(u8, .scalar)) usize {
    var size: usize = 0;

    while (iter.next()) |_| : (size += 1) {}
    iter.reset();
    return size;
}

fn restartProgram(line: []const u8) !void {
    std.debug.print("in restart line is '{s}'\n", .{line});
    var iter = mem.tokenizeScalar(u8, line, ' ');
    const size = countSizeIterator(&iter);
    if (size > 2) return ProgramError.HighTokenCount;
    try stopProgram(line, false);
    try startProgram(line, false);
}

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

fn startProgram(line: []const u8, count: bool) !void {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    if (count) {
        const size = countSizeIterator(&iter);
        if (size > 2) return ProgramError.HighTokenCount;
    }
    if (iter.next()) |token| {
        std.debug.print("start program token: '{s}'\n", .{token});
        // use  string hash map of current structure of programs to run.
        // then run that program if it exist return err if not.
        return ProgramError.ProgramNotFound;
    }
}

pub fn doProgramAction(allocator: Allocator, line: []const u8) !*ProgramAction {
    const program_action = try allocator.create(ProgramAction);
    errdefer allocator.destroy(program_action);

    program_action.result = false;
    const arg = std.os.argv[1];
    if (mem.eql(u8, line, "exit")) { 
        program_action.result = true;
        return program_action;
    }  else if (mem.eql(u8, line, "reload")) {
        program_action.thread_pool = try conf.loadConfiguration(allocator, false);
    } else if (mem.eql(u8, line, "status")) {
            const end = std.mem.indexOfSentinel(u8, 0, arg);
            const realpath = try std.fs.cwd().realpathAlloc(allocator, arg[0..end]);
            defer allocator.free(realpath);
            const result = try parser.readYamlFile(allocator, realpath);
            defer allocator.free(result);
            std.debug.print("{s}\n", .{result});
    } else if (mem.startsWith(u8, line, "start")) {
        try startProgram(line, true);
    } else if (mem.startsWith(u8, line, "stop")) {
        try stopProgram(line, true);
    } else if (mem.startsWith(u8, line, "restart")) {
        try restartProgram(line);
    } 
    return program_action;
}
