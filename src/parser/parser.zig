const std = @import("std");
const Yaml = @import("yaml").Yaml;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const gpa = std.heap.page_allocator;

const ProgramsYaml = struct {
    programs: []struct {
        name: []const u8,
        content: struct {
            cmd: []const u8,
            numprocs: u64,
            umask: u8,
            workingdir: []const u8,
            autostart: bool,
            exitcodes:[]u8,
            startretires: u64,
            starttime: u64,
            stopsignal: []const u8,
            stoptime: u64,
            stdout: []const u8,
            stderr: []const u8,
            env: []StringHashMap([]const u8),
        },
    }
};

pub var programs_map: StringHashMap(ProgramsYaml) = undefined;

pub fn readYamlFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const realpath = try std.fs.realpathAlloc(allocator, path);
    defer allocator.free(realpath);

    const file = try std.fs.openFileAbsolute(realpath, .{ .mode = .read_only });
    defer file.close();

    const size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, size);

    _ = try file.readAll(buffer);
    return buffer;
}

pub fn startParsing(allocator: Allocator, path: []const u8, errFile: *std.fs.File) !void {
    const realpath = try std.fs.realpathAlloc(allocator, path);
    defer allocator.free(realpath);
    std.debug.print("startParsing realpath: '{s}'\n", .{realpath});
    const buf = try readYamlFile(allocator, realpath);

    var yaml: Yaml = .{ .source = buf };
    defer yaml.deinit(allocator);
    yaml.load(allocator) catch |err| switch (err) {
        error.ParseFailure => {
            yaml.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(errFile)});
            return error.ParseFailure;
        },
        else => return err,
    };

    const result = try yaml.parse(allocator, ProgramsYaml);
}
