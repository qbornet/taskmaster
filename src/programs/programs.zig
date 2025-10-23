const std = @import("std");
const conf = @import("configuration.zig");
const parser = @import("../parser/parser.zig");
const mem = std.mem;

const Allocator = mem.Allocator;

const ProgramError = error {
    HighTokenCount,
    ProgramNotFound
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

pub fn doProgramAction(allocator: Allocator, line: []const u8) !bool {
    if (mem.eql(u8, line, "exit")) { 
        return true;
    }  else if (mem.eql(u8, line, "reload")) {
        conf.reloadConfiguration(allocator, false);
    } else if (mem.eql(u8, line, "status")) {
        if (std.os.argv.len == 2) {
            const indexEnd = std.mem.indexOfSentinel(u8, 0, std.os.argv[1]);
            try parser.readYamlFile(allocator, std.os.argv[1][0..indexEnd-1]);
        }
    } else if (mem.startsWith(u8, line, "start")) {
        try startProgram(line, true);
    } else if (mem.startsWith(u8, line, "stop")) {
        try stopProgram(line, true);
    } else if (mem.startsWith(u8, line, "restart")) {
        try restartProgram(line);
    } 
    return false;

}
