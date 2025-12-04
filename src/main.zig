const std = @import("std");
const mem = std.mem;

const parser = @import("parser/parser.zig");
const reader = @import("reader/readline.zig");
const conf = @import("programs/configuration.zig");
const exec = @import("programs/execution.zig");
const programs = @import("programs/programs.zig");

const assert = std.debug.assert;
const optimize = @import("builtin").mode;
const Printer = @import("lib/Printer.zig");
const Allocator = std.mem.Allocator;

fn freeTaskmaster(allocator: Allocator, line: []const u8, execution_pool: []*exec.ExecutionResult) void {
    std.debug.print("freeing line\n", .{});
    allocator.free(line);
    // exec.freeProcessProgram();
    std.debug.print("freeing thread execution\n", .{});
    exec.freeExecutionPool(allocator, execution_pool);
    std.debug.print("freeing parser programs_map and autostart_map\n", .{});
    parser.deinitPrograms(allocator);
    std.debug.print("finished freeing\n", .{});
}

fn returnArg() []const u8 {
    const endIndex = std.mem.indexOfSentinel(u8, 0, std.os.argv[1]);
    return std.os.argv[1][0..endIndex];
}

fn createLogFile(allocator: Allocator) !*std.fs.File {
    const file = try allocator.create(std.fs.File);
    errdefer allocator.destroy(file);
    file.* = try std.fs.cwd().createFile("logger.log", .{ .truncate = true });
    return file;
}

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    defer stdin.close();

    // memory gpa definition this will use debug if -Doptimize=Debug other use default
    var gpa_debug = std.heap.DebugAllocator(.{ .verbose_log = true }){};
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

    const log_file = try createLogFile(allocator);
    defer allocator.destroy(log_file);
    const stdout: *Printer = try .init(allocator, .Stdout, log_file);
    defer stdout.deinit();
    try stdout.print("Starting taskmaster...\n", .{});
    const arg = returnArg();
    try parser.startParsing(allocator, arg);
    const execution_pool = try conf.loadConfiguration(allocator, true);
    for (0..execution_pool.len, execution_pool) |i, execution| {
        std.debug.print("[{d}]: worker: {*}\n", .{ i, execution.worker });
        std.debug.print("[{d}]: validity_thread: {*}\n", .{ i, execution.validity_thread });
        execution.validity_thread.join();
    }
    while (true) {
        const line = try reader.readLine(allocator, stdin);
        std.debug.print("line: '{s}'\n", .{line});
        const program_action = programs.doProgramAction(allocator, line) catch |err| blk: {
            switch (err) {
                error.HighTokenCount => std.debug.print("Too many program entry passed\n", .{}),
                error.ProgramNotFound => {
                    const opt_pos = std.ascii.indexOfIgnoreCase(line, " ");
                    if (opt_pos) |pos| {
                        std.debug.print("Programs '{s}' doens't exist\n", .{line[pos + 1 ..]});
                    } else std.debug.print("Programs doens't exist\n", .{});
                },
                else => std.debug.print("Unknown error: '{s}'", .{@errorName(err)}),
            }
            break :blk &programs.ProgramAction{ .allocator = null, .result = false, .thread_pool = &.{} };
        };
        if (program_action.result) {
            if (program_action.allocator != null) allocator.destroy(program_action);
            freeTaskmaster(allocator, line, execution_pool);
            break;
        }
        if (program_action.allocator != null) {
            allocator.destroy(program_action);
        }
        allocator.free(line);
    }
}
