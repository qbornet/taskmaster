const std = @import("std");
const mem = std.mem;

const parser = @import("parser/parser.zig");
const reader = @import("reader/readline.zig");
const conf = @import("programs/configuration.zig");
const exec = @import("programs/execution.zig");
const programs = @import("programs/programs.zig");

const assert = std.debug.assert;
const optimize = @import("builtin").mode;
const Allocator = std.mem.Allocator;

fn freeTaskmaster(allocator: Allocator, line: []const u8, thread_pool: []*std.Thread) void {
    allocator.free(line);
    parser.deinitPrograms(allocator);
    exec.freeThreadExecution(allocator, thread_pool);
}

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
    if (std.os.argv.len != 2) {
        std.debug.print("usage: ./taskmaster <configuration.yaml>", .{});
        std.process.exit(1);
    }
    const endIndex = std.mem.indexOfSentinel(u8, 0, std.os.argv[1]);
    const arg = std.os.argv[1][0..endIndex];
    try parser.startParsing(allocator, arg);
    const thread_pool = try conf.loadConfiguration(allocator, true);
    while (true) {
        const line = try reader.readLine(allocator, stdin);
        std.debug.print("line: '{s}'\n", .{line});
        const program_action = programs.doProgramAction(allocator, line) catch |err| blk: {
            switch (err) {
                error.HighTokenCount => std.debug.print("Too many program entry passed\n", .{}),
                error.ProgramNotFound => {
                    const opt_pos = std.ascii.indexOfIgnoreCase(line, " ");
                    if (opt_pos) |pos| {
                        std.debug.print("Programs '{s}' doens't exist\n", .{line[pos+1..]});
                    } else std.debug.print("Programs doens't exist\n", .{});
                },
                else => std.debug.print("Unknown error: '{s}'", .{@errorName(err)}),
            }
            break :blk &programs.ProgramAction{ .result = false, .thread_pool = &.{}};
        };
        if (program_action.result) {
            freeTaskmaster(allocator, line, thread_pool);
            break;
        }
        allocator.free(line);
    }
}
