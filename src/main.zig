const std = @import("std");
const mem = std.mem;

const parser = @import("parser/parser.zig");
const conf = @import("programs/configuration.zig");
const exec = @import("programs/execution.zig");
const programs = @import("programs/programs.zig");
const lev = @import("reader/levenshtein.zig");
const global = @import("lib/global_map.zig");

const optimize = @import("builtin").mode;
const Printer = @import("lib/Printer.zig");
const Allocator = std.mem.Allocator;
const LineReader = @import("lib/LineReader.zig");

/// Use only for freeing overwriten variable not for gracefull exit.  
fn freeExecutionPool(allocator: Allocator, ep: std.ArrayList(exec.ExecutionResult)) void {
    var execution_pool = ep;
    defer execution_pool.deinit(allocator);
    for (execution_pool.items) |execution_result| {
        execution_result.worker.deinit();
    }
}

fn freeTaskmaster(allocator: Allocator, line: []const u8, execution_pool: []exec.ExecutionResult) !void {
    allocator.free(parser.current_config);
    allocator.free(line);
    for (execution_pool) |value| {
        value.worker.deinit();
        try exec.exitCleanly(value.program);
    }
    exec.freeProcessProgram();
    parser.deinitPrograms(allocator);
}

fn returnArg() []const u8 {
    const endIndex = std.mem.indexOfSentinel(u8, 0, std.os.argv[1]);
    return std.os.argv[1][0..endIndex];
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
        if (status == .leak) @panic("error leak");
    }
    if (optimize == .Debug) std.debug.print("Optimization mode: '{s}'\n", .{@tagName(optimize)});
    allocator = if (optimize == .Debug) gpa_debug.allocator() else gpa_default.allocator();
    if (std.os.argv.len != 2) {
        std.debug.print("usage: ./taskmaster <configuration.yaml>", .{});
        std.process.exit(1);
    }

    var reader: LineReader  = try .init(allocator);
    defer reader.deinit();
    const stderr: *Printer = try .init(allocator, .Stderr, null);
    defer stderr.deinit();
    const stdout: *Printer = try .init(allocator, .Stdout, null);
    defer stdout.deinit();
    const arg = returnArg();
    var execution_pool = &global.execution_pool;

    try stdout.print("Starting taskmaster...\n", .{});
    try parser.startParsing(allocator, arg, stdout);
    try stdout.print("loading configuration...\n", .{});
    const tmp_pool = try conf.loadConfiguration(allocator, true);
    execution_pool.* = tmp_pool.?;
    while (true) {
        const opt_line = try reader.readLine("taskmaster> ");
        if (opt_line == null) continue;

        const line = opt_line.?;
        const program_action = programs.doProgramAction(allocator, line) catch |err| {
            switch (err) {
                error.HighTokenCount => try stderr.print("Too many program entry passed\n", .{}),
                error.ProgramNotFound => {
                    const opt_pos = std.ascii.indexOfIgnoreCase(line, " ");
                    if (opt_pos) |pos| {
                        try stderr.print("Programs '{s}' doens't exist\n", .{line[pos + 1 ..]});
                    } else try stderr.print("Programs doens't exist\n", .{});
                },
                else => try stderr.print("Unknown error: '{s}'", .{@errorName(err)}),
            }
            allocator.free(line);
            continue;
        };
        if (program_action.execution_result) |execution_result| {
            defer allocator.destroy(execution_result);
            const worker = execution_result.*.worker;
            const program = execution_result.*.program;
            try execution_pool.append(allocator, .{ 
                .worker = worker,
                .validity_thread = undefined,
                .process_runner = undefined,
                .program = program
            });
        }
        if (program_action.execution_pool) |pa_execution_pool|{
            freeExecutionPool(allocator, execution_pool.*);
            execution_pool.* = pa_execution_pool;
        }
        if (program_action.allocator != null) allocator.destroy(program_action);
        if (program_action.result) {
            try freeTaskmaster(allocator, line, execution_pool.items);
            execution_pool.deinit(allocator);
            break;
        }
        allocator.free(line);
    }
}
