const std = @import("std");
const Ymlz = @import("yaml").Ymlz;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const gpa = std.heap.page_allocator;

const Program = struct {
    name: []const u8,
    cmd: []const u8,
    numprocs: u16,
    umask: u16,
    workingdir: []const u8,
    autostart: bool,
    autorestart: []const u8,
    exitcodes:[]const u8,
    startretries: u16,
    starttime: u16,
    stopsignal: []const u8,
    stoptime: u16,
    stdout: []const u8,
    stderr: []const u8,
    env: ?[]const u8
};

const ProgramsYaml = struct {
    programs: []Program,
};

const ReadYamlError = error{
    FailedRead,
};

pub var programs_map: StringHashMap(Program) = undefined;

/// return an allocated buffer of the file read by the given path.
pub fn readYamlFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();

    const size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, size);

    const ret = try file.readAll(buffer);
    return if (ret != size) ReadYamlError.FailedRead else buffer;
}

pub fn startParsing(allocator: Allocator, path: []const u8) !void {
    const realpath = try std.fs.cwd().realpathAlloc(allocator, path);
    defer allocator.free(realpath);
    std.debug.print("startParsing realpath: '{s}'\n", .{realpath});
    const buf = readYamlFile(allocator, realpath) catch |err| {
        switch (err) {
            error.FailedRead => std.debug.print("error: FailedRead didn't read all the file\n", .{}),
            else => std.debug.print("error: unknown {s}\n", .{@errorName(err)}),
        }
        return err;
    };
    defer allocator.free(buf);

    var ymlz = try Ymlz(ProgramsYaml).init(allocator);
    const result = try ymlz.loadRaw(buf);
    defer ymlz.deinit(result);

    programs_map = .init(allocator);
    errdefer programs_map.deinit();
    for (result.programs) |program| {
        try programs_map.put(program.name, program);
    }
}
