const std = @import("std");
const mem = std.mem;

const reader = @import("reader/readline.zig");
const programs = @import("programs/programs.zig");

const assert = std.debug.assert;
const optimize = @import("builtin").mode;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const stdin = std.fs.File.stdin();

    defer stdout.close();
    defer stderr.close();
    defer stdin.close();

    // memory gpa definition this will use debug if -Doptimize=Debug other use default
    var gpa_debug  = std.heap.DebugAllocator(.{ .verbose_log = true }){};
    var gpa_default = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator: std.mem.Allocator = undefined;
    defer {
        const status = if (optimize == .Debug) gpa_debug.deinit() else gpa_default.deinit();
        if (optimize == .Debug and status == .leak) @panic("error leak");
    }
    if (optimize == .Debug) std.debug.print("Optimization mode: '{s}'\n", .{@tagName(optimize)});
    allocator = if (optimize == .Debug) gpa_debug.allocator() else gpa_default.allocator();
    while (true) {
        const line = try reader.readLine(allocator, stdin);
        std.debug.print("line: '{s}'\n", .{line});
        const exit = programs.doProgramAction(line) catch false;
        if (exit) {
            allocator.free(line);
            break;
        } else {
            const opt_pos = std.ascii.indexOfIgnoreCase(line, " ");
            if (opt_pos) |pos| {
                std.debug.print("Programs '{s}' doens't exist\n", .{line[pos+1..]});
            } else std.debug.print("Programs doens't exist\n", .{});
        }
        allocator.free(line);
    }
}
