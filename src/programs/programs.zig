const std = @import("std");
const mem = std.mem;

const ProgramError = error {
    HighTokenCount,
    ProgramNotFound
};

fn restartProgram(line: []const u8) !void {
    std.debug.print("in restart line is '{s}'\n", .{line});
    try stopProgram(line);
    try startProgram(line);
}

fn stopProgram(line: []const u8) !void {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    if (iter.next()) |token| {
        std.debug.print("stop program token: '{s}'\n", .{token});
        return ProgramError.ProgramNotFound;
    }
}

fn startProgram(line: []const u8) !void {
    var iter = mem.tokenizeScalar(u8, line, ' ');
    if (iter.buffer.len >= 2) return ProgramError.HighTokenCount;
    if (iter.next()) |token| {
        std.debug.print("start program token: '{s}'\n", .{token});
        // use  string hash map of current structure of programs to run.
        // then run that program if it exist return err if not.
        return ProgramError.ProgramNotFound;
    }
}

pub fn doProgramAction(line: []const u8) !bool {
    if (mem.eql(u8, line, "exit")) { 
        return true;
    }  else if (mem.eql(u8, line, "reload")) {
        // reload
    } else if (mem.startsWith(u8, line, "start")) {
        try startProgram(line);
    } else if (mem.startsWith(u8, line, "stop")) {
        try stopProgram(line);
    } else if (mem.startsWith(u8, line, "restart")) {
        try restartProgram(line);
    }
    return false;

}
