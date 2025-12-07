// This is a struct of type ProcessRunner
const std = @import("std");
const parseEnv = @import("../parser/parser.zig").parseEnv;
const posix = std.posix;
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const ProcessProgram = @import("ProcessProgram.zig");
const Program = @import("../parser/parser.zig").Program;
const Self = @This();

allocator: Allocator,


mutex: *std.Thread.Mutex,

pid: posix.pid_t,

stdout_file: std.fs.File,
stdout_path: []const u8,

stderr_file: std.fs.File,
stderr_path: []const u8,


/// Create ProcessRunner struct
pub fn init(allocator: Allocator, stdout_path: []const u8, stderr_path: []const u8) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.*.allocator = allocator;
    self.*.mutex = try allocator.create(std.Thread.Mutex);
    self.*.stdout_path = try allocator.dupe(u8, stdout_path);
    self.*.stderr_path = try allocator.dupe(u8, stderr_path);
    return self;
}

/// Allocate resources need to the return resources.
fn parseExitCodes(self: *Self, exitcodes: []const u8) ![]u16 {
    var size: usize = 0;
    var iter = std.mem.splitScalar(u8, exitcodes, ',');
    while (iter.next()) : (size +=1) {}
    iter.reset();

    const allocator = self.*.allocator;
    var exitcode_result = try allocator.alloc(u16, size);
    errdefer allocator.free(exitcode_result);
    for (0..size, iter.next()) |i, line|{
        exitcode_result[i] = try fmt.parseInt(u16, line, 10);
    }
    return exitcode_result;
}

fn fileExistStdout(self: *Self) bool {
    self.*.stdout_file = std.fs.createFileAbsolute(self.*.stdout_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("error: '{s}' log file already exist\n", .{self.*.stderr_path});
            return true;
        },
        else => return true,
    };
    return false;
}

fn fileExistStderr(self: *Self) bool {
    self.*.stderr_file = std.fs.createFileAbsolute(self.*.stderr_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("error: '{s}' log file already exist\n", .{self.*.stderr_path});
            return true;
        },
        else => return true,
    };
    return false;
}

fn processRunnerValid(pid: posix.pid_t, second: usize, process_program: *ProcessProgram) !void {
    const timer = std.time.ns_per_s * second; 
    std.Thread.sleep(timer);

    posix.kill(pid, 0) catch |err| switch (err) {
        error.PermissionDenied => std.debug.print("Unsufficant Permission not allowed to check process\n", .{}),
        error.ProcessNotFound => std.debug.print("Unable to find [{d}] pid\n", .{pid}),
        else => @panic("unknown error when checking process\n"),
    };
    try process_program.pidAdd(pid);
}

/// start execution of command and return pid.
pub fn start(self: *Self,  program: *Program, exec: []const []const u8, process_program: *ProcessProgram) !*std.Thread {
    const allocator = self.*.allocator;
    const mutex = self.*.mutex;
    const umask = try std.fmt.parseInt(u16, program.umask, 8);
    const argv = try allocator.allocSentinel(?[*:0]const u8, exec.len, null);
    defer allocator.free(argv);

    for (0..exec.len, exec) |i, line| argv[i] = try allocator.dupeZ(u8, line);
    defer {
        for (argv) |opt_line| {
            if (opt_line) |line| allocator.free(std.mem.span(line));
        }
    }

    const env = try parseEnv(allocator, program.env);
    defer {
        const slice = std.mem.span(env);
        for (slice) |item| {
            if (item) |s| allocator.free(std.mem.span(s));
        }
        allocator.free(slice);
    }

    const old_umask = std.c.umask(umask);
    defer _ = std.c.umask(old_umask);

    const pid = try posix.fork();
    if (pid == 0) {
        // we are the child
        mutex.lock();
        if (self.fileExistStderr()) self.*.stderr_file = try std.fs.openFileAbsolute(self.*.stderr_path, .{ .mode = .write_only });
        if (self.fileExistStdout()) self.*.stdout_file = try std.fs.openFileAbsolute(self.*.stdout_path, .{ .mode = .write_only });
        mutex.unlock();
        try posix.dup2(self.*.stdout_file.handle, posix.STDOUT_FILENO);
        try posix.dup2(self.*.stderr_file.handle, posix.STDERR_FILENO);

        posix.close(self.*.stdout_file.handle);
        posix.close(self.*.stderr_file.handle);

        try posix.chdir(program.workingdir);
        const err = posix.execvpeZ(argv[0].?, argv, env);
        switch (err) {
            else => std.debug.print("posix.execvpeZ error: '{s}'\n", .{@errorName(err)}),
        }
        posix.exit(0);
    } 
    // we are the parent
    
    self.*.pid = pid;

    // We create a thread here to check if the start of the process is valid or not,
    // this will impact the thread that check if the process is up or not.
    const thread: *std.Thread = try allocator.create(std.Thread);
    errdefer allocator.destroy(thread);

    thread.* = try std.Thread.spawn(.{}, processRunnerValid, .{ pid, program.starttime, process_program });
    return thread;
}

/// Destroy ProcessRunner struct `release` all allocated resources
pub fn deinit(self: *Self) void {
    const allocator = self.*.allocator;
    self.*.mutex.lock();
    allocator.free(self.*.stdout_path);
    allocator.free(self.*.stderr_path);
    self.*.mutex.unlock();
    allocator.destroy(self.*.mutex);
    allocator.destroy(self);
    self.* = undefined;
}
