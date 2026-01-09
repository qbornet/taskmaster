const std = @import("std");
const Allocator = std.mem.Allocator;
const Printer = @import("../lib/Printer.zig");

const ReadLineError = error{EndOfLine};

pub fn readLine(allocator: Allocator, file: std.fs.File) ![]const u8 {
    var buf: [1024]u8 = undefined;
    var input_wrapper = file.reader(&buf);
    var reader: *std.Io.Reader = &input_wrapper.interface;

    // add small prompt ? 
    while (reader.takeDelimiterExclusive('\n')) |line| {
        return try allocator.dupe(u8, line);
    } else |err| if (err != error.EndOfStream) return err;
    return ReadLineError.EndOfLine;
}
