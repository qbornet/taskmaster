const std = @import("std");
const Allocator = std.mem.Allocator;
const Printer = @import("../lib/Printer.zig");

const cmds: [6][]const u8 = .{
    "stop",
    "exit",
    "start",
    "status",
    "reload",
    "restart",
};

/// Return a distance of levenshtein 0 or positive.
fn distLevenshtein(a: []const u8, b: []const u8) !usize {
    var current_line: [4096]usize = undefined;
    var prev_line: [4096]usize = undefined;
    const source = if (a.len < b.len) b else a;
    const target = if (a.len < b.len) a else b;
    const n = target.len;

    if (current_line.len < n + 1) {
        return error.BufferToSmall;
    }

    for (0..n+1) |i| {
        current_line[i] = i;
    }
    @memcpy(&prev_line, &current_line);

    for (0..source.len) |i| {
        var current = i + 1;
        var previous_diag = prev_line[0];
        for (0..n) |j| {
            const previous_col = prev_line[j + 1];
            const cost: usize = if (source[i] == target[j]) 0 else 1;
            const substitution = previous_diag + cost;
            const deletion = previous_col + 1;
            const insertion = current + 1;

            previous_diag = previous_col;
            current = @min(substitution, deletion, insertion);
            current_line[j + 1] = current;
        }
        @memcpy(&prev_line, &current_line);
    }
    return current_line[n];
}

pub fn findLevenshteinError(allocator: Allocator, target: []const u8) !void {
    const stderr: *Printer = try .init(allocator, .Stderr, null);
    defer stderr.deinit();
    var map_result: std.StringHashMap(usize) = .init(allocator);
    defer map_result.deinit();
    for (cmds) |cmd| {
        const dist = try distLevenshtein(target, cmd);
        try map_result.put(cmd, dist);
    }
    var result_string: []const u8 = undefined;
    var result: usize = std.math.maxInt(usize);
    var iter = map_result.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* < result) {
            result_string = entry.key_ptr.*;
            result = entry.value_ptr.*;
        }
    }
    try stderr.print("maybe you want '{s}' if not type 'help' for more information.\n", .{result_string});
}
