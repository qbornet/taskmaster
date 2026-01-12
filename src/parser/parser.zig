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

pub var current_config: []const u8 = undefined;
pub var autostart_map: StringHashMap(*Program) = undefined;
pub var programs_map: StringHashMap(*Program) = undefined;


/// Clone new if didn't exist, modify the program via diff.
fn realoadProgramMap(allocator: Allocator, new: *const Program) !void {
    const opt_auto_original: ?*Program = autostart_map.get(new.name);
    const opt_original: ?*Program = programs_map.get(new.name);
    if (opt_auto_original == null and new.autostart) {
        const clone = try cloneProgram(allocator, new);
        allocator.destroy(new);
        try autostart_map.put(clone.name, clone);
    } else if (opt_auto_original != null) {
        try diffProgram(allocator, opt_auto_original.?, new);
    }
    if (opt_original == null) {
        const clone = try cloneProgram(allocator, new);
        allocator.destroy(new);
        try programs_map.put(clone.name, clone);
    } else {
        try diffProgram(allocator, opt_original.?, new);
    }
}

/// Change the original program with the new program value.
fn diffProgram(allocator: Allocator, original: *Program, new: *const Program) !void {
    inline for (std.meta.fields(Program)) |field| {
        if (field.type == []const u8 or field.type == []u8) blk: {
            const old_value = @field(original.*, field.name);
            const field_value = @field(new.*, field.name);
            if (std.mem.eql(u8, old_value, field_value)) break :blk;
            @field(original, field.name) = try allocator.dupe(u8, field_value);
            errdefer allocator.free(@field(original, field.name));
            allocator.free(old_value);
        }
        if (field.type == ?[]const u8) blk: {
            const old_value = @field(original.*, field.name);
            const field_value = @field(new.*, field.name);
            if ((old_value == null and field_value == null) 
                or (old_value != null and field_value != null 
                    and std.mem.eql(u8, old_value.?, field_value.?))) break :blk;
            if (old_value == null and field_value != null) {
                @field(original, field.name) = try allocator.dupe(u8, field_value.?);
                errdefer allocator(@field(original, field.name));
            } else if (old_value != null and field_value == null) {
                allocator.free(old_value.?);
                @field(original, field.name) = null;
            } else {
                @field(original, field.name) = try allocator.dupe(u8, field_value.?);
                errdefer allocator.free(@field(original, field.name));
                allocator.free(old_value.?);
            }
        }
        if (field.type == bool) blk: {
            const old_value = @field(original.*, field.name);
            const field_value = @field(new.*, field.name);
            if (old_value == field_value) break :blk;
            @field(original, field.name) = field_value;
        }
        if (field.type == u16) blk: {
            const old_value = @field(original.*, field.name);
            const field_value = @field(new.*, field.name);
            if (old_value == field_value) break :blk;
            @field(original, field.name) = field_value;
        }
    }
}

fn validWorkingDir(workingdir: []const u8) !bool {
    const dir = try std.fs.openDirAbsolute(workingdir, .{});
    const stat = try dir.stat();
    if (stat.kind != .directory) return error.NotADirectory;
    return (stat.mode & std.c.S.IXUSR) != 0;
}

fn validCommand(cmd: []const u8) !bool {
    const file = try std.fs.openFileAbsolute(cmd, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file) return error.NotAFile;
    return (stat.mode & std.c.S.IXUSR) != 0;
}

const ValidParserError = error{
    EmptyName,
    InvalidName,
    InvalidUmask,
    InvalidSignal,
    InvalidCommand,
    InvalidWorkingDir,
    InvalidNumOfProcess,
    InvalidRestartPolicies,
};

fn validParser(allocator: Allocator, result: ProgramsYaml) !void {
    var name_set: std.BufSet = .init(allocator);
    defer name_set.deinit();
    const printer: *Printer = try .init(allocator, .Stderr, null);
    defer printer.deinit();
    const rlim = try posix.getrlimit(posix.rlimit_resource.NPROC);
    for (result.programs) |program| {
        if (name_set.contains(program.name)) {
            try printer.print("error parsing: Invalid name you already have a program name '{s}\n'", .{program.name});
            return ValidParserError.InvalidName;
        }
        if (std.mem.eql(u8, program.name, "file")) {
            try printer.print("error parsing: '{s}' is reserved and cannot be used\n", .{program.name});
            return ValidParserError.InvalidName;
        }
        if (std.mem.eql(u8, program.name, "")) {
            try printer.print("error parsing: Empty name not allowed for program\n", .{});
            return ValidParserError.EmptyName;
        }
        try name_set.insert(program.name);
        var ret = if (validCommand(program.cmd)) |r| r else |err| {
            switch (err) {
                error.FileNotFound => try printer.print("error parsing: '{s}': Command file doesn't exist should be absolute path\n", .{program.name}),
                error.AccessDenied => try printer.print("error parsing: '{s}': Command not allowed unsifficent permision\n", .{program.name}),
                error.NotAFile => try printer.print("error parsing: '{s}': Command is not a file\n", .{program.name}),
                else => try printer.print("error parsing: '{s}': error '{s}'\n", .{program.name, @errorName(err)}),
            }
            return ValidParserError.InvalidCommand;
        };
        if (!ret) {
            try printer.print("error parsing: '{s}': Command is not executable\n", .{program.name});
            return ValidParserError.InvalidCommand;
        }
        if (program.numprocs >= rlim.max) {
            try printer.print("error parsing: '{s}': Number of process is to high not allowed\n", .{program.name});
            return ValidParserError.InvalidNumOfProcess;
        }
        if (std.fmt.parseInt(u16, program.umask, 8)) |_| _ = true else |err| {
            switch (err) {
                error.InvalidCharacter => try printer.print("error parsing: '{s}': Umask is not written in octal format\n", .{program.name}),
                error.Overflow => try printer.print("error parsing: '{s}': Umask is overflowing\n", .{program.name}),
            }
            return ValidParserError.InvalidUmask;
        }
        // add valid exitcodes
        ret = if (validWorkingDir(program.workingdir)) |r| r else |err| {
            switch (err) {
                error.FileNotFound => try printer.print("error parsing: '{s}': WorkingDir doesn't exist should be absolute path\n", .{program.name}),
                error.AccessDenied => try printer.print("error parsing: '{s}': WorkingDir not allowed unsifficent permision\n", .{program.name}),
                error.NotADirectory => try printer.print("error parsing: '{s}': WorkingDir is not a directory\n", .{program.name}),
                else => try printer.print("error parsing: '{s}': error '{s}'\n", .{program.name, @errorName(err)}),
            }
            return ValidParserError.InvalidWorkingDir;
        };
        if (!ret) {
            try printer.print("error parsing: '{s}': WorkingDir is not a accessible\n", .{program.name});
            return ValidParserError.InvalidWorkingDir;
        }
        
        if (!std.mem.eql(u8, program.autorestart, "never") 
            and !std.mem.eql(u8, program.autorestart, "always")
            and !std.mem.eql(u8, program.autorestart, "unexpected")) {
            try printer.print("error parsing: '{s}': Autorestart policies should be either 'never' or 'always' or 'unexpected'\n", .{program.name});
            return ValidParserError.InvalidRestartPolicies;
        }
        _ = if (getSignal(program.stopsignal)) |_| true else |err| {
            switch (err) {
                error.SignalNotFound => try printer.print("error parsing: '{s}': Signal provided doesn't exist\n", .{program.name}),
            }
            return ValidParserError.InvalidSignal;
        };
    }
}

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
        if (field.type == ?[]const u8 or field.type == ?[]u8) {
            const field_value = @field(original.*, field.name);
            if (field_value != null) {
                @field(clone, field.name) = try allocator.dupe(u8, field_value.?);
                errdefer allocator.free(@field(clone, field.name));
            }
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
        if (field.type == ?[]const u8 or field.type == ?[]u8) {
            const opt_value = @field(to_destroy, field.name);
            if (opt_value != null) allocator.free(opt_value.?);
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

/// reloadMap change the autostart_map, programs_map with the new configuration.
pub fn reloadMap(allocator: Allocator, config: []const u8) !void {
    allocator.free(current_config);
    current_config = config;
    var ymlz = try Ymlz(ProgramsYaml).init(allocator);
    errdefer ymlz.deinit(null);
    const result = try ymlz.loadRaw(current_config);
    defer ymlz.deinit(result);
    const programs = result.programs;

    for (programs) |program| {
        try realoadProgramMap(allocator, &program);
    }
}

/// Initiate the parsing of the passed yml path.
pub fn startParsing(allocator: Allocator, path: []const u8, printer: *Printer)  !void {
    try printer.print("starting parsing...\n", .{});
    const realpath = try std.fs.cwd().realpathAlloc(allocator, path);
    defer allocator.free(realpath);
    const buf = readYamlFile(allocator, realpath) catch |err| {
        switch (err) {
            error.FailedRead => std.debug.print("error: FailedRead didn't read all the file\n", .{}),
            else => std.debug.print("error: unknown {s}\n", .{@errorName(err)}),
        }
        return err;
    };
    defer allocator.free(buf);

    current_config = try readYamlFile(allocator, realpath);
    errdefer allocator.free(current_config);
    var process_program: *ProcessProgram = undefined;
    var ymlz = try Ymlz(ProgramsYaml).init(allocator);
    const result = try ymlz.loadRaw(current_config);
    defer ymlz.deinit(result);
    try validParser(allocator, result);


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
            exec.mutex.lock();
            try exec.process_program_map.put(clone.name, process_program);
            exec.mutex.unlock();
        } else {
            process_program = try .init(allocator, clone.name);
            errdefer process_program.deinit();
            exec.mutex.lock();
            try exec.process_program_map.put(clone.name, process_program);
            exec.mutex.unlock();
            try programs_map.put(clone.name, clone);
        }
    }
}
