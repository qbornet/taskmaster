const std = @import("std");

const assert = std.debug.assert;

const optimize = @import("builtin").mode;
const Yaml = @import("yaml").Yaml;

const source =
    \\names: [ John Doe, MacIntosh, Jane Austin ]
    \\numbers:
    \\  - 10
    \\  - -8
    \\  - 6
    \\nested:
    \\  some: one
    \\  wick: john doe
    \\finally: [ 8.17,
    \\           19.78      , 17 ,
    \\           21 ]
;


pub fn main() !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

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
    var yaml: Yaml = .{ .source = source };
    yaml.load(allocator) catch |err| switch (err) {
        error.ParseFailure => {
            assert(yaml.parse_errors.errorMessageCount() > 0);
            yaml.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(stderr)});
        },
        else => return err,
    };
    //var arena = if (optimize == .Debug ) std.heap.ArenaAllocator.init(gpa_debug) else std.heap.ArenaAllocator.init(gpa_default);
    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);
    var writer = stdout.writer(buffer);
    try yaml.stringify(&writer.interface);
    std.debug.print("yaml: {s}\n", .{buffer});
    yaml.deinit(allocator);
}
