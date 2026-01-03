const std = @import("std");
const posix = std.posix;


const exec = @import("../programs/execution.zig");
const ProcessProgram = @import("../lib/ProcessProgram.zig");
const Printer = @import("../lib/Printer.zig");
const Ymlz = @import("yaml").Ymlz;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const gpa = std.heap.page_allocator;

pub const Program = struct { 
    name: []const u8, 
    cmd: []const u8, 
    numprocs: u16,
    umask: []const u8,
    workingdir: []const u8,
    autostart: bool,
    autorestart: []const u8,
    exitcodes: []const u8,
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

pub var autostart_map: StringHashMap(*Program) = undefined;
pub var programs_map: StringHashMap(*Program) = undefined;


/// Clone non allocated program to allocated program.
fn cloneProgram(allocator: Allocator, original: *const Program) !*Program {
    const clone = try allocator.create(Program);
    errdefer allocator.destroy(clone);
    clone.* = original.*;

    inline for (std.meta.fields(Program)) |field| {
        if (field.type == []const u8 or field.type == []u8) {
            const field_value = @field(original.*, field.name);
            @field(clone, field.name) = try allocator.dupe(u8, field_value);
            errdefer allocator.free(@field(clone, field.name));
        }
    }

    return clone;
}

/// Clear function needed to destroy program.
fn destroyProgram(allocator: Allocator, to_destroy: *Program) void {
    inline for (std.meta.fields(Program)) |field| {
        if (field.type == []const u8 or field.type == []u8) {
            allocator.free(@field(to_destroy, field.name));
        }
    }
    allocator.destroy(to_destroy);
}

/// Release ressources `program_map` and `autostart_map`.
pub fn deinitPrograms(allocator: Allocator) void {
    var iter = programs_map.iterator();
    while (iter.next()) |entry| {
        destroyProgram(allocator, entry.value_ptr.*);
    }
    iter = autostart_map.iterator();
    while (iter.next()) |entry| {
        destroyProgram(allocator, entry.value_ptr.*);
    }
    autostart_map.deinit();
    programs_map.deinit();
}

/// Get the signal `u6` to the coresponding string that you pass.
pub fn getSignal(signal: []const u8) !u6 {
    const signals = std.StaticStringMap(u6).initComptime(.{
        // Termination
        .{ "INT",  std.posix.SIG.INT },
        .{ "TERM", std.posix.SIG.TERM },
        .{ "KILL", std.posix.SIG.KILL },
        .{ "QUIT", std.posix.SIG.QUIT },

        // Control
        .{ "STOP", std.posix.SIG.STOP },
        .{ "CONT", std.posix.SIG.CONT },
        .{ "HUP",  std.posix.SIG.HUP },
        
        // Custom
        .{ "USR1", std.posix.SIG.USR1 },
        .{ "USR2", std.posix.SIG.USR2 },
        
        // Errors
        .{ "SEGV", std.posix.SIG.SEGV },
        .{ "ILL",  std.posix.SIG.ILL },
    });
    const opt_val = signals.get(signal);
    if (opt_val == null) return error.SignalNotFound;
    return opt_val.?;
}

/// Return an allocated buffer of the file read by the given path.
pub fn readYamlFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();

    const size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, size);

    const ret = try file.readAll(buffer);
    return if (ret != size) ReadYamlError.FailedRead else buffer;
}

/// Return allocated ressources the caller need to free the return value.
pub fn parseEnv(allocator: Allocator, opt_env: ?[]const u8) ![*:null]const ?[*:0]const u8 {
    const sys_env_slice = std.os.environ;
    var extra_size: usize = 0;
    if (opt_env) |env_line| {
        var iter = std.mem.splitScalar(u8, env_line, ',');
        while (iter.next()) |_| : (extra_size += 1) {}
    }
    const total_len = extra_size + sys_env_slice.len;
    const env = try allocator.allocSentinel(?[*:0]const u8, total_len, null);

    var current_idx: usize = 0;
    errdefer {
        for (0..current_idx) |i| {
            if (env[i]) |s| allocator.free(std.mem.span(s));
        }
        allocator.free(env);
    }

    for (sys_env_slice) |line| {
        env[current_idx] = try allocator.dupeZ(u8, std.mem.span(line));
        current_idx += 1;
    }

    if (opt_env) |line| {
        var iter = std.mem.splitScalar(u8, line, ',');
        while (iter.next()) |part| : (current_idx += 1) {
            env[current_idx] = try allocator.dupeZ(u8, part);
        }
    }

    return env;
}

pub fn startParsing(allocator: Allocator, path: []const u8, printer: *Printer)  !void {
    try printer.print("starting parsing...\n", .{});
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

    var process_program: *ProcessProgram = undefined;
    var ymlz = try Ymlz(ProgramsYaml).init(allocator);
    const result = try ymlz.loadFile(realpath);
    defer ymlz.deinit(result);

    programs_map = .init(allocator);

    // autostart_map is only needed for the autostart functionality,
    // and to keep track of which program is needed for autostart when reloading config.
    autostart_map = .init(allocator);
    errdefer programs_map.deinit();
    errdefer autostart_map.deinit();
    errdefer exec.process_program_map.deinit(); // deinit content when err received.
    for (result.programs) |program| {
        const clone = try cloneProgram(allocator, &program);
        errdefer destroyProgram(allocator, clone);
        if (clone.autostart) {
            try autostart_map.put(clone.name, clone);

            // this is done because we need another clone for programs_map.
            const program_clone = try cloneProgram(allocator, &program);
            try programs_map.put(program_clone.name, program_clone);
            process_program = try .init(allocator, clone.name);
            errdefer process_program.deinit();
            try exec.process_program_map.put(clone.name, process_program);
        } else {
            try printer.print("added to program_map program.name: '{s}'\n", .{clone.name});
            process_program = try .init(allocator, clone.name);
            errdefer process_program.deinit();
            try exec.process_program_map.put(clone.name, process_program);
            try programs_map.put(clone.name, clone);
        }
    }
}
